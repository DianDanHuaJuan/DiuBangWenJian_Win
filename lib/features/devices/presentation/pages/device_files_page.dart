import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../../../../app/di/service_locator.dart';
import '../../../../app/router/peer_session_navigation.dart';
import '../../../../app/router/route_paths.dart';
import '../../../../app/ui/app_dialog.dart';
import '../../../../core/common/app_logger.dart';
import '../../../../core/file_provider/file_entry.dart';
import '../../../../core/platform/browse_surface_labels.dart';
import '../../../../core/storage/external_volume_browser.dart';
import '../../../home/presentation/grid_selection_chrome.dart';
import '../cubits/device_files_cubit.dart';
import '../drag_select.dart';
import '../../domain/category_download_run.dart';
import '../widgets/upload_floating_actions.dart';

/// 外置多卷列表中的「磁盘」条目（相对路径为空 + extvol rootId）。
bool _isVolumeEntry(FileEntry entry) {
  return entry.isDirectory &&
      entry.relativePath.isEmpty &&
      entry.rootId.startsWith(ExternalVolumeBrowser.rootIdPrefix);
}

/// 设备文件浏览页（本机 / 对端共享区）。
///
/// 网格与四分类对齐原 DiuBangNASClient FileListView / FileCategoryFilter。
class DeviceFilesPage extends StatelessWidget {
  const DeviceFilesPage({
    super.key,
    required this.isSelf,
    this.peerId,
    this.peerTitle,
  });

  final bool isSelf;
  final String? peerId;
  final String? peerTitle;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) =>
          DeviceFilesCubit(isSelf: isSelf, peerId: peerId, peerTitle: peerTitle)
            ..start(),
      child: const _DeviceFilesView(),
    );
  }
}

class _DeviceFilesView extends StatelessWidget {
  const _DeviceFilesView();

  /// 浏览层是否应「吃掉」返回。目录树内退一层，不改媒体墙/目录树切换。
  bool _consumeBrowseBack(DeviceFilesCubit cubit, DeviceFilesState state) {
    if (_exitGridSelection(cubit, state)) return true;
    if (state.canGoUpInTree) {
      cubit.goUp();
      return true;
    }
    return false;
  }

  /// 需要拦截系统返回时为 true。本机路由根交给 Navigator pop，避免
  /// `canPop: false` + `pop/maybePop` 死循环。
  /// 多选时，返回只退出多选。
  bool _exitGridSelection(DeviceFilesCubit cubit, DeviceFilesState state) {
    if (!state.selectionMode) return false;
    cubit.exitSelection();
    return true;
  }

  bool _interceptSystemBack(DeviceFilesCubit cubit, DeviceFilesState state) {
    if (state.selectionMode) return true;
    if (state.canGoUpInTree) return true;
    // 对端根：须 leave + go，不能裸 pop。
    return !cubit.isSelf;
  }

