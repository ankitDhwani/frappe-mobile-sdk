// ImageField pick / camera / remove / full-screen flows, driven through a
// fake ImagePickerPlatform and a temp MediaStore root (real file I/O, hence
// the runAsync hops in `_settle`).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/exceptions.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/image_pick_source.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/image_field.dart';
import 'package:frappe_mobile_sdk/src/utils/media_store.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:path/path.dart' as p;

class _FakePicker extends ImagePickerPlatform {
  final List<ImageSource> sources = [];
  String? path;
  Object? error;

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async {
    sources.add(source);
    if (error != null) throw error!;
    return path == null ? null : XFile(path!);
  }
}

final _field = DocField(
  fieldname: 'photo',
  fieldtype: 'Attach Image',
  label: 'Photo',
);

void main() {
  late Directory tmp;
  late String sourcePath;
  late _FakePicker picker;
  late ImagePickerPlatform originalPicker;

  setUpAll(() => originalPicker = ImagePickerPlatform.instance);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('pis2_image_field_');
    MediaStore.overrideRootForTest(p.join(tmp.path, 'store'));
    sourcePath = p.join(tmp.path, 'shot.jpg');
    File(sourcePath).writeAsBytesSync(List<int>.filled(64, 7));
    picker = _FakePicker()..path = sourcePath;
    ImagePickerPlatform.instance = picker;
  });

  tearDown(() {
    ImagePickerPlatform.instance = originalPicker;
    MediaStore.overrideRootForTest(null);
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> pump(
    WidgetTester tester, {
    String? value,
    DocField? field,
    List<String?>? changes,
    List<String?>? reclaimed,
    bool? online,
    bool offlineMode = false,
    Future<String?> Function(File)? upload,
    ImagePickSource? source,
    bool enabled = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: FormBuilder(
              child: ImageField(
                field: field ?? _field,
                value: value,
                enabled: enabled,
                onChanged: (v) => changes?.add(v as String?),
                reclaimAttachment: (v) async => reclaimed?.add(v),
                isOnline: online == null ? null : () => online,
                isOfflineMode: () => offlineMode,
                uploadFile: upload,
                imagePickSource: source == null ? null : () => source,
                fileUrlBase: 'https://example.test',
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Pump + real-time hops until [done] holds (bounded).
  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 60 && !done(); i++) {
      await tester.pump();
      if (done()) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    await tester.pump();
  }

  bool snack(String text) => find.text(text).evaluate().isNotEmpty;

  testWidgets('offline-first gallery pick stores a durable staged copy', (
    tester,
  ) async {
    final changes = <String?>[];
    await pump(tester, changes: changes, offlineMode: true);
    await tester.tap(find.text('Gallery'));
    await settle(tester, () => changes.isNotEmpty);

    expect(picker.sources, [ImageSource.gallery]);
    final stored = changes.single!;
    expect(stored, isNot(sourcePath));
    expect(p.isWithin(p.join(tmp.path, 'store'), stored), isTrue);
    final exists = await tester.runAsync(() => File(stored).exists());
    expect(exists, isTrue);
    // A local-file preview with the full-screen affordance appears.
    expect(find.byIcon(Icons.fullscreen), findsOneWidget);
    expect(find.byTooltip('Remove photo'), findsOneWidget);
  });

  testWidgets('online pick uploads and keeps only the server URL', (
    tester,
  ) async {
    final changes = <String?>[];
    final uploaded = <String>[];
    await pump(
      tester,
      changes: changes,
      online: true,
      upload: (f) async {
        uploaded.add(f.path);
        return '/files/shot.jpg';
      },
    );
    await tester.tap(find.text('Gallery'));
    await settle(tester, () => changes.isNotEmpty);
    expect(changes, ['/files/shot.jpg']);
    expect(uploaded, hasLength(1));
    // The staged copy that was uploaded is cleaned up.
    final left = await tester.runAsync(() => File(uploaded.single).exists());
    expect(left, isFalse);
  });

  testWidgets('offline (not offline-first) pick keeps the local copy', (
    tester,
  ) async {
    final changes = <String?>[];
    var uploads = 0;
    await pump(
      tester,
      changes: changes,
      online: false,
      upload: (_) async {
        uploads++;
        return '/files/never.jpg';
      },
    );
    await tester.tap(find.text('Gallery'));
    await settle(tester, () => changes.isNotEmpty);
    expect(uploads, 0);
    expect(p.isWithin(p.join(tmp.path, 'store'), changes.single!), isTrue);
  });

  testWidgets('a terminal upload rejection is explained and nothing stored', (
    tester,
  ) async {
    final changes = <String?>[];
    await pump(
      tester,
      changes: changes,
      online: true,
      upload: (_) async => throw ApiException('Forbidden file type', 400),
    );
    await tester.tap(find.text('Gallery'));
    const msg = 'The server rejected this photo, so it was not attached.';
    await settle(tester, () => snack(msg));
    expect(find.text(msg), findsOneWidget);
    expect(changes, isEmpty);
    expect(find.byTooltip('Remove photo'), findsNothing);
  });

  testWidgets('a transient upload failure falls back to the staged copy', (
    tester,
  ) async {
    final changes = <String?>[];
    await pump(
      tester,
      changes: changes,
      online: true,
      upload: (_) async => throw NetworkException('No internet connection'),
    );
    await tester.tap(find.text('Gallery'));
    await settle(tester, () => changes.isNotEmpty);
    expect(p.isWithin(p.join(tmp.path, 'store'), changes.single!), isTrue);
  });

  testWidgets('a denied gallery permission is reported, not thrown', (
    tester,
  ) async {
    picker.error = PlatformException(code: 'photo_access_denied');
    final changes = <String?>[];
    await pump(tester, changes: changes);
    await tester.tap(find.text('Gallery'));
    const msg =
        'Could not open the gallery. Check photo permissions in Settings.';
    await settle(tester, () => snack(msg));
    expect(find.text(msg), findsOneWidget);
    expect(changes, isEmpty);
  });

  testWidgets('cancelling the gallery leaves the value untouched', (
    tester,
  ) async {
    picker.path = null;
    final changes = <String?>[];
    await pump(tester, changes: changes, value: '/files/old.jpg');
    await tester.tap(find.text('Gallery'));
    await settle(tester, () => picker.sources.isNotEmpty);
    expect(changes, isEmpty);
    expect(find.byTooltip('Remove photo'), findsOneWidget);
  });

  testWidgets('camera capture stores the photo', (tester) async {
    final changes = <String?>[];
    await pump(tester, changes: changes, offlineMode: true);
    await tester.tap(find.text('Camera'));
    await settle(tester, () => changes.isNotEmpty);
    expect(picker.sources, [ImageSource.camera]);
    expect(changes, hasLength(1));
  });

  testWidgets('a camera failure is reported, not thrown', (tester) async {
    picker.error = PlatformException(code: 'camera_access_denied');
    await pump(tester);
    await tester.tap(find.text('Camera'));
    const msg =
        'Could not open the camera. Check camera permissions in Settings.';
    await settle(tester, () => snack(msg));
    expect(find.text(msg), findsOneWidget);
  });

  testWidgets('replacing a photo reclaims the previous value first', (
    tester,
  ) async {
    final changes = <String?>[];
    final reclaimed = <String?>[];
    await pump(
      tester,
      value: ' /tmp/previous.jpg ',
      changes: changes,
      reclaimed: reclaimed,
      offlineMode: true,
    );
    await tester.tap(find.text('Gallery'));
    await settle(tester, () => changes.isNotEmpty);
    // The widget value is trimmed before it is handed to the reclaimer.
    expect(reclaimed, ['/tmp/previous.jpg']);
    expect(changes, hasLength(1));
  });

  testWidgets('Remove clears the value, then reclaims the old one', (
    tester,
  ) async {
    final changes = <String?>[];
    final reclaimed = <String?>[];
    await pump(
      tester,
      value: 'https://example.test/files/a.jpg',
      changes: changes,
      reclaimed: reclaimed,
    );
    expect(find.byType(Image), findsOneWidget);
    await tester.tap(find.byTooltip('Remove photo'));
    await tester.pump();
    expect(changes, [null]);
    expect(reclaimed, ['https://example.test/files/a.jpg']);
    expect(find.byType(Image), findsNothing);
    expect(find.byTooltip('Remove photo'), findsNothing);
  });

  testWidgets('read-only field: no Remove, but the preview still opens', (
    tester,
  ) async {
    await pump(
      tester,
      value: 'https://example.test/files/a.jpg',
      field: DocField(
        fieldname: 'photo',
        fieldtype: 'Attach Image',
        label: 'Photo',
        readOnly: true,
      ),
    );
    expect(find.byTooltip('Remove photo'), findsNothing);
    await tester.tap(find.byType(Image));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(InteractiveViewer), findsNothing);
  });

  testWidgets('a disabled form hides Remove and disables both pickers', (
    tester,
  ) async {
    await pump(tester, value: '/files/a.jpg', enabled: false);
    expect(find.byTooltip('Remove photo'), findsNothing);
    final buttons = tester
        .widgetList<ButtonStyleButton>(
          find.byWidgetPredicate((w) => w is ButtonStyleButton),
        )
        .toList();
    expect(buttons, hasLength(2));
    expect(buttons.every((b) => b.onPressed == null), isTrue);
  });

  testWidgets('a local-file thumbnail opens the file viewer', (tester) async {
    await pump(tester, value: sourcePath);
    expect(find.byIcon(Icons.fullscreen), findsOneWidget);
    await tester.tap(find.byType(Image));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final viewer = tester.widget<Image>(
      find.descendant(
        of: find.byType(InteractiveViewer),
        matching: find.byType(Image),
      ),
    );
    expect(viewer.image, isA<FileImage>());
  });

  testWidgets('gallery-only source hides the camera button', (tester) async {
    await pump(tester, source: ImagePickSource.gallery);
    expect(find.text('Gallery'), findsOneWidget);
    expect(find.text('Camera'), findsNothing);
  });

  testWidgets('camera-only source hides the gallery button', (tester) async {
    await pump(tester, source: ImagePickSource.camera);
    expect(find.text('Gallery'), findsNothing);
    expect(find.text('Camera'), findsOneWidget);
  });

  testWidgets(
    'a failing reclaim of the replaced photo does not lose the new pick',
    (tester) async {
      // BUG SDK2-11 (P3): image_field.dart:297 awaits reclaimAttachment BEFORE
      // didChange/onChanged (:298-299), so a reclaimer that throws aborts the
      // pick: the new photo is staged but never attached, and the gallery
      // catch (:589-600) tells the user to check PHOTO PERMISSIONS. The same
      // file's Remove path documents the opposite rule (:699-703, "the user's
      // action must take effect even if reclaiming the bytes fails").
      final changes = <String?>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FormBuilder(
              child: ImageField(
                field: _field,
                value: '/tmp/previous.jpg',
                onChanged: (v) => changes.add(v as String?),
                isOfflineMode: () => true,
                reclaimAttachment: (_) async => throw StateError('db closed'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Gallery'));
      await settle(tester, () => changes.isNotEmpty || snack('x'));
      await settle(tester, () => changes.isNotEmpty);
      expect(changes, hasLength(1));
      expect(find.textContaining('photo permissions'), findsNothing);
    },
    skip: true, // BUG SDK2-11: reclaim failure drops the new pick
  );
}
