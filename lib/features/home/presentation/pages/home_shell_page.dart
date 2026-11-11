import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/di/service_locator.dart';
import '../../../../app/ui/app_dialog.dart';
import '../../../../core/platform/app_platform.dart';
import '../grid_selection_chrome.dart';
import '../widgets/transfer_progress_bar.dart';

/// 三导航壳：概览/设备/设置（doc/04 §1.1）。
/// Android 底栏；Windows 左侧栏（docs/Win移植整体规划.md Q8）。
class HomeShellPage extends StatelessWidget {
  final StatefulNavigationShell navigationShell;

  const HomeShellPage({super.key, required this.navigationShell});

  void _applyTabVisibility(int index) {
    final overview = index == 0;
    final devices = index == 1;
    if (serviceLocator.overviewVisible.value != overview) {
      serviceLocator.overviewVisible.value = overview;
    }
    serviceLocator.localBasics.setActive(overview);
    if (serviceLocator.devicesVisible.value != devices) {
      serviceLocator.devicesVisible.value = devices;
    }
  }

  void _selectTab(int index) {
    final resetDevicesList =
        index == 1 && index == navigationShell.currentIndex;
    navigationShell.goBranch(
      index,
      initialLocation: index == navigationShell.currentIndex,
    );
    if (resetDevicesList) {
      unawaited(serviceLocator.peerWsSession().leaveToDevicesList());
    }
    _applyTabVisibility(index);
  }

