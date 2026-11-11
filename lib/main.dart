import 'package:flutter/material.dart';

import 'app/app.dart';
import 'app/bootstrap.dart';

Future<void> main(List<String> args) async {
  await bootstrap(startupArgs: args);
  // 网格缩略图主存 GridThumbnailCache；全局 ImageCache 略放宽避免滑回反复 decode。
  PaintingBinding.instance.imageCache.maximumSize = 250;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 120 << 20;
  runApp(const DiuBangApp());
  scheduleDeferredStartup();
}
