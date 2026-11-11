import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../app/di/service_locator.dart';
import '../../../../core/task/transfer_task.dart';
import '../../../../core/transfer/nas_transfer_service.dart';

/// 贴在底栏上方的传输提示。只认本进程 [NasTransferService] live 任务，事件驱动刷新。
class TransferProgressBar extends StatefulWidget {
  const TransferProgressBar({super.key});

  @override
  State<TransferProgressBar> createState() => _TransferProgressBarState();
}

class _TransferProgressBarState extends State<TransferProgressBar> {
  static const _sizeDuration = Duration(milliseconds: 220);
  static const _doneHold = Duration(seconds: 2);

  Timer? _doneTimer;
  TransferTask? _current;
  var _collapsed = false;
  var _sawDownload = false;
  var _sawUpload = false;
  var _batchIndex = 0;
  var _batchTotal = 0;
  var _isDownloadBatch = true;
  double? _batchProgress;
  String? _doneText;
  NasTransferService? _xfer;

  @override
  void initState() {
    super.initState();
    _xfer = serviceLocator.nasTransferService()..addListener(_onXferChanged);
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    await _xfer?.ensureColdStartCleanup();
    await _refresh();
  }

  void _onXferChanged() => unawaited(_refresh());

  @override
  void dispose() {
    _doneTimer?.cancel();
    _xfer?.removeListener(_onXferChanged);
    super.dispose();
  }

  Future<void> _refresh() async {
    final xfer = _xfer;
    if (xfer == null) return;
    final active = await xfer.snapshotLiveTasks();
    final downloads = active.where(_isDownload).toList();
    final uploads = active.where((task) => !_isDownload(task)).toList();
    if (downloads.isNotEmpty) _sawDownload = true;
    if (uploads.isNotEmpty) _sawUpload = true;

    final finished = <String>[];
    if (_sawDownload && downloads.isEmpty) {
      final stats = xfer.batchDownloadStats();
      final ok = stats['ok'] as int? ?? 0;
      final fail = stats['fail'] as int? ?? 0;
      final planned = stats['planned'] as int? ?? (ok + fail);
      if (ok > 0 && fail == 0) {
        finished.add(planned > 1 ? '下载完成 · $ok 个' : '下载完成');
      } else if (ok > 0 && fail > 0) {
        finished.add('下载结束：成功 $ok · 失败 $fail');
      } else if (fail > 0) {
        finished.add('下载失败（$fail）');
      } else {
        finished.add('下载结束');
      }
      _sawDownload = false;
    }
    if (_sawUpload && uploads.isEmpty) {
      final stats = xfer.batchUploadStats();
      final ok = stats['ok'] as int? ?? 0;
      final fail = stats['fail'] as int? ?? 0;
      final planned = stats['planned'] as int? ?? (ok + fail);
      if (ok > 0 && fail == 0) {
        finished.add(planned > 1 ? '上传完成 · $ok 个' : '上传完成');
      } else if (ok > 0 && fail > 0) {
        finished.add('上传结束：成功 $ok · 失败 $fail');
      } else if (fail > 0) {
        finished.add('上传失败（$fail）');
      } else {
        finished.add('上传完成');
      }
      _sawUpload = false;
    }

    final preferDownload = downloads.isNotEmpty;
    final focus = preferDownload
        ? downloads
        : uploads.isNotEmpty
            ? uploads
            : active;
    TransferTask? current;
    for (final task in focus) {
      if (task.state == TransferTaskState.transferring) {
        current = task;
        break;
      }
    }
    current ??= focus.isEmpty ? null : focus.first;

    final isDownload = current == null || _isDownload(current);
    final stats = isDownload
        ? xfer.batchDownloadStats()
        : xfer.batchUploadStats();
    final doneCount =
        (stats['ok'] as int? ?? 0) + (stats['fail'] as int? ?? 0);
    final planned = stats['planned'] as int? ?? 0;
    final liveCount = focus.length;
    final total = planned > 0 ? planned : doneCount + liveCount;
    final index = total <= 0
        ? 0
        : (liveCount > 0 ? (doneCount + 1).clamp(1, total) : doneCount);
    final progress = _batchFraction(
      doneCount: doneCount,
      total: total,
      live: focus,
    );

    if (!mounted) return;

    if (finished.isNotEmpty) {
      _doneTimer?.cancel();
      _doneTimer = Timer(_doneHold, () {
        if (!mounted) return;
        setState(() => _doneText = null);
      });
    }
    setState(() {
      if (finished.isNotEmpty) {
        // 完成态与展开进度同高，避免先变矮再消失。
        _collapsed = false;
        _doneText = finished.join(' · ');
      }
      _current = current;
      _batchIndex = index;
      _batchTotal = total;
      _isDownloadBatch = isDownload;
      _batchProgress = progress;
    });
  }

