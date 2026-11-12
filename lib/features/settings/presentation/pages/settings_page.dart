import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/di/service_locator.dart';
import '../../../../app/router/route_paths.dart';
import '../../../../app/ui/app_dialog.dart';
import '../../../../app/ui/app_sheet.dart';
import '../../../../core/common/app_exception.dart';
import '../../../../core/desktop/desktop_runtime_controller.dart';
import '../../../../core/identity/device_identity_service.dart';
import '../../../../core/platform/app_platform.dart';
import '../../../../core/storage/app_paths.dart';
import '../../../../core/storage/storage_path_policy.dart';
import '../../../../core/storage/storage_root.dart';
import '../../../../core/storage/storage_root_store.dart';
import '../../../common/widgets/section_header.dart';
import '../../../common/widgets/settings_entry_tile.dart';

/// 设置页（Tab2）：仅设备身份 / 存储位置 / 文件备份 / 关于。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late Future<DeviceIdentity> _identity =
      serviceLocator.deviceIdentityService.identity;

  void _comingSoon(BuildContext context, [String? label]) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(label ?? '建设中')));
  }

  Future<void> _openIdentity(DeviceIdentity? seed) async {
    await context.push(
      RoutePaths.settingsIdentity,
      extra: seed ?? serviceLocator.deviceIdentityService.cachedIdentity,
    );
    if (!mounted) return;
    setState(() {
      _identity = serviceLocator.deviceIdentityService.identity;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 112),
          children: [
            const SectionHeader(title: '设置'),
            const SizedBox(height: 24),
            FutureBuilder<DeviceIdentity>(
              future: _identity,
              builder: (context, snapshot) {
                final emoji = snapshot.data?.emoji.trim() ?? '';
                final face = emoji.isEmpty ? '🙂' : emoji;
                return SettingsGroup(
                  children: [
                    SettingsEntryTile(
                      leading: Container(
                        width: 42,
                        height: 42,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: const Color(0xFFEAF3EC),
                          borderRadius: BorderRadius.circular(11),
                        ),
                        child: Text(face, style: const TextStyle(fontSize: 22)),
                      ),
                      title: '设备身份',
                      onTap: () => unawaited(_openIdentity(snapshot.data)),
                    ),
                    SettingsEntryTile(
                      icon: Icons.folder_outlined,
                      title: '存储位置',
                      onTap: () => unawaited(_showShareLocationSheet(context)),
                    ),
                    SettingsEntryTile(
                      icon: Icons.backup_outlined,
                      title: '文件备份',
                      onTap: () => context.push(RoutePaths.backupPlans),
                    ),
                    if (AppPlatform.supportsLaunchAtStartup)
                      SettingsEntryTile(
                        icon: Icons.power_settings_new_outlined,
                        title: DesktopRuntimeController
                                .instance.launchAtStartupEnabled
                            ? '开机自启：开'
                            : '开机自启：关',
                        onTap: () async {
                          final next = !DesktopRuntimeController
                              .instance.launchAtStartupEnabled;
                          await DesktopRuntimeController.instance
                              .setLaunchAtStartupEnabled(next);
                          if (!context.mounted) return;
                          setState(() {});
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                next ? '已开启开机自启' : '已关闭开机自启',
                              ),
                            ),
                          );
                        },
                      ),
                    SettingsEntryTile(
                      icon: Icons.info_outline,
                      title: '关于',
                      onTap: () => _comingSoon(context, '关于页建设中'),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showShareLocationSheet(BuildContext context) async {
    final changed = await AppSheet.show<bool>(
      context: context,
      heightFactor: 0.48,
      builder: (sheetContext) => _ShareLocationSheet(
        onChanged: () => Navigator.of(sheetContext).pop(true),
      ),
    );
    if (changed == true && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('存储位置已更新')));
    }
  }
}

class _ShareLocationSheet extends StatefulWidget {
  const _ShareLocationSheet({required this.onChanged});

  final VoidCallback onChanged;

  @override
  State<_ShareLocationSheet> createState() => _ShareLocationSheetState();
}

class _ShareLocationSheetState extends State<_ShareLocationSheet> {
  static const _surface = Color(0xFFFCFBF9);
  static const _muted = Color(0xFF8B867C);
  static const _ink = Color(0xFF1A1918);
  static const _primary = Color(0xFF3D8A5A);

  bool _loading = true;
  bool _busy = false;
  bool _pathDirty = false;
  String? _error;
  String _committedPath = '';
  String? _defaultPath;

  /// `/Download` 之前的部分，输入框里不显示。
  String _downloadPrefix =
      AppPlatform.isWindows ? '' : '/storage/emulated/0/';

  late final TextEditingController _pathController;
  late final FocusNode _pathFocus;

  @override
  void initState() {
    super.initState();
    _pathController = TextEditingController();
    _pathFocus = FocusNode();
    _pathController.addListener(_onPathEdited);
    unawaited(_reload());
  }

  @override
  void dispose() {
    _pathController.removeListener(_onPathEdited);
    _pathController.dispose();
    _pathFocus.dispose();
    super.dispose();
  }

  void _onPathEdited() {
    final dirty =
        _absoluteFromField(_pathController.text) != _normPath(_committedPath);
    setState(() => _pathDirty = dirty);
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final store = serviceLocator.storageRootStore();
      final current = await store.ensureCurrent();
      if (!mounted) return;
      _rememberDownloadPrefix(current.uriOrPath);
      String? defaultPath;
      try {
        final fallback = await resolveDefaultShareDirectory();
        defaultPath = fallback.path;
        _rememberDownloadPrefix(fallback.path);
      } catch (_) {
        // 默认公共根暂不可用（权限等）时仍展示用户当前根，不跳盘。
      }
      _setPath(current.uriOrPath, committed: true);
      setState(() {
        _defaultPath = defaultPath;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is AppException ? e.message : '$e';
      });
    }
  }

  void _setPath(String path, {required bool committed}) {
    final full = _normPath(path);
    _pathController.removeListener(_onPathEdited);
    if (committed) _committedPath = full;
    final display = _shortStoragePath(full);
    _pathController.text = display;
    _pathDirty = _absoluteFromField(display) != _normPath(_committedPath);
    _pathController.addListener(_onPathEdited);
  }

  void _rememberDownloadPrefix(String path) {
    final prefix = _prefixBeforeDownload(path);
    if (prefix.isNotEmpty) _downloadPrefix = prefix;
  }

  String _absoluteFromField(String field) {
    final text = _normPath(field);
    if (text.isEmpty || _isAbsoluteStoragePath(text)) return text;
    if (_downloadPrefix.isEmpty) return text;
    final prefix = _downloadPrefix.endsWith('/')
        ? _downloadPrefix
        : '$_downloadPrefix/';
    return _normPath('$prefix$text');
  }

  Future<bool> _ensureManageStorage() async => true;

  Future<void> _runSwitch(Future<StorageRoot> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (!mounted) return;
      widget.onChanged();
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
      if (e.code == 'storage_volume_root') {
        await AppDialog.alert(
          context,
          title: '无法使用该目录',
          message: e.message,
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _restoreDefault() {
    final path = _defaultPath;
    if (path == null || _busy) return;
    final display = _shortStoragePath(path);
    _pathController.value = TextEditingValue(
      text: display,
      selection: TextSelection.collapsed(offset: display.length),
    );
    setState(() => _error = null);
  }

  Future<void> _pickFolder() async {
    if (!await _ensureManageStorage()) return;
    final path = await serviceLocator.deviceFileService().pickDirectory();
    if (path == null || path.isEmpty || !mounted) return;
    await _runSwitch(() => serviceLocator.switchShareRoot().toDirectory(path));
  }

  Future<void> _applyTypedPath() async {
    final path = _absoluteFromField(_pathController.text);
    final problem = await _pathProblem(path);
    if (!mounted) return;
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    if (!await _ensureManageStorage()) return;
    await _runSwitch(
      () => serviceLocator.switchShareRoot().toDirectory(AppPaths.native(path)),
    );
  }

  /// 应用前只接受已存在、可识别的绝对目录，不替用户新建路径。
  Future<String?> _pathProblem(String path) async {
    if (path.isEmpty) return '请输入目录路径';
    if (!_isAbsoluteStoragePath(path)) return '路径无法对应到真实目录';
    if (isAppPrivateStoragePath(path)) return '禁止使用应用私有目录';
    if (await isStorageVolumeRoot(path)) {
      return '不能将存储介质的根目录设为存储位置，请选择根目录下的子文件夹。';
    }
    final type = await FileSystemEntity.type(AppPaths.native(path));
    if (type == FileSystemEntityType.notFound) return '目录不存在';
    if (type != FileSystemEntityType.directory) return '这不是文件夹';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '存储位置',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 22),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '当前位置',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: _muted,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Material(
                        color: _surface,
                        elevation: 1.5,
                        shadowColor: Colors.black.withValues(alpha: 0.07),
                        borderRadius: BorderRadius.circular(14),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
                          child: Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _pathController,
                                  focusNode: _pathFocus,
                                  enabled: !_busy,
                                  textInputAction: TextInputAction.done,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                    color: _ink,
                                    height: 1.3,
                                  ),
                                  cursorColor: _primary,
                                  decoration: const InputDecoration(
                                    isDense: true,
                                    hintText: '输入存储目录',
                                    hintStyle: TextStyle(
                                      color: _muted,
                                      fontWeight: FontWeight.w400,
                                    ),
                                    border: InputBorder.none,
                                    enabledBorder: InputBorder.none,
                                    focusedBorder: InputBorder.none,
                                    filled: false,
                                    contentPadding: EdgeInsets.symmetric(
                                      vertical: 18,
                                    ),
                                  ),
                                  onSubmitted: (_) {
                                    if (_pathDirty) {
                                      unawaited(_applyTypedPath());
                                    }
                                  },
                                ),
                              ),
                              if (_pathDirty || _busy)
                                TextButton(
                                  onPressed: _busy || !_pathDirty
                                      ? null
                                      : () => unawaited(_applyTypedPath()),
                                  style: TextButton.styleFrom(
                                    foregroundColor: _primary,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                  ),
                                  child: _busy
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: _primary,
                                          ),
                                        )
                                      : const Text(
                                          '应用',
                                          style: TextStyle(
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: const Color(0xFFB3261E),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _FloatPathButton(
                      label: '恢复默认',
                      onPressed: _busy || _defaultPath == null
                          ? null
                          : _restoreDefault,
                    ),
                    const SizedBox(width: 28),
                    _FloatPathButton(
                      label: '选择新路径',
                      onPressed: _busy ? null : () => unawaited(_pickFolder()),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}

class _FloatPathButton extends StatelessWidget {
  const _FloatPathButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Material(
        elevation: enabled ? 3 : 0,
        shadowColor: Colors.black.withValues(alpha: 0.18),
        color: const Color(0xFFEAF3EC),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.black,
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _normPath(String path) => AppPaths.portable(path);

bool _isAbsoluteStoragePath(String path) {
  final n = AppPaths.portable(path);
  if (n.startsWith('/')) return true;
  if (AppPlatform.isWindows) {
    if (RegExp(r'^[A-Z]:/').hasMatch(n)) return true;
    if (n.startsWith('//')) return true;
  }
  return false;
}

/// 从 `Download` 起显示，去掉它前面的存储根。
String _shortStoragePath(String path) {
  final full = _normPath(path);
  final at = full.indexOf('/Download');
  if (at < 0) return full;
  return full.substring(at + 1);
}

String _prefixBeforeDownload(String path) {
  final full = _normPath(path);
  final at = full.indexOf('/Download');
  if (at < 0) return '';
  return full.substring(0, at + 1);
}