  void _handleBack(BuildContext context, DeviceFilesState state) {
    final cubit = context.read<DeviceFilesCubit>();
    if (_exitGridSelection(cubit, state)) return;
    if (_consumeBrowseBack(cubit, state)) return;
    if (!cubit.isSelf) {
      unawaited(goToDevicesList(context));
      return;
    }
    // 本机根：与 PopScope(canPop: true) 一致，只 pop 一次。
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(RoutePaths.devices);
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<DeviceFilesCubit, DeviceFilesState>(
      listenWhen: (prev, next) =>
          next.blockedDirectoryMessage != null &&
          next.blockedDirectoryMessage != prev.blockedDirectoryMessage,
      listener: (context, state) {
        final msg = state.blockedDirectoryMessage;
        if (msg == null) return;
        final cubit = context.read<DeviceFilesCubit>();
        showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('无法进入'),
            content: Text(msg),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  cubit.clearBlockedDirectoryMessage();
                },
                child: const Text('知道了'),
              ),
            ],
          ),
        ).whenComplete(cubit.clearBlockedDirectoryMessage);
      },
      child: BlocBuilder<DeviceFilesCubit, DeviceFilesState>(
        builder: (context, state) {
          final cubit = context.read<DeviceFilesCubit>();
          final scheme = Theme.of(context).colorScheme;
          final intercept = _interceptSystemBack(cubit, state);
          final showUpload = !state.selectionMode &&
              (!state.isDirectoryTree ||
                  state.treeAnchor == DirectoryTreeAnchor.shareRoot ||
                  (state.isOnVolume &&
                      state.externalVolumePath != null &&
                      state.externalVolumePath!.isNotEmpty));

          return PopScope(
            // 铁律：canPop==false 时，onPopInvoked 内禁止再 pop/maybePop。
            canPop: !intercept,
            onPopInvokedWithResult: (didPop, _) {
              if (didPop) return;
              // 此处只做浏览消费或 goToDevicesList（go），绝不 pop。
              if (_exitGridSelection(cubit, state)) return;
              if (_consumeBrowseBack(cubit, state)) return;
              if (!cubit.isSelf) {
                unawaited(goToDevicesList(context));
              }
            },
            child: Scaffold(
              backgroundColor: Colors.white,
              appBar: AppBar(
                backgroundColor: Colors.white,
                elevation: 0,
                leading: IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => _handleBack(context, state),
                ),
                title: Text(cubit.appBarTitle),
                actions: [
                  if (state.isDirectoryTree &&
                      state.treeAnchor != DirectoryTreeAnchor.volumePicker &&
                      !state.selectionMode)
                    IconButton(
                      tooltip: '新建文件夹',
                      icon: const Icon(Icons.create_new_folder_outlined),
                      onPressed: () => unawaited(_createFolder(context)),
                    ),
                ],
              ),
              body: Stack(
                children: [
                  Positioned.fill(
                    child: _ExitGridSelectionOffFiles(
                      child: _PeerFileSignals(
                        hintEnabled: !cubit.isSelf,
                        gridSelect: !state.isDirectoryTree,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
                              child: Row(
                                children: [
                                  _SlidingAccessModeToggle(
                                    mediaWallSelected: state.isMediaWall,
                                    onSelectMediaWall: () => cubit
                                        .setAccessMode(BrowseAccessMode.mediaWall),
                                    onSelectDirectoryTree: () => cubit
                                        .setAccessMode(
                                            BrowseAccessMode.directoryTree),
                                  ),
                                  const Spacer(),
                                  if (!cubit.isSelf && cubit.peerId != null)
                                    _PeerChatAction(peerId: cubit.peerId!),
                                ],
                              ),
                            ),
                            if (state.isDirectoryTree)
                              _DirectoryTreeToolRow(state: state)
                            else ...[
                              if (state.breadcrumbSegments.isNotEmpty)
                                _BreadcrumbBar(state: state),
                              Padding(
                                padding: EdgeInsets.fromLTRB(
                                  24,
                                  4,
                                  24,
                                  state.selectionMode ? 0 : 12,
                                ),
                                child: const _CategoryFilterBar(),
                              ),
                            ],
                            if (state.selectionMode && !state.isDirectoryTree)
                              _SelectionCountStrip(count: state.selected.length),
                            if (cubit.isSelf &&
                                state.isMediaWall &&
                                !state.category.isMediaLibraryCategory)
                              _SourceFilterBar(state: state),
                            if (state.error != null &&
                                state.blockedDirectoryMessage == null)
                              Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(24, 0, 24, 8),
                                child: Text(
                                  state.error!,
                                  style: TextStyle(
                                    color: scheme.error,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            Expanded(
                              child: RefreshIndicator(
                                color: const Color(0xFF3D8A5A),
                                onRefresh: cubit.refresh,
                                child: _FilesScrollBody(state: state),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (cubit.canUpload && cubit.peerId != null)
                    UploadFloatingActions(
                      peerId: cubit.peerId!,
                      showUploadAction: showUpload,
                      onUploadMediaTap: () => _upload(context, media: true),
                      onUploadFilesTap: () => _upload(context, media: false),
                    ),
                  if (state.selectionMode && state.isDirectoryTree)
                    const _DirectoryTreeSelectionBar(),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _createFolder(BuildContext context) async {
    final cubit = context.read<DeviceFilesCubit>();
    final name = await AppDialog.prompt(
      context,
      title: '新建文件夹',
      hint: '文件夹名称',
      okLabel: '创建',
    );
    if (name == null || name.trim().isEmpty) return;
    final ok = await cubit.createFolder(name);
    if (!context.mounted) return;
    if (!ok) {
      final err = cubit.state.error;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(err ?? '创建失败')),
        );
    }
  }

  Future<void> _upload(BuildContext context, {required bool media}) async {
    final cubit = context.read<DeviceFilesCubit>();
    final facade = serviceLocator.localPickFacade();
    final result = media
        ? await facade.pickMedia(context)
        : await facade.pickFiles();
    if (result.isEmpty) return;
    final files = [
      for (final item in result.items)
        if (item.localPath.isNotEmpty)
          (
            path: item.localPath,
            name: item.displayName.isNotEmpty
                ? item.displayName
                : p.basename(item.localPath),
            size: item.size,
          ),
    ];
    if (files.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('未选到可读文件')));
      }
      return;
    }
    final n = await cubit.uploadPicked(files);
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          // Flutter 3.38+：带 action 的 SnackBar 默认 persist，不设 false 会一直不消失。
          persist: false,
          duration: const Duration(seconds: 3),
          content: Text('已加入上传 $n 项'),
          action: SnackBarAction(
            label: '查看',
            onPressed: () => context.push(RoutePaths.transfers),
          ),
        ),
      );
  }
}

Future<void> openFilePreview(BuildContext context, FileEntry entry) async {
  final cubit = context.read<DeviceFilesCubit>();
  if (entry.isDirectory) return;
  final opened = await cubit.openMediaPreview(context, entry);
  if (opened || !context.mounted) return;
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(const SnackBar(content: Text('该类型暂不支持预览')));
}

/// 对齐原客户端 FileCategoryFilter：四分类等宽卡片。
class _CategoryFilterBar extends StatelessWidget {
  const _CategoryFilterBar();

  IconData _icon(FileCategoryFilter c) => switch (c) {
    FileCategoryFilter.photo => Icons.photo_outlined,
    FileCategoryFilter.video => Icons.videocam_outlined,
    FileCategoryFilter.document => Icons.description_outlined,
    FileCategoryFilter.other => Icons.folder_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final cubit = context.watch<DeviceFilesCubit>();
    final engine = serviceLocator.categoryDownloadEngine();
    return ListenableBuilder(
      listenable: engine,
      builder: (context, _) {
        final selected = cubit.state.category;
        final run = engine.activeRun;
        return Row(
          children: [
            for (final category in FileCategoryFilter.values)
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(
                    right: category != FileCategoryFilter.values.last ? 12 : 0,
                  ),
                  child: _CategoryCard(
                    category: category,
                    selected: selected == category,
                    icon: _icon(category),
                    run: run != null &&
                            !cubit.isSelf &&
                            run.matches(
                              peerFingerprint: cubit.peerId ?? '',
                              category: category,
                              scopePath: category.isMediaLibraryCategory
                                  ? ''
                                  : cubit.state.path,
                            )
                        ? run
                        : null,
                    onTap: () => cubit.setCategory(category),
                    onLongPress: cubit.isSelf
                        ? null
                        : () => unawaited(
                              _onCategoryLongPress(context, category),
                            ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _CategoryCard extends StatelessWidget {
  const _CategoryCard({
    required this.category,
    required this.selected,
    required this.icon,
    required this.onTap,
    this.onLongPress,
    this.run,
  });

  final FileCategoryFilter category;
  final bool selected;
  final IconData icon;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final CategoryDownloadRun? run;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final fg = selected ? Colors.white : const Color(0xFF6D6C6A);
    return Material(
      color: selected ? primary : Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          height: 64,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? primary : const Color(0xFFE0E0E0),
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 20, color: fg),
              const SizedBox(height: 2),
              Text(
                category.label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.normal,
                  color: fg,
                ),
              ),
              if (run != null)
                Text(
                  run!.totalCount > 0
                      ? '${run!.successCount}/${run!.totalCount}'
                      : run!.status.label,
                  style: TextStyle(fontSize: 9, color: fg),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _onCategoryLongPress(
  BuildContext context,
  FileCategoryFilter category,
) async {
  final cubit = context.read<DeviceFilesCubit>();
  if (cubit.isSelf || cubit.peerId == null) return;
  final engine = serviceLocator.categoryDownloadEngine();
  await engine.bootstrap();
  if (!context.mounted) return;
  final scope = category.isMediaLibraryCategory ? '' : cubit.state.path;
  final active = engine.activeRun;
  if (active != null &&
      !active.matches(
        peerFingerprint: cubit.peerId!,
        category: category,
        scopePath: scope,
      )) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('请先继续或停止正在进行的「${active.category.label}」下载'),
      ),
    );
    return;
  }

  if (active == null) {
    final scopeHint = category.isMediaLibraryCategory
        ? '对端图库中的全部${category.label}'
        : '对端共享目录中的全部${category.label}';
    final ok = await AppDialog.confirm(
      context,
      title: '下载全部${category.label}？',
      message: '将在后台把$scopeHint逐个下载到本机。',
      okLabel: '下载',
    );
    if (!ok || !context.mounted) return;
    final err = await engine.start(
      peerFingerprint: cubit.peerId!,
      peerName: cubit.appBarTitle,
      category: category,
      scopePath: scope,
    );
    if (!context.mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    }
    return;
  }

  if (active.status == CategoryDownloadStatus.paused) {
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${category.label}下载已中断'),
        content: Text(active.errorMessage ?? '可以继续，或停止这次下载。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'stop'),
            child: const Text('停止'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'continue'),
            child: const Text('继续'),
          ),
        ],
      ),
    );
    if (!context.mounted || action == null) return;
    if (action == 'stop') {
      await engine.stopActive();
      return;
    }
    final err = await engine.continueActive();
    if (!context.mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    }
    return;
  }

  final stop = await AppDialog.confirm(
    context,
    title: '停止下载${category.label}？',
    message: '还没开始传的文件会取消。已经下载到本机的会保留。',
    okLabel: '停止',
    destructive: true,
  );
  if (!stop || !context.mounted) return;
  await engine.stopActive();
}

/// 目录树工具行：左【根目录|OTG】右【返回上一级】，等高对称。
class _DirectoryTreeToolRow extends StatelessWidget {
  const _DirectoryTreeToolRow({required this.state});

  final DeviceFilesState state;

  static const _toolH = 36.0;
  static const _accent = Color(0xFF3D8A5A);

  bool get _otgSideActive {
    final vol = state.externalVolumePath;
    if (vol == null || vol.isEmpty) return false;
    return state.otgVolumes.any(
      (v) =>
          v.path == vol ||
          v.path.replaceAll(r'\', '/') == vol.replaceAll(r'\', '/'),
    );
  }

  Future<void> _onGoUp(BuildContext context, DeviceFilesCubit cubit) async {
    final moved = await cubit.goUp();
    if (moved || !context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('已回到根目录'),
          duration: Duration(milliseconds: 1200),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<DeviceFilesCubit>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: SizedBox(
        height: _toolH,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _RootOtgToggle(
              height: _toolH,
              rootSelected: !_otgSideActive,
              otgEnabled: state.otgAvailable,
              onRoot: cubit.goToVolumeRoot,
              onOtg: state.otgAvailable ? cubit.goToOtg : null,
            ),
            const Spacer(),
            SizedBox(
              height: _toolH,
              child: OutlinedButton.icon(
                onPressed: () => _onGoUp(context, cubit),
                icon: const Icon(Icons.arrow_upward, size: 18),
                label: const Text('返回上一级', style: TextStyle(fontSize: 13)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _accent,
                  side: const BorderSide(color: _accent, width: 1.5),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  minimumSize: const Size(0, _toolH),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「根目录 | OTG」；高度与右侧按钮一致；无 OTG 时右段置灰。
class _RootOtgToggle extends StatelessWidget {
  const _RootOtgToggle({
    required this.rootSelected,
    required this.otgEnabled,
    required this.onRoot,
    required this.onOtg,
    this.height = 36,
  });

  final bool rootSelected;
  final bool otgEnabled;
  final VoidCallback onRoot;
  final VoidCallback? onOtg;
  final double height;

  static const _pad = 2.0;
  static const _segW = 56.0;
  static const _accent = Color(0xFF3D8A5A);

  @override
  Widget build(BuildContext context) {
    final onRootSide = rootSelected || !otgEnabled;
    final thumbLeft = onRootSide ? _pad : _pad + _segW;
    return SizedBox(
      width: _segW * 2 + _pad * 2,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFFEAF3EC),
          borderRadius: BorderRadius.circular(height / 2),
          border: Border.all(color: _accent, width: 1.5),
        ),
        child: Stack(
          children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              left: thumbLeft,
              top: _pad,
              width: _segW,
              height: height - _pad * 2,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular((height - _pad * 2) / 2),
                ),
              ),
            ),
            Row(
              children: [
                SizedBox(
                  width: _segW + _pad,
                  child: _MiniRootOtgHit(
                    label: '根目录',
                    selected: onRootSide,
                    enabled: true,
                    onTap: onRoot,
                  ),
                ),
                SizedBox(
                  width: _segW + _pad,
                  child: _MiniRootOtgHit(
                    label: 'OTG',
                    selected: !onRootSide,
                    enabled: otgEnabled,
                    onTap: onOtg ?? () {},
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniRootOtgHit extends StatelessWidget {
  const _MiniRootOtgHit({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = !enabled
        ? const Color(0xFFC5C2BA)
        : (selected ? const Color(0xFF3D8A5A) : const Color(0xFF8B867C));
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(16),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected && enabled ? FontWeight.w600 : FontWeight.w500,
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}

/// 媒体 | 目录：淡绿轨 + 白滑块；两端始终可点。
class _SlidingAccessModeToggle extends StatelessWidget {
  const _SlidingAccessModeToggle({
    required this.mediaWallSelected,
    required this.onSelectMediaWall,
    required this.onSelectDirectoryTree,
  });

  final bool mediaWallSelected;
  final VoidCallback onSelectMediaWall;
  final VoidCallback onSelectDirectoryTree;

  static const _trackH = 36.0;
  static const _pad = 3.0;
  static const _segW = 72.0;

  @override
  Widget build(BuildContext context) {
    final thumbLeft = mediaWallSelected ? _pad : _pad + _segW;
    return SizedBox(
      width: _segW * 2 + _pad * 2,
      height: _trackH,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFFEAF3EC),
          borderRadius: BorderRadius.circular(_trackH / 2),
        ),
        child: Stack(
          children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              left: thumbLeft,
              top: _pad,
              width: _segW,
              height: _trackH - _pad * 2,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular((_trackH - _pad * 2) / 2),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 6,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
              ),
            ),
            Row(
              children: [
                SizedBox(
                  width: _segW + _pad,
                  child: _SlidingSegHit(
                    padding: const EdgeInsets.only(left: _pad),
                    icon: Icons.photo_library_outlined,
                    label: BrowseSurfaceLabels.mediaWall,
                    selected: mediaWallSelected,
                    enabled: true,
                    onTap: onSelectMediaWall,
                  ),
                ),
                SizedBox(
                  width: _segW + _pad,
                  child: _SlidingSegHit(
                    padding: const EdgeInsets.only(right: _pad),
                    icon: Icons.folder_outlined,
                    label: BrowseSurfaceLabels.directoryTree,
                    selected: !mediaWallSelected,
                    enabled: true,
                    onTap: onSelectDirectoryTree,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SlidingSegHit extends StatelessWidget {
  const _SlidingSegHit({
    required this.icon,
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
    this.padding = EdgeInsets.zero,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;
  final EdgeInsets padding;

  static const _on = Color(0xFF3D8A5A);
  static const _off = Color(0xFF8B867C);
  static const _disabled = Color(0xFFC5C2BA);

  @override
  Widget build(BuildContext context) {
    final color = !enabled ? _disabled : (selected ? _on : _off);
    return Padding(
      padding: padding,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Center(
            child: Opacity(
              opacity: enabled ? 1 : 0.85,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 15, color: color),
                  const SizedBox(width: 4),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected && enabled
                          ? FontWeight.w700
                          : FontWeight.w400,
                      color: color,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 可下拉刷新的文件列表/网格（空态也可拉）。
class _FilesScrollBody extends StatelessWidget {
  const _FilesScrollBody({required this.state});

  final DeviceFilesState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (state.loading && state.visibleEntries.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 160),
          Center(child: CircularProgressIndicator()),
        ],
      );
    }
    if (state.visibleEntries.isEmpty && state.error == null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(
            height: 220,
            child: Center(
              child: Text(
                state.isVolumePicker && state.externalVolumes.isEmpty
                    ? '未检测到可用磁盘'
                    : '当前目录为空',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
          ),
        ],
      );
    }
    if (state.isDirectoryTree) {
      return _ExternalListBody(entries: state.visibleEntries);
    }
    return _GridBody(
      entries: state.visibleEntries,
      hasMore: state.hasMore,
      loadingMore: state.loadingMore,
    );
  }
}

class _SourceFilterBar extends StatelessWidget {
  const _SourceFilterBar({required this.state});

  final DeviceFilesState state;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<DeviceFilesCubit>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final s in ShareSourceFilter.values)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text(s.label),
                  selected: state.source == s,
                  onSelected: (_) => cubit.setSource(s),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 目录树：列表式文件夹浏览（非媒体分类墙）。
class _ExternalListBody extends StatefulWidget {
  const _ExternalListBody({required this.entries});

  final List<FileEntry> entries;

  @override
  State<_ExternalListBody> createState() => _ExternalListBodyState();
}

class _ExternalListBodyState extends State<_ExternalListBody> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  IconData _icon(FileEntry e) {
    if (_isVolumeEntry(e)) return Icons.storage_rounded;
    if (e.isDirectory) return Icons.folder;
    if (e.isImage) return Icons.image_outlined;
    if (e.isVideo) return Icons.videocam_outlined;
    if (e.isAudio) return Icons.audiotrack;
    return Icons.insert_drive_file_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<DeviceFilesCubit>();
    final scheme = Theme.of(context).colorScheme;
    final entries = widget.entries;
    final bottom = cubit.state.selectionMode ? 168.0 : 100.0;
    final volumePicker =
        cubit.state.treeAnchor == DirectoryTreeAnchor.volumePicker;
    final list = ListView.builder(
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(8, 0, 8, bottom),
      itemExtent: 73,
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        final selected = cubit.isSelected(entry);
        final isVolume = _isVolumeEntry(entry);
        final canSelect = !volumePicker && !isVolume;
        return _PeerFileTouch(
          entry: entry,
          child: Column(
            children: [
              Expanded(
                child: IgnorePointer(
                  child: ListTile(
                    leading: Icon(
                      _icon(entry),
                      color: entry.isDirectory
                          ? const Color(0xFF3D8A5A)
                          : scheme.onSurfaceVariant,
                    ),
                    title: Text(
                      entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: isVolume
                        ? const Text('磁盘')
                        : entry.isDirectory
                            ? const Text('文件夹')
                            : Text(entry.sizeLabel),
                    trailing: cubit.state.selectionMode && canSelect
                        ? Icon(
                            selected
                                ? Icons.check_circle
                                : Icons.radio_button_unchecked,
                            color: selected ? scheme.primary : null,
                          )
                        : entry.isDirectory
                            ? const Icon(Icons.chevron_right)
                            : null,
                  ),
                ),
              ),
              const Divider(height: 1),
            ],
          ),
        );
      },
    );
    return DragSelectLayer(
      enabled: !volumePicker,
      selectionActive: cubit.state.selectionMode,
      controller: _scroll,
      metrics: UniformDragMetrics.fileList,
      keys: [
        for (final entry in entries)
          (volumePicker || _isVolumeEntry(entry)) ? null : _fileKey(entry),
      ],
      selected: cubit.state.selected,
      commitOnLongPress: false,
      onSelection: cubit.applyDragSelection,
      onStationaryLongPress: (index) {
        final entry = entries[index];
        if (volumePicker || _isVolumeEntry(entry)) return;
        if (!cubit.isSelf && !entry.isDirectory) {
          unawaited(_showPeerFileActions(context, cubit, entry));
          return;
        }
        if (!cubit.state.selectionMode) {
          cubit.enterSelection();
        }
        cubit.toggleSelect(entry);
      },
      child: list,
    );
  }
}

class _BreadcrumbBar extends StatelessWidget {
  const _BreadcrumbBar({required this.state});

  final DeviceFilesState state;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<DeviceFilesCubit>();
    final scheme = Theme.of(context).colorScheme;
    final segments = state.breadcrumbSegments;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            InkWell(
              onTap: () => cubit.goBreadcrumb(-1),
              child: Text(
                '根目录',
                style: TextStyle(
                  color: scheme.primary,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ),
            for (var i = 0; i < segments.length; i++) ...[
              Text(' / ', style: TextStyle(color: scheme.onSurfaceVariant)),
              InkWell(
                onTap: i == segments.length - 1
                    ? null
                    : () => cubit.goBreadcrumb(i),
                child: Text(
                  segments[i],
                  style: TextStyle(
                    color: i == segments.length - 1
                        ? scheme.onSurface
                        : scheme.primary,
                    fontWeight: FontWeight.w400,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 对齐原客户端：4 列、间距 4、正方形格子；视口驱动缩略图队列 + 触底 loadMore。
///
/// 滚动中关闭 preload、延迟 loadMore；缩略图按格 Stream 刷新（非整表 setState）。
class _GridBody extends StatefulWidget {
  const _GridBody({
    required this.entries,
    required this.hasMore,
    required this.loadingMore,
  });

  final List<FileEntry> entries;
  final bool hasMore;
  final bool loadingMore;

  @override
  State<_GridBody> createState() => _GridBodyState();
}

class _GridBodyState extends State<_GridBody> {
  static const _crossAxisCount = 4;
  static const _scrollSettleDelay = Duration(milliseconds: 72);
  final _scroll = ScrollController();
  var _isScrollActive = false;
  var _pendingLoadMore = false;
  var _lastScrollOffset = 0.0;
  var _scrollBias = 0;
  Timer? _scrollSettleTimer;
  int? _lastFirst;
  int? _lastLast;
  bool? _lastAllowPreload;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScrollMetrics);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _requestViewport();
    });
  }

  @override
  void didUpdateWidget(covariant _GridBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entries.length != widget.entries.length) {
      _lastFirst = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => _requestViewport());
    }
  }

  @override
  void dispose() {
    _scrollSettleTimer?.cancel();
    _scroll.removeListener(_onScrollMetrics);
    _scroll.dispose();
    super.dispose();
  }

  bool _onScrollNotification(ScrollNotification n) {
    if (n is ScrollUpdateNotification || n is ScrollStartNotification) {
      _markScrollActive();
    }
    if (n is ScrollEndNotification) {
      _scheduleSettledScrollWork();
    }
    return false;
  }

  void _markScrollActive() {
    _scrollSettleTimer?.cancel();
    if (!_isScrollActive) {
      _isScrollActive = true;
    }
  }

  void _scheduleSettledScrollWork() {
    _scrollSettleTimer?.cancel();
    _scrollSettleTimer = Timer(_scrollSettleDelay, () {
      if (!mounted) return;
      _isScrollActive = false;
      _requestViewport(force: true);
      _maybeLoadMore(force: true);
    });
  }

  void _onScrollMetrics() {
    if (!_scroll.hasClients) return;
    final offset = _scroll.offset;
    if (offset > _lastScrollOffset + 0.5) {
      _scrollBias = 1;
    } else if (offset < _lastScrollOffset - 0.5) {
      _scrollBias = -1;
    }
    _lastScrollOffset = offset;
    _requestViewport();
    _maybeLoadMore();
  }

  void _maybeLoadMore({bool force = false}) {
    if (!widget.hasMore || widget.loadingMore) return;
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final nearEnd = pos.pixels >= pos.maxScrollExtent - 480;
    if (!nearEnd) {
      _pendingLoadMore = false;
      return;
    }
    if (_isScrollActive && !force) {
      _pendingLoadMore = true;
      return;
    }
    if (_pendingLoadMore || nearEnd) {
      _pendingLoadMore = false;
      context.read<DeviceFilesCubit>().loadMore();
    }
  }

  void _requestViewport({bool force = false}) {
    if (!mounted || !_scroll.hasClients) return;
    final cubit = context.read<DeviceFilesCubit>();
    final extent = _scroll.position.viewportDimension;
    final offset = _scroll.offset;
    // 近似：正方形格子 + 间距 4；左右 padding 24*2。
    // 注意：MediaQuery 全窗宽度在有侧栏时会大于 Grid 实际宽度，导致 cell/rowH
    // 估大 → lastIndex 偏小 → 屏下半可见格不进请求（thumb_diag 对比两项宽度）。
    final mediaW = MediaQuery.sizeOf(context).width;
    final box = context.findRenderObject() as RenderBox?;
    final layoutW = box != null && box.hasSize ? box.size.width : null;
    final width = mediaW - 48;
    final cell = (width - (_crossAxisCount - 1) * 4) / _crossAxisCount;
    if (cell <= 0) return;
    final rowH = cell + 4;
    final firstRow = (offset / rowH).floor().clamp(0, 1 << 20);
    final lastRow = ((offset + extent) / rowH).ceil().clamp(0, 1 << 20);
    final first = (firstRow * _crossAxisCount).clamp(0, widget.entries.length);
    final last = ((lastRow + 1) * _crossAxisCount - 1).clamp(
      0,
      widget.entries.isEmpty ? 0 : widget.entries.length - 1,
    );
    // 若用 layout 实际宽度重算，可见区会覆盖到哪（仅诊断，不改调度）。
    int? altLast;
    double? altCell;
    if (layoutW != null && layoutW > 48) {
      altCell = (layoutW - 48 - (_crossAxisCount - 1) * 4) / _crossAxisCount;
      if (altCell > 0) {
        final altRowH = altCell + 4;
        final altLastRow =
            ((offset + extent) / altRowH).ceil().clamp(0, 1 << 20);
        altLast = ((altLastRow + 1) * _crossAxisCount - 1).clamp(
          0,
          widget.entries.isEmpty ? 0 : widget.entries.length - 1,
        );
      }
    }
    final allowPreload = !_isScrollActive;
    if (!force &&
        _lastFirst == first &&
        _lastLast == last &&
        _lastAllowPreload == allowPreload) {
      return;
    }
    _lastFirst = first;
    _lastLast = last;
    _lastAllowPreload = allowPreload;
    AppLogger.log(
      'grid viewport',
      scope: 'thumb_diag',
      details: {
        'force': force,
        'entries': widget.entries.length,
        'offset': offset.toStringAsFixed(1),
        'extent': extent.toStringAsFixed(1),
        'mediaW': mediaW.toStringAsFixed(1),
        'layoutW': layoutW?.toStringAsFixed(1) ?? '',
        'usedWidth': width.toStringAsFixed(1),
        'cell': cell.toStringAsFixed(1),
        'rowH': rowH.toStringAsFixed(1),
        'firstRow': firstRow,
        'lastRow': lastRow,
        'first': first,
        'last': last,
        'altCell': altCell?.toStringAsFixed(1) ?? '',
        'altLast': altLast ?? -1,
        'indexGap': altLast == null ? -1 : (altLast - last),
        'allowPreload': allowPreload,
        'scrollBias': _scrollBias,
        'isSelf': cubit.isSelf,
        'rootId': cubit.state.rootId,
        'category': cubit.state.category.name,
      },
    );
    cubit.requestVisibleThumbs(
      entries: widget.entries,
      firstIndex: first,
      lastIndex: last,
      allowPreload: allowPreload,
      scrollBias: _scrollBias,
    );
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.entries.length + (widget.hasMore ? 1 : 0);
    final cubit = context.read<DeviceFilesCubit>();
    return NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: DragSelectLayer(
        enabled: true,
        selectionActive: cubit.state.selectionMode,
        controller: _scroll,
        metrics: UniformDragMetrics.grid,
        keys: [
          for (final entry in widget.entries)
            entry.isDirectory ? null : _fileKey(entry),
        ],
        selected: cubit.state.selected,
        onSelection: cubit.applyDragSelection,
        child: GridView.builder(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        cacheExtent: MediaQuery.sizeOf(context).height,
        padding: EdgeInsets.fromLTRB(
          24,
          0,
          24,
          _gridBottomPad(context),
        ),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: _crossAxisCount,
          crossAxisSpacing: 4,
          mainAxisSpacing: 4,
          childAspectRatio: 1,
        ),
        itemCount: count,
        itemBuilder: (context, index) {
          if (index >= widget.entries.length) {
            return const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          }
          return _EntryTile(entry: widget.entries[index]);
        },
      ),
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry});

  final FileEntry entry;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<DeviceFilesCubit>();
    final state = cubit.state;
    final selected = cubit.isSelected(entry);

    return RepaintBoundary(
      child: _PeerFileTouch(
        entry: entry,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(
              color: Colors.white,
              child: _ThumbOrIcon(entry: entry),
            ),
            if (state.selectionMode && !entry.isDirectory)
              Positioned(
                top: 4,
                right: 4,
                child: Icon(
                  selected ? Icons.check_circle : Icons.radio_button_unchecked,
                  size: 20,
                  color: selected
                      ? Theme.of(context).colorScheme.primary
                      : Colors.white70,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ThumbOrIcon extends StatelessWidget {
  const _ThumbOrIcon({required this.entry});

  final FileEntry entry;

  Color _bg() {
    if (entry.isDirectory) return const Color(0xFFEAF4EC);
    if (entry.isImage) return const Color(0xFFF1EFE7);
    if (entry.isVideo) return const Color(0xFFE9EEF7);
    const docs = {'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx'};
    if (docs.contains(entry.extension)) return const Color(0xFFF4ECE7);
    return const Color(0xFFF2F1EE);
  }

  Color _fg() {
    if (entry.isDirectory) return const Color(0xFF3D8A5A);
    if (entry.isImage) return const Color(0xFF9B7A48);
    if (entry.isVideo) return const Color(0xFF5777A8);
    const docs = {'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx'};
    if (docs.contains(entry.extension)) return const Color(0xFFB5664C);
    return const Color(0xFF7C7974);
  }

  IconData _icon() {
    if (_isVolumeEntry(entry)) return Icons.storage_rounded;
    if (entry.isDirectory) return Icons.folder;
    if (entry.isImage) return Icons.image;
    if (entry.isVideo) return Icons.videocam;
    switch (entry.extension) {
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'doc':
      case 'docx':
        return Icons.article;
      case 'xls':
      case 'xlsx':
        return Icons.grid_on;
      case 'ppt':
      case 'pptx':
        return Icons.slideshow;
      case 'zip':
      case 'rar':
      case '7z':
        return Icons.folder_zip;
      case 'mp3':
      case 'wav':
      case 'flac':
        return Icons.audio_file;
      default:
        return Icons.insert_drive_file;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (entry.isDirectory || (!entry.isImage && !entry.isVideo)) {
      final parts = entry.relativePath
          .split('/')
          .where((s) => s.isNotEmpty)
          .toList();
      final label = entry.name.trim().isNotEmpty
          ? entry.name.trim()
          : (parts.isEmpty ? '' : parts.last);
      return ColoredBox(
        color: _bg(),
        child: Column(
          children: [
            Expanded(
              child: Center(child: Icon(_icon(), size: 28, color: _fg())),
            ),
            if (label.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
                child: Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 10,
                    height: 1.2,
                    color: Color(0xFF4B5563),
                  ),
                ),
              ),
          ],
        ),
      );
    }
    final cubit = context.read<DeviceFilesCubit>();
    // 按格订阅 cache.updates；禁止整表 setState。
    return StreamBuilder<void>(
      stream: cubit.watchThumb(entry),
      builder: (context, _) {
        final bytes = cubit.peekThumb(entry);
        if (bytes == null || bytes.isEmpty) {
          return ColoredBox(
            color: _bg(),
            child: Center(child: Icon(_icon(), size: 32, color: _fg())),
          );
        }
        final width = MediaQuery.sizeOf(context).width - 48;
        final cell = (width - 3 * 4) / 4;
        final dpr = MediaQuery.devicePixelRatioOf(context);
        // 只设一边：同时设 cacheWidth+cacheHeight 会按正方形强制解码（类似
        // BoxFit.fill），横/竖图会被拉扁；中心裁切交给 BoxFit.cover。
        final cachePx = (cell * dpr).round().clamp(64, 384);
        return Image.memory(
          bytes,
          fit: BoxFit.cover,
          alignment: Alignment.center,
          width: double.infinity,
          height: double.infinity,
          cacheWidth: cachePx,
          gaplessPlayback: true,
          filterQuality: FilterQuality.low,
        );
      },
    );
  }
}

String _fileKey(FileEntry entry) => '${entry.rootId}|${entry.relativePath}';

double _gridBottomPad(BuildContext context) {
  final cubit = context.read<DeviceFilesCubit>();
  final state = cubit.state;
  final nav = 72 + MediaQuery.viewPaddingOf(context).bottom;
  if (state.selectionMode && state.isDirectoryTree) {
    return 168;
  }
  if (state.selectionMode && !state.isDirectoryTree) {
    return nav + 64;
  }
  return 100;
}

/// 离开文件页（切到底部其他 Tab）时退出分类网格多选。
class _ExitGridSelectionOffFiles extends StatefulWidget {
  const _ExitGridSelectionOffFiles({required this.child});

  final Widget child;

  @override
  State<_ExitGridSelectionOffFiles> createState() =>
      _ExitGridSelectionOffFilesState();
}

class _ExitGridSelectionOffFilesState extends State<_ExitGridSelectionOffFiles> {
  GoRouter? _router;
  DeviceFilesCubit? _cubit;
  StreamSubscription<DeviceFilesState>? _selectionSub;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final router = GoRouter.of(context);
    if (!identical(router, _router)) {
      _router?.routerDelegate.removeListener(_onRoute);
      _router = router;
      router.routerDelegate.addListener(_onRoute);
    }
    final cubit = context.read<DeviceFilesCubit>();
    if (identical(cubit, _cubit)) return;
    _selectionSub?.cancel();
    _cubit = cubit;
    _selectionSub = cubit.stream.listen((_) => _publishSelectionChrome());
    _publishSelectionChrome();
  }

  void _publishSelectionChrome() {
    final cubit = _cubit;
    if (cubit == null) return;
    final state = cubit.state;
    if (!state.selectionMode || state.isDirectoryTree) {
      gridSelectionChrome.clear();
      return;
    }
    gridSelectionChrome.publish(
      count: state.selected.length,
      canDownload: cubit.canDownload,
      onDownload: () => unawaited(cubit.downloadSelected()),
      onDelete: () async {
        await cubit.deleteSelected();
      },
      onCancel: cubit.exitSelection,
    );
  }

  @override
  void dispose() {
    _selectionSub?.cancel();
    gridSelectionChrome.clear();
    _router?.routerDelegate.removeListener(_onRoute);
    super.dispose();
  }

  void _onRoute() {
    if (!mounted) return;
    final path = _router?.routerDelegate.currentConfiguration.uri.path ?? '';
    if (path.endsWith('/files')) return;
    final cubit = context.read<DeviceFilesCubit>();
    if (!cubit.state.selectionMode || cubit.state.isDirectoryTree) return;
    cubit.exitSelection();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 对端点到不可预览文件时，只留一条 0.5 秒提示。滑动多选在 DragSelectLayer。
class _PeerFileSignals extends StatefulWidget {
  const _PeerFileSignals({
    required this.hintEnabled,
    required this.gridSelect,
    required this.child,
  });

  final bool hintEnabled;
  final bool gridSelect;
  final Widget child;

  static _PeerFileSignalsState? maybeOf(BuildContext context) {
    return context.findAncestorStateOfType<_PeerFileSignalsState>();
  }

  @override
  State<_PeerFileSignals> createState() => _PeerFileSignalsState();
}

class _PeerFileSignalsState extends State<_PeerFileSignals> {
  Timer? _hintTimer;
  bool _hint = false;

  @override
  void dispose() {
    _hintTimer?.cancel();
    super.dispose();
  }

  void showUnpreviewable() {
    if (!widget.hintEnabled) return;
    _hintTimer?.cancel();
    setState(() => _hint = true);
    _hintTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      setState(() => _hint = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Stack(
      children: [
        widget.child,
        if (_hint)
          Positioned(
            left: 0,
            right: 0,
            bottom: 72 + mq.viewPadding.bottom + 16,
            child: const IgnorePointer(
              child: Center(child: _UnpreviewableChip()),
            ),
          ),
      ],
    );
  }
}

class _UnpreviewableChip extends StatelessWidget {
  const _UnpreviewableChip();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF2F2E2B),
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text(
          '无法预览该文件',
          style: TextStyle(color: Colors.white, fontSize: 13),
        ),
      ),
    );
  }
}

class _PeerFileTouch extends StatelessWidget {
  const _PeerFileTouch({required this.entry, required this.child});

  final FileEntry entry;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<DeviceFilesCubit>();
    final signals = _PeerFileSignals.maybeOf(context);
    final peer = signals != null && signals.widget.hintEnabled;
    final grid = signals != null && signals.widget.gridSelect;
    final dragOwned = DragSelectLayer.owns(context);
    final treeSelect = cubit.state.isDirectoryTree &&
        cubit.state.treeAnchor != DirectoryTreeAnchor.volumePicker &&
        !_isVolumeEntry(entry);
    return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (cubit.state.selectionMode && grid && entry.isDirectory) {
            cubit.openEntry(entry);
            return;
          }
          if (cubit.state.selectionMode) {
            if (treeSelect || !entry.isDirectory) {
              cubit.toggleSelect(entry);
            }
            return;
          }
          if (entry.isDirectory) {
            cubit.openEntry(entry);
            return;
          }
          if (entry.isImage || entry.isVideo) {
            openFilePreview(context, entry);
            return;
          }
          if (peer) {
            signals.showUnpreviewable();
            return;
          }
          openFilePreview(context, entry);
        },
        onLongPress: dragOwned || grid || peer
            ? null
            : () {
                if (!cubit.state.selectionMode) {
                  if (!treeSelect && entry.isDirectory) return;
                  cubit.enterSelection();
                  cubit.toggleSelect(entry);
                }
              },
        child: child,
      );
  }
}

Future<void> _showPeerFileActions(
  BuildContext context,
  DeviceFilesCubit cubit,
  FileEntry entry,
) {
  return showDialog<void>(
    context: context,
    useRootNavigator: true,
    builder: (dialogContext) {
      return Dialog(
        backgroundColor: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: SizedBox(
          width: 300,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_peerActionIcon(entry), size: 42, color: const Color(0xFF3D8A5A)),
                const SizedBox(height: 16),
                Text(
                  entry.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF2F2E2B),
                    height: 1.3,
                  ),
                ),
                if (entry.sizeLabel.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    entry.sizeLabel,
                    style: const TextStyle(fontSize: 13, color: Color(0xFF6D6C6A)),
                  ),
                ],
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () {
                      Navigator.of(dialogContext).pop();
                      unawaited(cubit.downloadEntry(entry));
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF3D8A5A),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.download_rounded, size: 18),
                    label: const Text('下载'),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () {
                      Navigator.of(dialogContext).pop();
                      unawaited(cubit.deleteEntry(entry));
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFB64848),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('删除'),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF6D6C6A),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text(
                      '取消',
                      style: TextStyle(fontWeight: FontWeight.w400),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

IconData _peerActionIcon(FileEntry entry) {
  if (entry.isImage) return Icons.image;
  if (entry.isVideo) return Icons.videocam;
  if (entry.isAudio) return Icons.audio_file;
  switch (entry.extension) {
    case 'pdf':
      return Icons.picture_as_pdf;
    case 'doc':
    case 'docx':
      return Icons.article;
    case 'xls':
    case 'xlsx':
    case 'csv':
      return Icons.grid_on;
    case 'ppt':
    case 'pptx':
      return Icons.slideshow;
    case 'zip':
    case 'rar':
    case '7z':
      return Icons.folder_zip;
    default:
      return Icons.insert_drive_file;
  }
}

class _SelectionCountStrip extends StatelessWidget {
  const _SelectionCountStrip({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    // 只在多选时被放进列表。宽度交给外层 Column，不要写 infinite。
    return ColoredBox(
      color: const Color(0xFFE8F3EB),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '已选 $count 个',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Color(0xFF3D8A5A),
            ),
          ),
        ),
      ),
    );
  }
}

class _DirectoryTreeSelectionBar extends StatelessWidget {
  const _DirectoryTreeSelectionBar();

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<DeviceFilesCubit>();
    final selected = cubit.selectedEntries();
    final count = selected.length;
    final hasFolder = selected.any((e) => e.isDirectory);
    final bottom = 72 + MediaQuery.viewPaddingOf(context).bottom + 12;
    return Positioned(
      left: 16,
      right: 16,
      bottom: bottom,
      child: Material(
        color: Colors.white,
        elevation: 8,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '已选 $count 个',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF2F2E2B),
                  ),
                ),
              ),
              if (!cubit.isSelf)
                TextButton(
                  onPressed: count == 0
                      ? null
                      : () => cubit.downloadSelected(),
                  child: const Text('下载'),
                ),
              TextButton(
                onPressed: count == 0
                    ? null
                    : () async {
                        final ok = await AppDialog.confirm(
                          context,
                          title: hasFolder ? '删除所选内容？' : '删除已选文件？',
                          message: hasFolder
                              ? '将删除已选的 $count 项。文件夹将连同其内全部文件一并删除，且不可恢复。'
                              : '将删除已选的 $count 个文件。',
                          okLabel: '删除',
                          destructive: true,
                        );
                        if (ok) await cubit.deleteSelected();
                      },
                child: const Text(
                  '删除',
                  style: TextStyle(color: Color(0xFFB64848)),
                ),
              ),
              TextButton(
                onPressed: cubit.exitSelection,
                child: const Text('取消'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 对端文件页 → 聊天入口；有未读时角标星号。
class _PeerChatAction extends StatelessWidget {
  const _PeerChatAction({required this.peerId});

  final String peerId;

  @override
  Widget build(BuildContext context) {
    final unread = serviceLocator.chatUnreadStore();
    return ListenableBuilder(
      listenable: unread,
      builder: (context, _) {
        final showStar = unread.hasUnread(peerId);
        return IconButton(
          tooltip: '聊天',
          onPressed: () => context.go(RoutePaths.deviceChatFor(peerId)),
          icon: Badge(
            isLabelVisible: showStar,
            label: const Text(
              '*',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                height: 1,
              ),
            ),
            backgroundColor: const Color(0xFFE53935),
            child: const Icon(Icons.chat_bubble_outline),
          ),
        );
      },
    );
  }
}
