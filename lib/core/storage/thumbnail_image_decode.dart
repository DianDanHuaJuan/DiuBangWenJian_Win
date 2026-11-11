import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Dart 侧图片缩略图（isolate 解码）。
Future<Uint8List?> decodeImageThumbnail(File file, int maxPx) async {
  try {
    return await compute(_imageThumbIsolate, (file.path, maxPx));
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
