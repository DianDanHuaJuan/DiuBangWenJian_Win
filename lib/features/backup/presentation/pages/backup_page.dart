import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../app/di/service_locator.dart';
import '../../../../core/discovery/peer_registry.dart';
import '../../application/backup_engine.dart';
import '../../domain/backup_models.dart';

/// 文件备份专属页。交互对齐原客户端图库卡片，能力按施工方案：立即备份、继续、放弃、历史。
class BackupPage extends StatefulWidget {
  const BackupPage({super.key});

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  static const _green = Color(0xFF3D8A5A);
  static const _muted = Color(0xFF6D6C6A);

  late final BackupEngine _engine;
  List<BackupRun> _history = const [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _engine = serviceLocator.backupEngine();
    _engine.addListener(_onEngine);
    unawaited(_boot());
  }

  @override
  void dispose() {
    _engine.removeListener(_onEngine);
    super.dispose();
  }

  Future<void> _boot() async {
    await _engine.bootstrap();
    await _reloadHistory();
  }

  void _onEngine() {
    if (!mounted) return;
    setState(() {});
    if (_engine.activeRun == null) {
      unawaited(_reloadHistory());
    }
  }

  Future<void> _reloadHistory() async {
    final list = await _engine.history();
    if (mounted) setState(() => _history = list);
  }

  Future<void> _start() async {
    if (_busy) return;
    final active = _engine.activeRun;
    if (active != null) {
      _toast('请先继续或放弃当前未完成的备份');
      return;
    }
    final targets = _engine.nasOnlineTargets();
    if (!mounted) return;
    final selected = await showDialog<OnlinePeer>(
      context: context,
      builder: (ctx) => _GalleryBackupDialog(targets: targets),
    );
    if (selected == null || !mounted) return;

    setState(() => _busy = true);
    final err = await _engine.startNewBackup(
      peerFingerprint: selected.fingerprint,
      peerName: selected.name,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) _toast(err);
  }

  Future<void> _continue() async {
    setState(() => _busy = true);
    final err = await _engine.continueActive();
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) _toast(err);
  }

  Future<void> _abandon() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '放弃这次备份？',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              const Text(
                '未传完的文件会取消。已经传到对方的文件会保留。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: _muted, height: 1.4),
              ),
              const SizedBox(height: 24),
              _DialogButton(
                label: '继续备份',
                background: _green,
                foreground: Colors.white,
                onPressed: () => Navigator.pop(ctx, false),
              ),
              const SizedBox(height: 12),
              _DialogButton(
                label: '放弃',
                background: const Color(0xFFF3F4F6),
                foreground: const Color(0xFF374151),
                onPressed: () => Navigator.pop(ctx, true),
              ),
            ],
          ),
        ),
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    await _engine.abandonActive();
    await _reloadHistory();
    if (!mounted) return;
    setState(() => _busy = false);
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final active = _engine.activeRun;
    final scanning = _busy && active == null;

    return Scaffold(
      appBar: AppBar(
        leadingWidth: 150,
        leading: Tooltip(
          message: '返回设置页',
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => Navigator.of(context).maybePop(),
            child: const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.arrow_back_ios_new_rounded,
                    size: 22,
                    color: _muted,
                  ),
                  SizedBox(width: 2),
                  Text(
                    '返回设置页',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: _muted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _GalleryEntryCard(
                    enabled: !scanning,
                    onTap: _start,
                  ),
                  if (active != null) ...[
                    const SizedBox(height: 12),
                    _ActiveRunCard(
                      run: active,
                      looping: _engine.isRunningLoop,
                      busy: _busy,
                      onContinue:
                          active.status == BackupRunStatus.paused && !_busy
                          ? _continue
                          : null,
                      onAbandon: _busy ? null : _abandon,
                    ),
                  ],
                  const SizedBox(height: 16),
                  _HistoryCard(runs: _history),
                ],
              ),
            ),
          ),
          if (scanning) const _ScanOverlay(),
        ],
      ),
    );
  }
}

class _GalleryBackupDialog extends StatelessWidget {
  const _GalleryBackupDialog({required this.targets});

  final List<OnlinePeer> targets;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '即将备份图库中的全部图片和视频',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            const Text(
              '选择一台当前在线、且已开启文件共享的设备',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Color(0xFF6D6C6A), height: 1.4),
            ),
            const SizedBox(height: 22),
            if (targets.isEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 18),
                child: Text(
                  '没有在线且已开启 NAS 的设备',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14, color: Color(0xFFB42318)),
                ),
              )
            else
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.42,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (final peer in targets) ...[
                        _DialogButton(
                          label: peer.name.trim().isEmpty ? '未命名设备' : peer.name,
                          background: const Color(0xFF3D8A5A),
                          foreground: Colors.white,
                          onPressed: () => Navigator.pop(context, peer),
                        ),
                        const SizedBox(height: 12),
                      ],
                    ],
                  ),
                ),
              ),
            _DialogButton(
              label: '取消',
              background: const Color(0xFFF3F4F6),
              foreground: const Color(0xFF374151),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
      ),
    );
  }
}

class _DialogButton extends StatelessWidget {
  const _DialogButton({
    required this.label,
    required this.background,
    required this.foreground,
    required this.onPressed,
  });