  bool _isDownload(TransferTask task) =>
      task.type == TransferTaskType.nasDownload ||
      task.type == TransferTaskType.p2pDownload;

  /// 按「已完成文件 + 进行中文件的字节占比」估算整批进度。
  double? _batchFraction({
    required int doneCount,
    required int total,
    required List<TransferTask> live,
  }) {
    if (total <= 0) return null;
    var units = doneCount.toDouble();
    for (final task in live) {
      if (task.sizeBytes > 0) {
        units += (task.bytesTransferred / task.sizeBytes).clamp(0.0, 1.0);
      } else if (task.state == TransferTaskState.transferring) {
        units += 0.15;
      }
    }
    return (units / total).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final task = _current;
    final done = _doneText;
    final primary = Theme.of(context).colorScheme.primary;
    final progress = _batchProgress;

    final Widget body;
    if (done != null) {
      body = _paddedCard(
        child: _statusBody(title: done, progress: null, centerTitle: true),
      );
    } else if (task != null && _collapsed) {
      body = Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _collapsed = false),
          child: _FloatingCard(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: SizedBox(
                height: 10,
                width: double.infinity,
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 10,
                  color: primary,
                  backgroundColor: const Color(0xFFE7E3DA),
                ),
              ),
            ),
          ),
        ),
      );
    } else if (task != null) {
      body = Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _collapsed = true),
          child: _FloatingCard(
            child: _statusBody(
              title: _label(task),
              progress: progress,
              progressColor: primary,
              trailing: const Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 22,
                color: Color(0xFF8B867C),
              ),
            ),
          ),
        ),
      );
    } else {
      // 交给 AnimatedSize 收到 0，避免瞬间掏空底栏。
      body = const SizedBox(width: double.infinity, height: 0);
    }

    return AnimatedSize(
      alignment: Alignment.bottomCenter,
      duration: _sizeDuration,
      curve: Curves.easeOutCubic,
      child: body,
    );
  }

  Widget _paddedCard({required Widget child}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: _FloatingCard(child: child),
    );
  }

  /// 进行中 / 完成共用同一骨架高度，避免完成瞬间留白。
  Widget _statusBody({
    required String title,
    required double? progress,
    Color? progressColor,
    Widget? trailing,
    bool centerTitle = false,
  }) {
    const titleStyle = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w700,
      color: Color(0xFF1A1918),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (centerTitle)
            SizedBox(
              height: 22,
              width: double.infinity,
              child: Center(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: titleStyle,
                ),
              ),
            )
          else
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: titleStyle,
                  ),
                ),
                trailing ??
                    const SizedBox(
                      width: 22,
                      height: 22,
                    ),
              ],
            ),
          const SizedBox(height: 10),
          if (progressColor != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 6,
                color: progressColor,
                backgroundColor: const Color(0xFFE7E3DA),
              ),
            )
          else
            const SizedBox(height: 6),
        ],
      ),
    );
  }

  String _label(TransferTask task) {
    final action = _isDownloadBatch ? '正在下载' : '正在上传';
    if (_batchTotal <= 1) {
      return '$action ${task.fileName}';
    }
    return '$action $_batchIndex/$_batchTotal · ${task.fileName}';
  }
}

class _FloatingCard extends StatelessWidget {
  const _FloatingCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: child,
      ),
    );
  }
}
