import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../../../core/platform/app_platform.dart';
import '../../../../../core/storage/ffmpeg_locator.dart';
import '../../../../../core/storage/mime_types.dart';

export '../../../../../core/storage/ffmpeg_locator.dart' show FfmpegLocator;

/// 视频预览会话：有 ffmpeg 时可生成 HLS；否则 / 定案 Windows 仅 Range 时返回 direct。
///
/// Windows 产品定案（docs/Win移植整体规划.md Q13）：对端播放只做 Range，不做 HLS。
/// 本服务仍保留 HLS 尝试路径供安卓；Windows 上直接走 direct。
class VideoHlsSessionService {
  VideoHlsSessionService({
    required this.resolver,
    required this.ffmpeg,
    Directory? workDir,
  }) : _workDir = workDir;

  final Future<File?> Function({
    required String rootId,
    required String relativePath,
  }) resolver;
  final FfmpegLocator ffmpeg;
  final Directory? _workDir;

  Future<Map<String, dynamic>> resolve({
    required String rootId,
    required String fileName,
  }) async {
    final file = await resolver(rootId: rootId, relativePath: fileName);
    if (file == null || !await file.exists()) {
      return {'ok': false, 'error': 'file not found'};
    }

    Map<String, dynamic> direct() => {
          'ok': true,
          'mode': 'direct',
          'contentPath':
              '/api/v1/files/content?rootId=${Uri.encodeQueryComponent(rootId)}&name=${Uri.encodeQueryComponent(fileName)}',
          'mimeHint': MimeTypes.fromFileNameOrOctet(fileName),
        };

    // Windows：定案仅 Range，不转 HLS。
    if (AppPlatform.isWindows) {
      return direct();
    }

    final bin = await ffmpeg.locate();
    if (bin == null) {
      return direct();
    }

    try {
      final base = _workDir ??
          Directory(p.join(Directory.systemTemp.path, 'diubang_hls'));
      await base.create(recursive: true);
      final sessionId =
          '${rootId.hashCode}_${fileName.hashCode}_${await file.length()}';
      final outDir = Directory(p.join(base.path, sessionId));
      final playlist = File(p.join(outDir.path, 'index.m3u8'));
      if (!await playlist.exists()) {
        await outDir.create(recursive: true);
        // LGPL：用 Cisco OpenH264（BSD），勿用 GPL 的 libx264。
        final result = await Process.run(bin, [
          '-y',
          '-i',
          file.path,
          '-c:v',
          'libopenh264',
          '-profile:v',
          'baseline',
          '-vf',
          'scale=-2:720',
          '-c:a',
          'aac',
          '-f',
          'hls',
          '-hls_time',
          '4',
          '-hls_list_size',
          '0',
          playlist.path,
        ]);
        if (result.exitCode != 0 || !await playlist.exists()) {
          return {
            ...direct(),
            'ffmpegNote': 'transcode failed, fallback direct',
          };
        }
      }
      return {
        'ok': true,
        'mode': 'hls',
        'sessionId': sessionId,
        'playlistPath': playlist.path,
        'contentPath':
            '/api/v1/files/content?rootId=${Uri.encodeQueryComponent(rootId)}&name=${Uri.encodeQueryComponent(fileName)}',
      };
    } catch (_) {
      return direct();
    }
  }
}
