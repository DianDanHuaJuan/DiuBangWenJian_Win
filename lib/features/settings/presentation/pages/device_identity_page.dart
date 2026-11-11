import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../../../app/di/service_locator.dart';
import '../../../../core/identity/device_emoji_presets.dart';
import '../../../../core/identity/device_identity_service.dart';
import '../../../common/widgets/section_header.dart';

/// 本机展示身份：页内改设备名（需点保存）+ 点选设备头像。
///
/// [initialIdentity] 由设置页传入缓存，避免进页再等一轮 loading。
/// 头像墙等路由转场结束后再分批铺开，减轻跳转卡顿。
class DeviceIdentityPage extends StatefulWidget {
  const DeviceIdentityPage({super.key, this.initialIdentity});

  final DeviceIdentity? initialIdentity;

  @override
  State<DeviceIdentityPage> createState() => _DeviceIdentityPageState();
}

class _DeviceIdentityPageState extends State<DeviceIdentityPage> {
  static const _presets = DeviceEmojiPresets.list;
  static const _emojiBatchSize = 12;
  static const _surface = Color(0xFFFCFBF9);
  static const _softGreen = Color(0xFFEAF3EC);
  static const _muted = Color(0xFF8B867C);
  static const _ink = Color(0xFF1A1918);
  static const _primary = Color(0xFF3D8A5A);
  static const _labelStyle = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w700,
    color: _muted,
  );

  DeviceIdentity? _identity;
  bool _loading = true;
  late final TextEditingController _nameController;
  late final FocusNode _nameFocus;
  String _savedName = '';
  var _savingName = false;
  var _nameDirty = false;

  /// 转场结束前不挂 emoji 墙。
  var _emojiSectionReady = false;
  var _emojiVisibleCount = 0;
  Timer? _emojiBatchTimer;
  Animation<double>? _routeAnim;
  AnimationStatusListener? _routeAnimListener;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController()..addListener(_onNameEdited);
    _nameFocus = FocusNode();
    _applyIdentity(
      widget.initialIdentity ??
          serviceLocator.deviceIdentityService.cachedIdentity,
      markLoaded: true,
    );
    unawaited(_reload());
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) _armEmojiRevealAfterTransition();
    });
  }

  @override
  void dispose() {
    _detachRouteAnimListener();
    _emojiBatchTimer?.cancel();
    _nameController.removeListener(_onNameEdited);
    unawaited(_commitNameIfNeeded(showFeedback: false));
    _nameFocus.dispose();
    _nameController.dispose();
    super.dispose();
  }

  void _applyIdentity(DeviceIdentity? identity, {required bool markLoaded}) {
    if (identity == null) return;
    final name = identity.deviceName.trim();
    _identity = identity;
    _savedName = name;
    _nameController.text = name;
    _nameDirty = false;
    if (markLoaded) _loading = false;
  }

  void _onNameEdited() {
    final dirty = _nameController.text.trim() != _savedName &&
        _nameController.text.trim().isNotEmpty;
    if (dirty != _nameDirty && mounted) {
      setState(() => _nameDirty = dirty);
    }
  }

  Future<void> _reload() async {
    final identity = await serviceLocator.deviceIdentityService.identity;
    if (!mounted) return;
    setState(() {
      _applyIdentity(identity, markLoaded: true);
    });
  }

  void _armEmojiRevealAfterTransition() {
    final anim = ModalRoute.of(context)?.animation;
    if (anim == null || anim.status == AnimationStatus.completed) {
      _beginEmojiReveal();
      return;
    }
    void listener(AnimationStatus status) {
      if (status == AnimationStatus.completed) {
        _detachRouteAnimListener();
        if (mounted) _beginEmojiReveal();
      }
    }

    _routeAnim = anim;
    _routeAnimListener = listener;
    anim.addStatusListener(listener);
  }

  void _detachRouteAnimListener() {
    final listener = _routeAnimListener;
    final anim = _routeAnim;
    if (listener != null && anim != null) {
      anim.removeStatusListener(listener);
    }
    _routeAnimListener = null;
    _routeAnim = null;
  }

  void _beginEmojiReveal() {
    if (_emojiSectionReady) return;
    setState(() {
      _emojiSectionReady = true;
      _emojiVisibleCount = 0;
    });
    _scheduleEmojiBatch();
  }

  void _scheduleEmojiBatch() {
    _emojiBatchTimer?.cancel();
    if (_emojiVisibleCount >= _presets.length) return;
    _emojiBatchTimer = Timer(const Duration(milliseconds: 20), () {
      if (!mounted) return;
      setState(() {
        _emojiVisibleCount = math.min(
          _presets.length,
          _emojiVisibleCount + _emojiBatchSize,
        );
      });
      if (_emojiVisibleCount < _presets.length) {
        _scheduleEmojiBatch();
      }
    });
  }

  void _toast(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _commitNameIfNeeded({bool showFeedback = true}) async {
    if (_savingName) return;
    final next = _nameController.text.trim();
    if (next.isEmpty) {
      if (_savedName.isNotEmpty && mounted) {
        _nameController.text = _savedName;
        setState(() => _nameDirty = false);
      }
      return;
    }
    if (next == _savedName) {
      if (mounted) setState(() => _nameDirty = false);
      return;
    }
    _savingName = true;
    if (mounted) setState(() {});
    try {
      await serviceLocator.deviceIdentityService.rename(next);
      await serviceLocator.publishLocalIdentityDisplay();
      _savedName = next;
      if (mounted) {
        setState(() {
          _identity = serviceLocator.deviceIdentityService.cachedIdentity;
          _nameDirty = false;
        });
        if (showFeedback) _toast('设备名已保存');
      }
    } finally {
      _savingName = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _pickEmoji(String emoji) async {
    if (_identity?.emoji == emoji) return;
    await serviceLocator.deviceIdentityService.setEmoji(emoji);
    await serviceLocator.publishLocalIdentityDisplay();
    if (!mounted) return;
    setState(() {
      _identity = serviceLocator.deviceIdentityService.cachedIdentity;
    });
  }

  @override
  Widget build(BuildContext context) {
    final identity = _identity;
    final selectedEmoji = identity?.emoji.trim() ?? '';
    final face = selectedEmoji.isEmpty ? '🙂' : selectedEmoji;
    final visibleEmojis = _presets.take(_emojiVisibleCount).toList();
    final emojiStillLoading =
        !_emojiSectionReady || _emojiVisibleCount < _presets.length;

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 112),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.arrow_back),
                ),
                const Expanded(
                  child: SectionHeader(title: '设备身份'),
                ),
                const SizedBox(width: 48),
              ],
            ),
            const SizedBox(height: 20),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              const Text('设备名', style: _labelStyle),
              const SizedBox(height: 10),
              Material(
                color: _surface,
                elevation: 1.5,
                shadowColor: Colors.black.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(14),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: _softGreen,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(face, style: const TextStyle(fontSize: 24)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _nameController,
                          focusNode: _nameFocus,
                          textInputAction: TextInputAction.done,
                          maxLength: 32,
                          maxLengthEnforcement: MaxLengthEnforcement.enforced,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: _ink,
                            height: 1.25,
                          ),
                          cursorColor: _primary,
                          decoration: const InputDecoration(
                            isDense: true,
                            counterText: '',
                            hintText: '输入设备名',
                            hintStyle: TextStyle(
                              color: _muted,
                              fontWeight: FontWeight.w400,
                            ),
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            filled: false,
                            contentPadding: EdgeInsets.symmetric(vertical: 10),
                          ),
                          onSubmitted: (_) => unawaited(
                            _commitNameIfNeeded(showFeedback: true),
                          ),
                        ),
                      ),
                      if (_nameDirty || _savingName)
                        TextButton(
                          onPressed: _savingName
                              ? null
                              : () => unawaited(
                                    _commitNameIfNeeded(showFeedback: true),
                                  ),
                          style: TextButton.styleFrom(
                            foregroundColor: _primary,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                          ),
                          child: _savingName
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: _primary,
                                  ),
                                )
                              : const Text(
                                  '保存',
                                  style: TextStyle(fontWeight: FontWeight.w700),
                                ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 28),
              const Text('设备头像', style: _labelStyle),
              const SizedBox(height: 10),
              if (!_emojiSectionReady)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 36),
                  child: Center(
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: _primary,
                      ),
                    ),
                  ),
                )
              else ...[
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final item in visibleEmojis)
                      Material(
                        color: item == selectedEmoji ? _softGreen : _surface,
                        borderRadius: BorderRadius.circular(12),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => unawaited(_pickEmoji(item)),
                          child: SizedBox(
                            width: 44,
                            height: 44,
                            child: Center(
                              child: Text(
                                item,
                                style: const TextStyle(fontSize: 24),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                if (emojiStillLoading)
                  const Padding(
                    padding: EdgeInsets.only(top: 16),
                    child: Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: _primary,
                        ),
                      ),
                    ),
                  ),
              ],
              if ((identity?.model ?? '').isNotEmpty) ...[
                const SizedBox(height: 28),
                Text(
                  '${identity!.model}'
                  '${identity.brand.isEmpty ? '' : ' · ${identity.brand}'}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    color: _muted,
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