  @override
  Widget build(BuildContext context) {
    _applyTabVisibility(navigationShell.currentIndex);
    final useLeftRail = AppPlatform.supportsDesktopTray;

    if (useLeftRail) {
      return Scaffold(
        resizeToAvoidBottomInset: false,
        body: Row(
          children: [
            _DesktopSideNav(
              selectedIndex: navigationShell.currentIndex,
              onSelect: _selectTab,
            ),
            const VerticalDivider(width: 1, color: Color(0xFFE7E3DA)),
            Expanded(
              child: Column(
                children: [
                  Expanded(child: navigationShell),
                  ListenableBuilder(
                    listenable: gridSelectionChrome,
                    builder: (context, _) {
                      if (gridSelectionChrome.active) {
                        return const _GridSelectionActions();
                      }
                      return const TransferProgressBar();
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      extendBody: true,
      // 默认 true 会在键盘动画里逐帧压矮 body，并清掉子树的 viewInsets。
      // 聊天页因此整表重排。键盘避让交给当前页（聊天输入栏 / 配对页自己的 Scaffold）。
      resizeToAvoidBottomInset: false,
      body: navigationShell,
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 16,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: ListenableBuilder(
          listenable: gridSelectionChrome,
          builder: (context, _) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (gridSelectionChrome.active)
                  // 不可 const：count 变化时需重建，否则删除确认文案会卡在首次数量。
                  const _GridSelectionActions()
                else
                  const TransferProgressBar(),
                _BottomNavigationBar(
                  selectedIndex: navigationShell.currentIndex,
                  onSelect: _selectTab,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Windows 左侧导航：加宽、大图标、更大行距。
class _DesktopSideNav extends StatelessWidget {
  const _DesktopSideNav({
    required this.selectedIndex,
    required this.onSelect,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelect;

  static const _width = 112.0;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return ColoredBox(
      color: Colors.white,
      child: SizedBox(
        width: _width,
        child: SafeArea(
          right: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 28, 10, 20),
            child: Column(
              children: [
                _DesktopNavButton(
                  icon: Icons.dns_outlined,
                  label: '概览',
                  selected: selectedIndex == 0,
                  primary: primary,
                  onTap: () => onSelect(0),
                ),
                const SizedBox(height: 22),
                _DesktopNavButton(
                  icon: Icons.devices_outlined,
                  label: '设备',
                  selected: selectedIndex == 1,
                  primary: primary,
                  onTap: () => onSelect(1),
                ),
                const SizedBox(height: 22),
                _DesktopNavButton(
                  icon: Icons.settings_outlined,
                  label: '设置',
                  selected: selectedIndex == 2,
                  primary: primary,
                  onTap: () => onSelect(2),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopNavButton extends StatelessWidget {
  const _DesktopNavButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.primary,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final Color primary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? primary : const Color(0xFF9C9B99);
    return Material(
      color: selected ? const Color(0xFFE8F3EB) : Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          width: double.infinity,
          height: 78,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color, size: 30),
              const SizedBox(height: 8),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomNavigationBar extends StatelessWidget {
  const _BottomNavigationBar({
    required this.selectedIndex,
    required this.onSelect,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    // viewPadding：系统栏 inset 稳定；勿用 padding（immersive 时会变 0，退出抬底栏）。
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    return Container(
      height: 72 + bottomInset,
      decoration: const BoxDecoration(color: Colors.white),
      padding: EdgeInsets.fromLTRB(16, 10, 16, 10 + bottomInset),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _NavigationItem(
            icon: Icons.dns_outlined,
            label: '概览',
            selected: selectedIndex == 0,
            onTap: () => onSelect(0),
          ),
          _NavigationItem(
            icon: Icons.devices_outlined,
            label: '设备',
            selected: selectedIndex == 1,
            onTap: () => onSelect(1),
          ),
          _NavigationItem(
            icon: Icons.settings_outlined,
            label: '设置',
            selected: selectedIndex == 2,
            onTap: () => onSelect(2),
          ),
        ],
      ),
    );
  }
}

class _NavigationItem extends StatelessWidget {
  const _NavigationItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = selected
        ? theme.colorScheme.primary
        : theme.textTheme.bodySmall?.color ?? const Color(0xFF9C9B99);

    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: SizedBox(
        width: 64,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 23),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GridSelectionActions extends StatelessWidget {
  const _GridSelectionActions();

  @override
  Widget build(BuildContext context) {
    final chrome = gridSelectionChrome;
    final count = chrome.count;
    final canAct = count > 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Material(
        color: Colors.white,
        elevation: 4,
        shadowColor: const Color(0x33000000),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Color(0xFF8FCB9E)),
        ),
        child: SizedBox(
          height: 44,
          child: Row(
            children: [
              Expanded(
                child: _SelectionActionButton(
                  label: '下载',
                  foreground: const Color(0xFF5EAF78),
                  onPressed: canAct && chrome.canDownload
                      ? () => chrome.onDownload?.call()
                      : null,
                ),
              ),
              const _SelectionActionDivider(),
              Expanded(
                child: _SelectionActionButton(
                  label: '删除',
                  foreground: const Color(0xFFB64848),
                  onPressed: canAct
                      ? () async {
                          final selected = gridSelectionChrome.count;
                          final ok = await AppDialog.confirm(
                            context,
                            title: '删除已选文件？',
                            message: '将删除已选的 $selected 个文件。',
                            okLabel: '删除',
                            destructive: true,
                          );
                          if (ok) await chrome.onDelete?.call();
                        }
                      : null,
                ),
              ),
              const _SelectionActionDivider(),
              Expanded(
                child: _SelectionActionButton(
                  label: '取消',
                  foreground: const Color(0xFF8B867C),
                  onPressed: chrome.onCancel,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SelectionActionButton extends StatelessWidget {
  const _SelectionActionButton({
    required this.label,
    required this.onPressed,
    this.foreground,
  });

  final String label;
  final VoidCallback? onPressed;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: foreground ?? const Color(0xFF1A1918),
        minimumSize: const Size.fromHeight(44),
        shape: const RoundedRectangleBorder(),
      ),
      child: Text(label),
    );
  }
}

class _SelectionActionDivider extends StatelessWidget {
  const _SelectionActionDivider();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 1,
      height: 16,
      child: ColoredBox(color: Color(0xFFD5D1C8)),
    );
  }
}
