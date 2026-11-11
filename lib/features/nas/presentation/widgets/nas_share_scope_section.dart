import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../../../app/di/service_locator.dart';
import '../../../../app/ui/app_dialog.dart';
import '../../data/nas_share_scope.dart';

/// NAS 弹窗中的共享范围：右侧下拉展开已选目录。
class NasShareScopeSection extends StatefulWidget {
  const NasShareScopeSection({super.key});

  @override
  State<NasShareScopeSection> createState() => _NasShareScopeSectionState();
}

class _NasShareScopeSectionState extends State<NasShareScopeSection> {
  bool _busy = false;
  bool _open = false;

  NasShareScope get _scope => serviceLocator.nasShareScope();

  Future<bool> _ensureAccess() async {
    final result =
        await serviceLocator.permissionService().requestAllStorageForNas();
    if (result.manageExternalOk) return true;
    if (!mounted) return false;
    final open = await AppDialog.confirm(
      context,
      title: '需要全部文件访问权限',
      message: '按文件夹共享需要「所有文件访问」权限。请在系统设置中开启后重试。',
      okLabel: '去设置',
      cancelLabel: '取消',
    );
    if (open) {
      await serviceLocator.permissionService().openAppSettings();
    }
    return false;
  }

  Future<void> _pickAndAdd() async {
    if (_busy) return;
    if (!await _ensureAccess()) return;
    final path = await serviceLocator.deviceFileService().pickDirectory();
    if (path == null || path.isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      final ok = await _scope.addFolder(path);
      if (!mounted) return;
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            duration: Duration(seconds: 3),
            content: Text('这不是可用的文件夹'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    if (_busy) return;
    await _scope.restoreDefault();
    if (!mounted) return;
    setState(() => _open = false);
  }

  String _valueLabel(bool custom, List<String> folders) {
    if (!custom || folders.isEmpty) return '全部媒体';
    if (folders.length == 1) {
      final name = p.basename(folders.first);
      return name.isEmpty ? '全部媒体' : name;
    }
    return '${folders.length} 个目录';
  }

  @override
  Widget build(BuildContext context) {
    final custom = _scope.isCustom;
    final folders = _scope.folders;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Material(
        color: const Color(0xFFF5F4F1),
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: () => setState(() => _open = !_open),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
                child: Row(
                  children: [
                    const Icon(
                      Icons.folder_outlined,
                      size: 22,
                      color: Color(0xFF3D8A5A),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        '共享范围',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF1A1918),
                        ),
                      ),
                    ),
                    Text(
                      _valueLabel(custom, folders),
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF3D8A5A),
                      ),
                    ),
                    Icon(
                      _open
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
                      size: 20,
                      color: const Color(0xFF3D8A5A),
                    ),
                  ],
                ),
              ),
            ),
            if (_open) ...[
              const Divider(height: 1, thickness: 1, color: Color(0xFFE4E1DA)),
              for (var i = 0; i < folders.length; i++)
                _FolderRow(
                  path: folders[i],
                  onRemove: _busy
                      ? null
                      : () async {
                          await _scope.removeAt(i);
                          if (!mounted) return;
                          if (_scope.folders.isEmpty) {
                            await _scope.restoreDefault();
                          }
                          if (mounted) setState(() {});
                        },
                ),
              _MenuAction(
                icon: Icons.add,
                label: '选择共享目录',
                onTap: _busy ? null : _pickAndAdd,
              ),
              _MenuAction(
                icon: Icons.restart_alt,
                label: '恢复默认',
                onTap: _busy ? null : _restore,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FolderRow extends StatelessWidget {
  const _FolderRow({required this.path, required this.onRemove});

  final String path;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final missing = !Directory(path).existsSync();
    final name = p.basename(path);
    final label = name.isEmpty ? path : name;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
      child: Row(
        children: [
          Icon(
            missing ? Icons.folder_off_outlined : Icons.folder_outlined,
            size: 18,
            color: missing ? const Color(0xFFB3261E) : const Color(0xFF8B867C),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                color: missing
                    ? const Color(0xFFB3261E)
                    : const Color(0xFF1A1918),
              ),
            ),
          ),
          IconButton(
            onPressed: onRemove,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 16),
            color: const Color(0xFF8B867C),
          ),
        ],
      ),
    );
  }
}

class _MenuAction extends StatelessWidget {
  const _MenuAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final color = enabled ? const Color(0xFF3D8A5A) : const Color(0xFFC4BFB6);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
            Text(
              label,
              style: TextStyle(fontSize: 13, color: color),
            ),
          ],
        ),
      ),
    );
  }
}
