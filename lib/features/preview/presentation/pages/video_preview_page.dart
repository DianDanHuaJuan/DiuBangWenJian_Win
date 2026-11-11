import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../../app/di/service_locator.dart';
import '../../../../core/protocol/nas_api_paths.dart';
import '../preview_args.dart';
import '../widgets/nas_video_session.dart';

/// 兼容路由 `/preview/video`（非主入口；主路径为画廊内嵌播放）。
///
/// 远程走 HTTPS Range 在线流（与画廊同一套缓冲定案），不再整文件下载。
class VideoPreviewPage extends StatefulWidget {
  const VideoPreviewPage({super.key, required this.args});

  final PreviewArgs args;

  @override
  State<VideoPreviewPage> createState() => _VideoPreviewPageState();
}

class _VideoPreviewPageState extends State<VideoPreviewPage> {
  final NasVideoSession _video = NasVideoSession();
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      final args = widget.args;
      final local = args.localPath;
      if (local != null && local.isNotEmpty) {
        await _video.openLocal(local, play: true);
      } else if (args.canFetchRemote) {
        final target =
            await serviceLocator.peerApiClient().authenticatedGetTarget(
                  args.peerFingerprint!,
                  NasApiPaths.filesContent,
                  query: {
                    'rootId': args.rootId,
                    'path': args.relativePath,
                  },
                );
        if (target == null) {
          throw Exception('无法解析播放地址');
        }
        await _video.openRemote(
          url: target.url,
          headers: target.headers,
          play: true,
        );
      } else {
        throw Exception('无法获取视频文件');
      }
      if (!mounted) {
        await _video.dispose();
        return;
      }
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  void dispose() {
    unawaited(_video.dispose());
    _video.disposeNotifiers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _video.controller;
    final theme = _video.buildControlsTheme();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          widget.args.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Colors.white))
          : _error != null
              ? Center(
                  child: Text(
                    _error!,
                    style: const TextStyle(color: Colors.white70),
                    textAlign: TextAlign.center,
                  ),
                )
              : controller == null
                  ? const SizedBox.shrink()
                  : MaterialVideoControlsTheme(
                      normal: theme,
                      fullscreen: theme,
                      child: Video(
                        controller: controller,
                        controls: MaterialVideoControls,
                        fill: Colors.black,
                      ),
                    ),
    );
  }
}
