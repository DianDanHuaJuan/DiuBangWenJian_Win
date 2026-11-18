import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'ffmpeg_locator.dart';
import 'file_thumbnail_backend.dart';
import 'thumb_diag.dart';
import 'thumbnail_image_decode.dart';

/// Windows：图片 Dart 解码；视频 ffmpeg 抽帧（缩放/编码进 isolate）。
class WindowsFileThumbnailBackend implements FileThumbnailBackend {
  WindowsFileThumbnailBackend({FfmpegLocator? ffmpegLocator})
      : _ffmpeg = ffmpegLocator ?? FfmpegLocator();

  final FfmpegLocator _ffmpeg;

  @override
  Future<Uint8List?> imageThumb(File file, int maxPx) async {
    final name = p.basename(file.path);
    final sw = Stopwatch()..start();
    final bytes = await decodeImageThumbnail(file, maxPx);
    sw.stop();
    ThumbDiag.markPhase(
      'backend_image_end',
      details: {
        'name': name,
        'maxPx': maxPx,
        'bytes': bytes?.length ?? 0,
        'ms': sw.elapsedMilliseconds,
      },
    );
    return bytes;
  }

  @override
  Future<Uint8List?> videoThumb(File file, int maxPx) async {
    final name = p.basename(file.path);
    final sw = Stopwatch()..start();
    final ffmpegPath = await _ffmpeg.find();
    if (ffmpegPath == null) {
      ThumbDiag.markPhase('backend_video_no_ffmpeg', details: {'name': name});
      return null;
    }

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
      if (exitCode != 0 || stdoutBytes.isEmpty) {
        sw.stop();
        ThumbDiag.markPhase(
          'backend_video_ffmpeg_fail',
          details: {
            'name': name,
            'exit': exitCode,
            'stdout': stdoutBytes.length,
            'ms': sw.elapsedMilliseconds,
          },
        );
        return null;
      }

      final out = await compute(
        decodeJpegThumbIsolate,
        (Uint8List.fromList(stdoutBytes), maxPx),
      );
      sw.stop();
      ThumbDiag.markPhase(
        'backend_video_end',
        details: {
          'name': name,
          'bytes': out?.length ?? 0,
          'ms': sw.elapsedMilliseconds,
        },
      );
      return out;
    } catch (e) {
      process?.kill();
      await stderrDrain?.catchError((_) {});
      sw.stop();
      ThumbDiag.markPhase(
        'backend_video_exception',
        details: {
          'name': name,
          'ms': sw.elapsedMilliseconds,
          'error': '$e',
        },
      );
      return null;
    }
  }
}
