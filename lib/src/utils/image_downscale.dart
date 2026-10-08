import 'dart:io';
import 'dart:isolate';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'sdk_log.dart';

/// Size limit for photos taken or picked in an image field.
///
/// Off unless the host app sets [ImageUploadSettings.captureLimits]: Frappe
/// itself stores whatever the camera produced.
class ImageCaptureLimits {
  const ImageCaptureLimits({this.targetLongEdge = 1920, this.jpegQuality = 92});

  /// The long edge a shrunk photo keeps at least, in pixels. A photo is shrunk
  /// by the largest whole factor that keeps its long edge at or above this; a
  /// photo under twice this size is left as it is. With 1920 (Full HD), a
  /// 4000 px photo becomes 2000 px, a 6000 px photo 2000 px, and an 8 MP
  /// (3264 px) photo is not touched.
  final int targetLongEdge;

  /// JPEG quality (1-100) the shrunk photo is saved at.
  final int jpegQuality;
}

/// App-wide image upload policy. Every field and upload path reads it, so a
/// host sets it once at startup.
class ImageUploadSettings {
  ImageUploadSettings._();

  /// Shrink photos on the device before they are stored or uploaded. Null (the
  /// default) keeps Frappe's behaviour: the original file is uploaded.
  static ImageCaptureLimits? captureLimits;

  /// Whether uploads ask the server to optimise images. Null (the default)
  /// follows Frappe Desk: an image over 200 KB that is not an SVG. Set false to
  /// keep the uploaded photo as sent, e.g. when [captureLimits] already sized
  /// it and a second, server-side shrink to 1024x768 is not wanted.
  static bool? serverOptimize;

  /// Restores the defaults (for tests).
  static void reset() {
    captureLimits = null;
    serverOptimize = null;
  }
}

/// Returns [file] shrunk per [limits], or [file] itself when it is under
/// twice [ImageCaptureLimits.targetLongEdge], is not a JPEG, cannot be read,
/// or would not get smaller.
///
/// Quality:
/// - it shrinks by a whole-number factor k, and each output pixel is the exact
///   mean of a k x k block of the photo (a box filter). Nothing is resampled at
///   a fractional ratio, and no pixels are dropped, so text and fine detail
///   stay clean. (The platform picker's own maxWidth/maxHeight resize drops
///   pixels.) At most k-1 edge pixels are trimmed so the blocks tile exactly;
/// - the camera's rotation (EXIF orientation) is applied; other EXIF, such as
///   time and GPS, is kept.
///
/// Runs on a background isolate.
Future<File> downscalePickedImage(File file, ImageCaptureLimits limits) async {
  final path = file.path;
  final target = limits.targetLongEdge;
  final quality = limits.jpegQuality;
  try {
    final out = await Isolate.run(() => _downscale(path, target, quality));
    return out == null ? file : File(out);
  } catch (e, st) {
    sdkLog('downscalePickedImage: kept the original — $e\n$st');
    return file;
  }
}

String? _downscale(String path, int target, int quality) {
  final ext = p.extension(path).toLowerCase();
  if (ext != '.jpg' && ext != '.jpeg') return null;
  final bytes = File(path).readAsBytesSync();
  final decoded = img.decodeJpg(bytes);
  if (decoded == null) return null;

  final oriented = img.bakeOrientation(decoded);
  final w = oriented.width;
  final h = oriented.height;
  final longEdge = w > h ? w : h;
  // Largest whole factor that keeps the long edge at or above the target.
  final k = longEdge ~/ target;
  if (k < 2) return null;
  final tiled = (w % k == 0 && h % k == 0)
      ? oriented
      : img.copyCrop(oriented, x: 0, y: 0, width: w - w % k, height: h - h % k);
  final resized = img.copyResize(
    tiled,
    width: tiled.width ~/ k,
    height: tiled.height ~/ k,
    interpolation: img.Interpolation.average,
  );
  final encoded = img.encodeJpg(resized, quality: quality);
  if (encoded.length >= bytes.length) return null;

  final out = p.join(
    p.dirname(path),
    '${p.basenameWithoutExtension(path)}_${longEdge ~/ k}px.jpg',
  );
  File(out).writeAsBytesSync(encoded, flush: true);
  return out;
}

/// What an image field runs on every picked or captured photo: shrinks it when
/// the host app set [ImageUploadSettings.captureLimits], otherwise returns it
/// unchanged (Frappe behaviour). Runs before the photo is staged or uploaded,
/// so online and offline uploads both get the smaller file.
Future<File> preparePickedImage(File picked) {
  final limits = ImageUploadSettings.captureLimits;
  if (limits == null) return Future.value(picked);
  return downscalePickedImage(picked, limits);
}
