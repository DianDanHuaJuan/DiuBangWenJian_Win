import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../preview/presentation/widgets/nas_video_session.dart';

/// 聊天视频全屏预览：缓存文件本地播；下方「下载」晋升公共库（对齐图片预览）。
class ChatVideoPreviewPage extends StatefulWidget {
  const ChatVideoPreviewPage({
    super.key,
    required this.videoPath,
    this.title,
    this.onDownload,
    this.downloading = false,
    this.downloaded = false,
  });

  final String videoPath;
  final String? title;
  final VoidCallback? onDownload;
  final bool downloading;
  final bool downloaded;

  @override
  State<ChatVideoPreviewPage> createState() => _ChatVideoPreviewPageState();
}

class _ChatVideoPreviewPageState extends State<ChatVideoPreviewPage> {
  final _video = NasVideoSession();
  var _ready = false;
  String? _error;

  static const _overlayStyle = SystemUiOverlayStyle(
    statusBarColor: Colors.black,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.black,
    systemNavigationBarIconBrightness: Brightness.light,
    systemNavigationBarDividerColor: Colors.black,
  );

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    final file = File(widget.videoPath);
    if (!await file.exists()) {
      if (mounted) setState(() => _error = '文件不存在');
      return;
    }
    try {
      await _video.openLocal(widget.videoPath, play: true);
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
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
    final bottom = MediaQuery.paddingOf(context).bottom;
    final ctrl = _video.controller;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _overlayStyle,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (_error != null)
              Center(
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.white70),
                ),
              )
            else if (_ready && ctrl != null)
              Center(
                child: Video(
                  controller: ctrl,
                  controls: MaterialVideoControls,
                ),
              )
            else
              const Center(child: CircularProgressIndicator(color: Colors.white)),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.close, color: Colors.white),
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black.withValues(alpha: 0.35),
                      ),
                    ),
                    if ((widget.title ?? '').isNotEmpty)
                      Expanded(
                        child: Text(
                          widget.title!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 14,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (widget.onDownload != null || widget.downloaded)
              Positioned(
                left: 0,
                right: 0,
                bottom: 28 + bottom,
                child: Center(
                  child: widget.downloaded
                      ? const _OverlayChip(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.check_circle,
                                color: Colors.greenAccent,
                                size: 18,
                              ),
                              SizedBox(width: 8),
                              Text(
                                '已保存',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        )
                      : Material(
                          color: Colors.transparent,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(24),
                            onTap: widget.downloading
                                ? null
                                : widget.onDownload,
                            child: _OverlayChip(
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (widget.downloading)
                                    const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  else
                                    const Icon(
                                      Icons.download_rounded,
                                      color: Colors.white,
                                      size: 18,
                                    ),
                                  const SizedBox(width: 8),
                                  Text(
                                    widget.downloading ? '保存中…' : '下载',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _OverlayChip extends StatelessWidget {
  const _OverlayChip({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.28)),
      ),
      child: child,
    );
  }
}
