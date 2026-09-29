// AttachField pick flow through file_picker's method channel: stage / upload
// / multi-select notice / size guard / rejection / remove. Real file I/O in a
// temp MediaStore root, hence the runAsync hops in `settle`.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/exceptions.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/attach_field.dart';
import 'package:frappe_mobile_sdk/src/utils/media_store.dart';
import 'package:path/path.dart' as p;

const _channel = MethodChannel('miguelruivo.flutter.plugins.filepicker');

final _field = DocField(fieldname: 'doc', fieldtype: 'Attach', label: 'Doc');

void main() {
  late Directory tmp;
  late String pdf;
  late String second;
  late List<Map<String, Object?>>? pickResult;
  PlatformException? pickError;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('pis2_attach_field_');
    MediaStore.overrideRootForTest(p.join(tmp.path, 'store'));
    pdf = p.join(tmp.path, 'report.pdf');
    File(pdf).writeAsBytesSync(List<int>.filled(32, 1));
    second = p.join(tmp.path, 'extra.pdf');
    File(second).writeAsBytesSync(List<int>.filled(8, 2));
    pickResult = [
      {'name': 'report.pdf', 'path': pdf, 'size': 32},
    ];
    pickError = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (pickError != null) throw pickError!;
          return pickResult;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    MediaStore.overrideRootForTest(null);
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> pump(
    WidgetTester tester, {
    String? value,
    List<String?>? changes,
    List<String?>? reclaimed,
    bool? online,
    bool offlineMode = false,
    Future<String?> Function(File)? upload,
    Future<void> Function(String?)? reclaim,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FormBuilder(
            child: AttachField(
              field: _field,
              value: value,
              onChanged: (v) => changes?.add(v as String?),
              reclaimAttachment: reclaim ?? (v) async => reclaimed?.add(v),
              isOnline: online == null ? null : () => online,
              isOfflineMode: () => offlineMode,
              uploadFile: upload,
              fileUrlBase: 'https://example.test',
            ),
          ),
        ),
      ),
    );
  }

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

  bool shown(String text) => find.text(text).evaluate().isNotEmpty;

  testWidgets('offline-first pick stages a durable copy and names it', (
    tester,
  ) async {
    final changes = <String?>[];
    await pump(tester, changes: changes, offlineMode: true);
    expect(find.text('Select file'), findsOneWidget);
    await tester.tap(find.text('Select file'));
    await settle(tester, () => changes.isNotEmpty);
    final stored = changes.single!;
    expect(p.isWithin(p.join(tmp.path, 'store'), stored), isTrue);
    expect(p.basename(stored), 'report.pdf');
    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.byTooltip('Remove attachment'), findsOneWidget);
  });

  testWidgets('a multi-file selection keeps the first and says so', (
    tester,
  ) async {
    pickResult = [
      {'name': 'report.pdf', 'path': pdf, 'size': 32},
      {'name': 'extra.pdf', 'path': second, 'size': 8},
    ];
    final changes = <String?>[];
    await pump(tester, changes: changes, offlineMode: true);
    await tester.tap(find.text('Select file'));
    await settle(tester, () => changes.isNotEmpty);
    expect(p.basename(changes.single!), 'report.pdf');
    expect(find.text('Only the first file was attached.'), findsOneWidget);
  });

  testWidgets('cancelling the picker changes nothing', (tester) async {
    pickResult = null;
    final changes = <String?>[];
    await pump(tester, changes: changes, value: '/files/old.pdf');
    await tester.tap(find.text('old.pdf'));
    await settle(tester, () => false);
    expect(changes, isEmpty);
    expect(find.text('old.pdf'), findsOneWidget);
  });

  testWidgets('online pick uploads and stores only the file URL', (
    tester,
  ) async {
    final changes = <String?>[];
    await pump(
      tester,
      changes: changes,
      online: true,
      upload: (_) async => '/private/files/report.pdf',
    );
    await tester.tap(find.text('Select file'));
    await settle(tester, () => changes.isNotEmpty);
    expect(changes, ['/private/files/report.pdf']);
  });

  testWidgets('a terminal upload rejection is explained', (tester) async {
    final changes = <String?>[];
    await pump(
      tester,
      changes: changes,
      online: true,
      upload: (_) async => throw AuthException('Not permitted', 403),
    );
    await tester.tap(find.text('Select file'));
    const msg = 'The server rejected this file, so it was not attached.';
    await settle(tester, () => shown(msg));
    expect(find.text(msg), findsOneWidget);
    expect(changes, isEmpty);
  });

  testWidgets('an oversized file is refused with the real limit', (
    tester,
  ) async {
    final big = p.join(tmp.path, 'huge.pdf');
    final raf = File(big).openSync(mode: FileMode.write);
    raf.truncateSync(11 * 1024 * 1024); // sparse; no real disk use
    raf.closeSync();
    pickResult = [
      {'name': 'huge.pdf', 'path': big, 'size': 11 * 1024 * 1024},
    ];
    final changes = <String?>[];
    await pump(tester, changes: changes, offlineMode: true);
    await tester.tap(find.text('Select file'));
    const msg =
        'This file is 11 MB, over the 10 MB limit. Attach a smaller file.';
    await settle(tester, () => shown(msg));
    expect(find.text(msg), findsOneWidget);
    expect(changes, isEmpty);
  });

  testWidgets('a picker/platform failure is reported, not thrown', (
    tester,
  ) async {
    pickError = PlatformException(code: 'read_external_storage_denied');
    final changes = <String?>[];
    await pump(tester, changes: changes);
    await tester.tap(find.text('Select file'));
    const msg =
        'Could not attach the file. Check your connection and storage '
        'permissions.';
    await settle(tester, () => shown(msg));
    expect(find.text(msg), findsOneWidget);
    expect(changes, isEmpty);
  });

  testWidgets('Remove clears first, then reclaims the old value', (
    tester,
  ) async {
    final changes = <String?>[];
    final reclaimed = <String?>[];
    await pump(
      tester,
      value: '/files/old.pdf',
      changes: changes,
      reclaimed: reclaimed,
    );
    await tester.tap(find.byTooltip('Remove attachment'));
    await tester.pump();
    expect(changes, [null]);
    expect(reclaimed, ['/files/old.pdf']);
    expect(find.text('Select file'), findsOneWidget);
  });

  testWidgets('replacing a file reclaims the one it replaces', (tester) async {
    final changes = <String?>[];
    final reclaimed = <String?>[];
    await pump(
      tester,
      value: '/files/old.pdf',
      changes: changes,
      reclaimed: reclaimed,
      offlineMode: true,
    );
    await tester.tap(find.text('old.pdf'));
    await settle(tester, () => changes.isNotEmpty);
    expect(reclaimed, ['/files/old.pdf']);
    expect(p.basename(changes.single!), 'report.pdf');
  });

  testWidgets(
    'a failing reclaim of the replaced file does not lose the new pick',
    (tester) async {
      // BUG SDK2-11 (P3), AttachField twin of the ImageField finding:
      // attach_field.dart:428 awaits `reclaimAttachment(current)` BEFORE
      // `fieldState.didChange(stored)` / `onChanged` in the pick handler, so a
      // throwing reclaimer drops the freshly staged file and the catch-all
      // tells the user to check "connection and storage permissions". The
      // Remove button in the same file clears first for exactly this reason.
      final changes = <String?>[];
      await pump(
        tester,
        value: '/files/old.pdf',
        changes: changes,
        offlineMode: true,
        reclaim: (_) async => throw StateError('db closed'),
      );
      await tester.tap(find.text('old.pdf'));
      await settle(
        tester,
        () =>
            changes.isNotEmpty ||
            shown(
              'Could not attach the file. '
              'Check your connection and storage permissions.',
            ),
      );
      expect(changes, hasLength(1));
    },
    skip: true, // BUG SDK2-11: reclaim failure drops the new pick
  );
}
