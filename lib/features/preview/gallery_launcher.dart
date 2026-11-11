import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/file_provider/file_entry.dart';
import 'presentation/pages/gallery_page.dart';

/// Preview 模块对外唯一打开入口（doc/01 期 B / E2）。
///
/// `features/devices` 等只应 import 本文件，勿直接依赖 [GalleryPage] 实现细节。
/// 不切换 [SystemUiMode]，避免退出时壳底栏随 inset 抬起。
Future<void> openGalleryPreview({
  required BuildContext context,
  required List<FileEntry> mediaFiles,
  required FileEntry current,
  required bool isSelf,
  String? peerFingerprint,
  Map<String, Uint8List> thumbnails = const {},
}) async {
  if (mediaFiles.isEmpty) return;
  var initialIndex = mediaFiles.indexWhere(
    (e) =>
        e.rootId == current.rootId && e.relativePath == current.relativePath,
  );
  if (initialIndex < 0) initialIndex = 0;

  if (!context.mounted) return;
  await Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder(
      opaque: true,
      barrierColor: Colors.black,
      transitionDuration: const Duration(milliseconds: 180),
      reverseTransitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (context, animation, secondaryAnimation) => GalleryPage(
        mediaFiles: mediaFiles,
        initialIndex: initialIndex,
        isSelf: isSelf,
        peerFingerprint: peerFingerprint,
        thumbnails: thumbnails,
      ),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        return FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
          child: child,
        );
      },
    ),
  );
}
