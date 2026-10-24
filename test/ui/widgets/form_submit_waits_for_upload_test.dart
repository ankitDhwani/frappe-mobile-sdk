import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/image_field.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.dir);
  final String dir;
  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
}

/// Saving while a picked photo is still uploading used to read the photo field
/// from before the upload landed, so the record was saved without the photo
/// (or with the previous one). The form now waits for the photo, then saves.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pickerChannel = MethodChannel('plugins.flutter.io/image_picker');
  late Directory tmp;
  late File picked;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('form-upload-wait-');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    picked = File('${tmp.path}/photo.jpg')..writeAsBytesSync([1, 2, 3, 4]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pickerChannel, (call) async {
          if (call.method == 'pickImage') return picked.path;
          return null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pickerChannel, null);
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  // The pick path mixes real file I/O with the test's fake clock: alternate a
  // real wait (I/O completes) with a pump (microtasks and frames run). The pump
  // also moves the fake clock, which a modal sheet's animation needs.
  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 15; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  /// Same, but follows the work until [done] holds instead of guessing how long
  /// the file I/O takes on a busy machine.
  Future<void> settleUntil(
    WidgetTester t,
    bool Function() done, {
    int seconds = 15,
  }) async {
    final end = DateTime.now().add(Duration(seconds: seconds));
    while (!done() && DateTime.now().isBefore(end)) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  final meta = DocTypeMeta(
    name: 'TestDoctype',
    fields: <DocField>[
      DocField(fieldname: 'photo', fieldtype: 'Attach Image', label: 'Photo'),
    ],
  );

  Future<
    ({
      List<Map<String, dynamic>> submits,
      void Function() submit,
      Completer<String?> upload,
      bool Function() uploadStarted,
    })
  >
  mount(
    WidgetTester tester, {
    FormBuilderMode mode = FormBuilderMode.legacy,
  }) async {
    final upload = Completer<String?>();
    final submits = <Map<String, dynamic>>[];
    var started = false;
    late void Function() submit;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: meta,
            mode: mode,
            uploadFile: (_) {
              started = true;
              return upload.future;
            },
            onSubmit: submits.add,
            registerSubmit: (fn) => submit = fn,
          ),
        ),
      ),
    );
    await tester.pump();
    return (
      submits: submits,
      submit: () => submit(),
      upload: upload,
      uploadStarted: () => started,
    );
  }

  /// Taps Gallery and waits until the pick has reached the upload.
  Future<void> pickPhoto(
    WidgetTester tester,
    bool Function() uploadStarted,
  ) async {
    await tester.tap(find.text('Gallery'));
    await settleUntil(tester, uploadStarted);
    expect(uploadStarted(), isTrue, reason: 'the pick reached the upload');
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  }

  // The row sheet of a child table is its own form with its own Save button;
  // this is the case where a picture picked just before Save was dropped.
  testWidgets(
    'a child-table row saved while its photo uploads keeps the photo',
    (tester) async {
      final upload = Completer<String?>();
      final submits = <Map<String, dynamic>>[];
      var started = false;
      late void Function() submit;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FrappeFormBuilder(
              meta: DocTypeMeta(
                name: 'Parent',
                fields: <DocField>[
                  DocField(
                    fieldname: 'rows',
                    fieldtype: 'Table',
                    label: 'Rows',
                    options: 'RowDoctype',
                  ),
                ],
              ),
              getMeta: (_) async => DocTypeMeta(
                name: 'RowDoctype',
                isTable: true,
                fields: <DocField>[
                  DocField(
                    fieldname: 'picture',
                    fieldtype: 'Attach Image',
                    label: 'Picture',
                  ),
                ],
              ),
              uploadFile: (_) {
                started = true;
                return upload.future;
              },
              onSubmit: submits.add,
              registerSubmit: (fn) => submit = fn,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add Row'));
      await settle(tester);
      await pickPhoto(tester, () => started);

      // The sheet's own Save, pressed while the photo is still uploading.
      final sheetSave = find.ancestor(
        of: find.text('Save'),
        matching: find.bySubtype<FilledButton>(),
      );
      await tester.tap(sheetSave);
      await settle(tester);
      expect(
        find.text('Save'),
        findsOneWidget,
        reason: 'the sheet stays open while it waits for the photo',
      );

      upload.complete('/private/files/row.jpg');
      await settleUntil(tester, () => find.text('Save').evaluate().isEmpty);
      expect(
        find.text('Save'),
        findsNothing,
        reason: 'row added, sheet closed',
      );

      submit();
      await settleUntil(tester, () => submits.isNotEmpty);
      final rows = submits.single['rows'] as List;
      expect(rows, hasLength(1));
      expect((rows.single as Map)['picture'], '/private/files/row.jpg');
    },
  );

  for (final mode in FormBuilderMode.values) {
    group('${mode.name} form', () {
      testWidgets('a save pressed while the photo uploads keeps the photo', (
        tester,
      ) async {
        final f = await mount(tester, mode: mode);
        await pickPhoto(tester, f.uploadStarted);

        f.submit();
        await settle(tester);
        expect(
          f.submits,
          isEmpty,
          reason: 'the upload has not finished, so the form must not save yet',
        );

        f.upload.complete('/private/files/photo.jpg');
        await settleUntil(tester, () => f.submits.isNotEmpty);

        expect(f.submits, hasLength(1), reason: 'saved once the photo landed');
        expect(f.submits.single['photo'], '/private/files/photo.jpg');
      });

      testWidgets('pressing save twice while waiting saves once', (
        tester,
      ) async {
        final f = await mount(tester, mode: mode);
        await pickPhoto(tester, f.uploadStarted);

        f.submit();
        f.submit();
        f.upload.complete('/private/files/photo.jpg');
        await settleUntil(tester, () => f.submits.isNotEmpty);
        await settle(tester); // a second save, if there were one, lands here

        expect(f.submits, hasLength(1));
      });

      testWidgets('a failed upload still lets the save go through', (
        tester,
      ) async {
        final f = await mount(tester, mode: mode);
        await pickPhoto(tester, f.uploadStarted);

        f.submit();
        f.upload.completeError(StateError('network down'));
        await settleUntil(tester, () => f.submits.isNotEmpty);

        expect(
          f.submits,
          hasLength(1),
          reason: 'the form must not hang on a photo that failed',
        );
      });

      // TabBarView disposes a tab page once it is off screen, and no field
      // keeps itself alive, so the photo field is gone when its upload lands.
      testWidgets('a photo whose tab was left while it uploads is still saved', (
        tester,
      ) async {
        final upload = Completer<String?>();
        final submits = <Map<String, dynamic>>[];
        var started = false;
        late void Function() submit;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: FrappeFormBuilder(
                meta: DocTypeMeta(
                  name: 'TestDoctype',
                  fields: <DocField>[
                    DocField(
                      fieldname: 'tab_photos',
                      fieldtype: 'Tab Break',
                      label: 'Photos',
                    ),
                    DocField(
                      fieldname: 'photo',
                      fieldtype: 'Attach Image',
                      label: 'Photo',
                    ),
                    DocField(
                      fieldname: 'tab_notes',
                      fieldtype: 'Tab Break',
                      label: 'Notes',
                    ),
                    DocField(
                      fieldname: 'note',
                      fieldtype: 'Data',
                      label: 'Note',
                    ),
                  ],
                ),
                mode: mode,
                uploadFile: (_) {
                  started = true;
                  return upload.future;
                },
                onSubmit: submits.add,
                registerSubmit: (fn) => submit = fn,
              ),
            ),
          ),
        );
        await tester.pump();

        await pickPhoto(tester, () => started);

        await tester.tap(find.widgetWithText(Tab, 'Notes'));
        await settle(tester);
        expect(
          find.byType(ImageField, skipOffstage: false),
          findsNothing,
          reason: 'the photo tab page was disposed while the photo uploads',
        );

        submit();
        await settle(tester);
        expect(submits, isEmpty, reason: 'the upload has not finished yet');

        upload.complete('/private/files/photo.jpg');
        await settleUntil(tester, () => submits.isNotEmpty);

        expect(submits, hasLength(1), reason: 'saved once the photo landed');
        expect(submits.single['photo'], '/private/files/photo.jpg');
        expect(
          find.text(
            'Could not open the gallery. Check photo permissions in Settings.',
          ),
          findsNothing,
          reason: 'landing on a disposed field must not fail the pick',
        );
      });

      testWidgets('with no upload running, save is not delayed', (
        tester,
      ) async {
        final f = await mount(tester, mode: mode);

        f.submit();
        await tester.pump();

        expect(f.submits, hasLength(1));
      });
    });
  }
}
