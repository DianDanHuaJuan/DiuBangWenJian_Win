import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'ffmpeg_locator.dart';
import 'file_thumbnail_backend.dart';
import 'thumbnail_image_decode.dart';

/// Windows：图片 Dart 解码；视频 ffmpeg 抽帧。
class WindowsFileThumbnailBackend implements FileThumbnailBackend {
  WindowsFileThumbnailBackend({FfmpegLocator? ffmpegLocator})
      : _ffmpeg = ffmpegLocator ?? FfmpegLocator();

  final FfmpegLocator _ffmpeg;

  @override
  Future<Uint8List?> imageThumb(File file, int maxPx) =>
      decodeImageThumbnail(file, maxPx);

  @override
  Future<Uint8List?> videoThumb(File file, int maxPx) async {
    final ffmpegPath = await _ffmpeg.find();
    if (ffmpegPath == null) return null;

    Process? process;
    Future<void>? stderrDrain;
    try {
      process = await Process.start(ffmpegPath, [
        '-hide_banner',
        '-loglevel',
        'error',
        '-ss',
        '0',
        '-i',
        file.path,
        '-vframes',
        '1',
        '-f',
        'image2pipe',
        '-vcodec',
        'mjpeg',
        '-an',
        '-nostdin',
        'pipe:1',
      ]);
      stderrDrain = process.stderr.drain<void>();
      final stdoutBytes = await process.stdout
          .fold<List<int>>(<int>[], (buffer, chunk) => buffer..addAll(chunk))
          .timeout(const Duration(seconds: 15));
      final exitCode = await process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          process?.kill();
          return -1;
        },
      );
      await stderrDrain.timeout(
        const Duration(seconds: 5),
        onTimeout: () async {},
      );
      if (exitCode != 0 || stdoutBytes.isEmpty) return null;
      final decoded = img.decodeImage(Uint8List.fromList(stdoutBytes));
      if (decoded == null) return null;
      final resized = resizePreservingAspect(decoded, maxPx);
      return Uint8List.fromList(img.encodeJpg(resized, quality: 85));
    } catch (_) {
      process?.kill();
      await stderrDrain?.catchError((_) {});
      return null;
    }
  }
}
