import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'thumb_diag.dart';

/// Dart 侧图片缩略图（isolate 解码）。
Future<Uint8List?> decodeImageThumbnail(File file, int maxPx) async {
  try {
    final sw = Stopwatch()..start();
    final out = await compute(_imageThumbIsolate, (file.path, maxPx));
    sw.stop();
    ThumbDiag.markPhase(
      'image_compute_end',
      details: {
        'name': p.basename(file.path),
        'bytes': out?.length ?? 0,
        'ms': sw.elapsedMilliseconds,
      },
    );
    return out;
  } catch (_) {
    return null;
  }
}

/// 已有 JPEG 字节（如 ffmpeg 抽帧）→ 缩放 JPEG（isolate）。
Uint8List? decodeJpegThumbIsolate((Uint8List jpeg, int maxPx) args) {
  try {
    final decoded = img.decodeImage(args.$1);
    if (decoded == null) return null;
    final resized = resizePreservingAspect(decoded, args.$2);
    return Uint8List.fromList(img.encodeJpg(resized, quality: 85));
  } catch (_) {
    return null;
  }
}

img.Image resizePreservingAspect(img.Image image, int maxSize) {
  if (maxSize <= 0 || image.width <= 0 || image.height <= 0) return image;
  final aspect = image.width / image.height;
  final targetWidth =
      aspect > 1 ? maxSize : math.max(1, (maxSize * aspect).round());
  final targetHeight =
      aspect > 1 ? math.max(1, (maxSize / aspect).round()) : maxSize;
  if (targetWidth == image.width && targetHeight == image.height) {
    return image;
  }
  return img.copyResize(image, width: targetWidth, height: targetHeight);
}

Uint8List? _imageThumbIsolate((String path, int maxPx) args) {
  try {
    final file = File(args.$1);
    final raw = file.readAsBytesSync();
    final decoded = img.decodeImage(raw);
    if (decoded == null) return null;
    final resized = resizePreservingAspect(decoded, args.$2);
    return Uint8List.fromList(img.encodeJpg(resized, quality: 82));
  } catch (_) {
    return null;
  }
}
