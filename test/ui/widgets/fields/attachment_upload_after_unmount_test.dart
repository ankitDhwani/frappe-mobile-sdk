// A field can be taken out of the tree while its pick is still uploading: a
// tab page that scrolls off screen is disposed, and no field keeps itself
// alive. When the upload then lands, the field's FormFieldState is gone.
//
// The value used to be handed to the disposed state first (`didChange`), which
// throws, so `onChanged` never ran and the form never learned of the pick: the
// record saved without it. The value it replaced had already been reclaimed, so
// a staged file it pointed at was deleted as well.
//
// These tests take the field out mid-upload and check that the value still
// reaches `onChanged`, that nothing failed, and that the replaced value is
// reclaimed only after the new one has been handed over.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/attach_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/image_field.dart';
import 'package:frappe_mobile_sdk/src/utils/media_store.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:path/path.dart' as p;

class _FakePicker extends ImagePickerPlatform {
  _FakePicker(this.path);
  final String path;

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async => XFile(path);
}

const _filePickerChannel = MethodChannel(
  'miguelruivo.flutter.plugins.filepicker',
);

const _previous = '/outbox/previous/old.jpg';
const _uploaded = '/private/files/new.jpg';

const _galleryError =
    'Could not open the gallery. Check photo permissions in Settings.';
const _attachError =
    'Could not attach the file. Check your connection and storage permissions.';

void main() {
  late Directory tmp;
  late String source;
  late ImagePickerPlatform originalPicker;

  setUpAll(() => originalPicker = ImagePickerPlatform.instance);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('upload_after_unmount_');
    MediaStore.overrideRootForTest(p.join(tmp.path, 'store'));
    source = p.join(tmp.path, 'shot.jpg');
    File(source).writeAsBytesSync(List<int>.filled(64, 7));
    ImagePickerPlatform.instance = _FakePicker(source);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          _filePickerChannel,
          (call) async => [
            {'name': 'shot.jpg', 'path': source, 'size': 64},
          ],
        );
  });

  tearDown(() {
    ImagePickerPlatform.instance = originalPicker;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_filePickerChannel, null);
    MediaStore.overrideRootForTest(null);
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// Pump + real-time hops until [done] holds (bounded). The pick path does
  /// real file I/O, which only advances inside `runAsync`.
  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 80 && !done(); i++) {
      await tester.pump();
      if (done()) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    await tester.pump();
  }

  /// The Scaffold and the FormBuilder stay mounted throughout; only the field
  /// below them comes and goes, as it does when its tab page is disposed.
  Widget host(Widget? field) => MaterialApp(
    home: Scaffold(body: FormBuilder(child: field ?? const SizedBox.shrink())),
  );

  ({
    List<String> events,
    Completer<String?> upload,
    bool Function() started,
    Widget Function() image,
    Widget Function() attach,
  })
  harness() {
    final events = <String>[];
    final upload = Completer<String?>();
    var started = false;
    Future<String?> uploadFile(File _) {
      started = true;
      return upload.future;
    }

    void changed(dynamic v) => events.add('changed:$v');
    Future<void> reclaim(String? v) async => events.add('reclaimed:$v');

    return (
      events: events,
      upload: upload,
      started: () => started,
      image: () => ImageField(
        field: DocField(
          fieldname: 'photo',
          fieldtype: 'Attach Image',
          label: 'Photo',
        ),
        value: _previous,
        onChanged: changed,
        reclaimAttachment: reclaim,
        isOnline: () => true,
        isOfflineMode: () => false,
        uploadFile: uploadFile,
      ),
      attach: () => AttachField(
        field: DocField(fieldname: 'doc', fieldtype: 'Attach', label: 'Doc'),
        value: _previous,
        onChanged: changed,
        reclaimAttachment: reclaim,
        isOnline: () => true,
        isOfflineMode: () => false,
        uploadFile: uploadFile,
      ),
    );
  }

  group('ImageField', () {
    testWidgets('an upload that lands after the field is gone still reaches '
        'onChanged, then reclaims the photo it replaced', (tester) async {
      final h = harness();
      await tester.pumpWidget(host(h.image()));

      await tester.tap(find.text('Gallery'));
      await settle(tester, h.started);
      expect(h.started(), isTrue, reason: 'the pick reached the upload');

      // The tab page holding the field is disposed while the upload runs.
      await tester.pumpWidget(host(null));
      expect(find.byType(ImageField), findsNothing);
      expect(h.events, isEmpty, reason: 'nothing is committed mid-upload');

      h.upload.complete(_uploaded);
      await settle(tester, () => h.events.length >= 2);

      expect(h.events, ['changed:$_uploaded', 'reclaimed:$_previous']);
      expect(find.text(_galleryError), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a mounted field also commits the new photo before it '
        'reclaims the old one', (tester) async {
      final h = harness();
      await tester.pumpWidget(host(h.image()));

      await tester.tap(find.text('Gallery'));
      await settle(tester, h.started);
      h.upload.complete(_uploaded);
      await settle(tester, () => h.events.length >= 2);

      expect(h.events, ['changed:$_uploaded', 'reclaimed:$_previous']);
      expect(find.text(_galleryError), findsNothing);
      expect(find.byTooltip('Remove photo'), findsOneWidget);
    });
  });

  group('AttachField', () {
    testWidgets('an upload that lands after the field is gone still reaches '
        'onChanged, then reclaims the file it replaced', (tester) async {
      final h = harness();
      await tester.pumpWidget(host(h.attach()));

      await tester.tap(find.byIcon(Icons.attach_file));
      await settle(tester, h.started);
      expect(h.started(), isTrue, reason: 'the pick reached the upload');

      await tester.pumpWidget(host(null));
      expect(find.byType(AttachField), findsNothing);
      expect(h.events, isEmpty, reason: 'nothing is committed mid-upload');

      h.upload.complete(_uploaded);
      await settle(tester, () => h.events.length >= 2);

      expect(h.events, ['changed:$_uploaded', 'reclaimed:$_previous']);
      expect(find.text(_attachError), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a mounted field also commits the new file before it '
        'reclaims the old one', (tester) async {
      final h = harness();
      await tester.pumpWidget(host(h.attach()));

      await tester.tap(find.byIcon(Icons.attach_file));
      await settle(tester, h.started);
      h.upload.complete(_uploaded);
      await settle(tester, () => h.events.length >= 2);

      expect(h.events, ['changed:$_uploaded', 'reclaimed:$_previous']);
      expect(find.text(_attachError), findsNothing);
      expect(find.text('new.jpg'), findsOneWidget);
    });
  });
}