  final String label;
  final Color background;
  final Color foreground;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: background,
          foregroundColor: foreground,
          elevation: 0,
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16),
        ),
      ),
    );
  }
}

class _GalleryEntryCard extends StatelessWidget {
  const _GalleryEntryCard({required this.enabled, required this.onTap});

  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: enabled ? onTap : null,
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xFFE6E2DC)),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFF3D8A5A).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.photo_library_outlined,
                  color: Color(0xFF3D8A5A),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  '备份图库',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: enabled
                    ? const Color(0xFF6D6C6A)
                    : const Color(0xFFBDB7AE),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActiveRunCard extends StatelessWidget {
  const _ActiveRunCard({
    required this.run,
    required this.looping,
    required this.busy,
    required this.onContinue,
    required this.onAbandon,
  });

  final BackupRun run;
  final bool looping;
  final bool busy;
  final VoidCallback? onContinue;
  final VoidCallback? onAbandon;

  @override
  Widget build(BuildContext context) {
    final paused = run.status == BackupRunStatus.paused;
    final done = run.successCount + run.skippedCount + run.failedCount;
    final progress = run.totalCount == 0 ? 0.0 : done / run.totalCount;
    final statusColor = paused ? const Color(0xFFB54708) : const Color(0xFF3D8A5A);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE6E2DC)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  paused ? Icons.pause_circle_outline : Icons.autorenew_rounded,
                  color: statusColor,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      paused ? '未完成的备份' : '正在备份',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      run.peerName,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF6D6C6A),
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  paused ? '已中断' : (looping ? '传输中' : '进行中'),
                  style: TextStyle(
                    color: statusColor,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          LinearProgressIndicator(
            value: progress.clamp(0.0, 1.0),
            minHeight: 8,
            borderRadius: BorderRadius.circular(999),
            color: statusColor,
            backgroundColor: const Color(0xFFE7E3DA),
          ),
          const SizedBox(height: 10),
          Text(
            '$done / ${run.totalCount} · 成功 ${run.successCount} · 跳过 ${run.skippedCount} · 失败 ${run.failedCount}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: const Color(0xFF6D6C6A),
            ),
          ),
          if (paused && (run.errorMessage?.trim().isNotEmpty ?? false)) ...[
            const SizedBox(height: 8),
            Text(
              run.errorMessage!,
              style: const TextStyle(fontSize: 13, color: Color(0xFFB42318)),
            ),
          ],
          const SizedBox(height: 14),
          if (onContinue != null) ...[
            _DialogButton(
              label: '继续',
              background: const Color(0xFF3D8A5A),
              foreground: Colors.white,
              onPressed: onContinue!,
            ),
            const SizedBox(height: 10),
          ],
          _DialogButton(
            label: busy ? '正在处理…' : '放弃',
            background: const Color(0xFFC53030),
            foreground: Colors.white,
            onPressed: onAbandon,
          ),
        ],
      ),
    );
  }
}

class _ScanOverlay extends StatelessWidget {
  const _ScanOverlay();

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.28),
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 320),
            margin: const EdgeInsets.symmetric(horizontal: 24),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: const Color(0xFFE8F1FB),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Icon(
                        Icons.sync_rounded,
                        color: Color(0xFF2B6CB0),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '正在读取整机图库',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                const Text(
                  '正在找出可备份的图片和视频。',
                  style: TextStyle(color: Color(0xFF6D6C6A), height: 1.4),
                ),
                const SizedBox(height: 16),
                const LinearProgressIndicator(
                  minHeight: 8,
                  borderRadius: BorderRadius.all(Radius.circular(999)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({required this.runs});

  final List<BackupRun> runs;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE6E2DC)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '备份记录',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '最近的立即备份结果，包含成功、跳过和失败数量。',
            style: TextStyle(fontSize: 13, color: Color(0xFF6D6C6A), height: 1.4),
          ),
          const SizedBox(height: 14),
          if (runs.isEmpty)
            const Text(
              '还没有可展示的备份记录。',
              style: TextStyle(fontSize: 13, color: Color(0xFF6D6C6A)),
            )
          else
            for (final run in runs) ...[
              _HistoryTile(run: run),
              if (run != runs.last) const SizedBox(height: 10),
            ],
        ],
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.run});

  final BackupRun run;

  @override
  Widget build(BuildContext context) {
    final labelColor = switch (run.status) {
      BackupRunStatus.success => const Color(0xFF027A48),
      BackupRunStatus.running || BackupRunStatus.paused => const Color(0xFF175CD3),
      BackupRunStatus.cancelled => const Color(0xFFB54708),
      BackupRunStatus.failed => const Color(0xFFB42318),
    };
    final ended = run.endedAtMs ?? run.startedAtMs;
    final time = DateTime.fromMillisecondsSinceEpoch(ended);
    final stamp =
        '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} '
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F7F4),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '立即备份 · $stamp',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: labelColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  run.status.label,
                  style: TextStyle(
                    color: labelColor,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${run.peerName} · 备份 ${run.successCount} 个 · 跳过 ${run.skippedCount} 个 · 失败 ${run.failedCount} 个',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
