import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 定位捆绑或 PATH 中的 ffmpeg（Windows 使用旧仓裁剪版 assets/ffmpeg.exe）。
class FfmpegLocator {
  FfmpegLocator({this.extraCandidates = const []});

  final List<String> extraCandidates;

  static String? _cached;
  static bool _searched = false;

  Future<String?> locate() => find();

  Future<String?> find() async {
    if (_searched) return _cached;
    _searched = true;

    final executableDir = p.dirname(Platform.resolvedExecutable);
    final candidates = <String>[
      ...extraCandidates,
      if (Platform.isWindows) ...[
        p.join(executableDir, 'ffmpeg.exe'),
        p.join(executableDir, 'tools', 'ffmpeg.exe'),
        p.join(
          executableDir,
          'data',
          'flutter_assets',
          'assets',
          'ffmpeg.exe',
        ),
        p.join(Directory.current.path, 'assets', 'ffmpeg.exe'),
      ],
      'ffmpeg',
    ];

    for (final candidate in candidates) {
      try {
        if (candidate == 'ffmpeg') {
          final result = await Process.run(candidate, ['-version']);
          if (result.exitCode == 0) {
            _cached = candidate;
            return _cached;
          }
          continue;
        }
        if (await File(candidate).exists()) {
          _cached = candidate;
          return _cached;
        }
      } catch (_) {}
    }

    if (Platform.isWindows) {
      try {
        final result = await Process.run(
          'where',
          const <String>['ffmpeg.exe'],
          runInShell: true,
        );
        if (result.exitCode == 0) {
          for (final line in LineSplitter.split('${result.stdout}')) {
            final path = line.trim();
            if (path.isNotEmpty && await File(path).exists()) {
              _cached = path;
              return _cached;
            }
          }
        }
      } catch (_) {}
    }

    return null;
  }
}
