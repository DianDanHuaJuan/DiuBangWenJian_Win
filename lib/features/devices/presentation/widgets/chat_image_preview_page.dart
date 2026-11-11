import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 聊天图片全屏预览：黑底 + 系统栏着色，不切换 immersive（避免退出时底栏抬起）。
class ChatImagePreviewPage extends StatelessWidget {
  const ChatImagePreviewPage({
    super.key,
    required this.imagePath,
    this.title,
    this.onDownload,
    this.downloading = false,
    this.downloaded = false,
    this.loadingOriginal = false,
  });

  final String imagePath;
  final String? title;
  final VoidCallback? onDownload;
  final bool downloading;
  final bool downloaded;

  /// 预览图/封面已显示，正在后台拉原图。
  final bool loadingOriginal;

  static const _overlayStyle = SystemUiOverlayStyle(
    statusBarColor: Colors.black,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.black,
    systemNavigationBarIconBrightness: Brightness.light,
    systemNavigationBarDividerColor: Colors.black,
  );

  @override
  Widget build(BuildContext context) {
    final file = File(imagePath);
    final bottom = MediaQuery.paddingOf(context).bottom;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _overlayStyle,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: file.existsSync()
                  ? InteractiveViewer(
                      minScale: 1,
                      maxScale: 4,
                      child: Image.file(
                        file,
                        fit: BoxFit.contain,
                        width: MediaQuery.sizeOf(context).width,
                        height: MediaQuery.sizeOf(context).height,
                        filterQuality: FilterQuality.medium,
                        errorBuilder: (_, error, stackTrace) => const Icon(
                          Icons.broken_image_outlined,
                          color: Colors.white54,
                          size: 64,
                        ),
                      ),
                    )
                  : loadingOriginal
                      ? const SizedBox.shrink()
                      : const Icon(
                          Icons.broken_image_outlined,
                          color: Colors.white54,
                          size: 64,
                        ),
            ),
            if (loadingOriginal)
              const Center(
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    color: Color(0xFF9E9E9E),
                  ),
                ),
              ),
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
                    if ((title ?? '').isNotEmpty)
                      Expanded(
                        child: Text(
                          title!,
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
            if (onDownload != null || downloaded)
              Positioned(
                left: 0,
                right: 0,
                bottom: 28 + bottom,
                child: Center(
                  child: downloaded
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
                            onTap: downloading ? null : onDownload,
                            child: _OverlayChip(
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (downloading)
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
                                    downloading ? '下载中…' : '下载',
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
