import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import '../../../../app/di/service_locator.dart';
import '../../../../app/router/peer_session_navigation.dart';
import '../../../../app/router/route_paths.dart';
import '../../../../core/task/transfer_task.dart';
import '../../../preview/gallery_launcher.dart';
import '../../application/chat_media_preview.dart';
import '../../application/chat_offer_media_cache.dart';
import '../../application/chat_offer_poster.dart';
import '../../domain/entities/chat_message.dart';
import '../cubits/device_chat_cubit.dart';
import '../widgets/chat_bubble_widget.dart';
import '../widgets/chat_image_preview_page.dart';
import '../widgets/chat_message_frame.dart';
import '../widgets/chat_video_preview_page.dart';
import '../widgets/offer_card_widget.dart';

bool _peerHasNas(String peerId) {
  for (final o in serviceLocator.peerRegistry().onlinePaired) {
    if (o.fingerprint == peerId) return o.nasService;
  }
  return false;
}

bool _isImageFileName(String name) {
  final lower = name.toLowerCase();
  const images = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.heic'];
  return images.any(lower.endsWith);
}

bool _isVideoFileName(String name) {
  final lower = name.toLowerCase();
  const videos = ['.mp4', '.mov', '.mkv', '.webm', '.avi', '.m4v', '.3gp'];
  return videos.any(lower.endsWith);
}

/// chat 子页：文字气泡 + 报价卡（阶段 2）。
///
/// [embedded] 为 true 时用于设备页右侧栏：无返回键，不抢占整页路由。
class DeviceChatPage extends StatelessWidget {
  const DeviceChatPage({
    super.key,
    required this.peerId,
    this.embedded = false,
  });

  final String peerId;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => DeviceChatCubit(peerId: peerId)..start(),
      child: _DeviceChatView(peerId: peerId, embedded: embedded),
    );
  }
}

class _DeviceChatView extends StatefulWidget {
  const _DeviceChatView({required this.peerId, this.embedded = false});

  final String peerId;
  final bool embedded;

  @override
  State<_DeviceChatView> createState() => _DeviceChatViewState();
}

class _DeviceChatViewState extends State<_DeviceChatView> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  String _selfName = '我';
  String _peerName = '对方';
  String _selfEmoji = '';
  String _peerEmoji = '';
  var _toolsOpen = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
    unawaited(_loadNames());
  }

  void _onFocusChanged() {
    if (_focus.hasFocus && _toolsOpen) {
      setState(() => _toolsOpen = false);
    }
  }

  void _toggleTools() {
    final open = !_toolsOpen;
    if (open) {
      _focus.unfocus();
    }
    setState(() => _toolsOpen = open);
  }

  Future<void> _loadNames() async {
    try {
      final self = await serviceLocator.deviceIdentityService.identity;
      final peer = await (await serviceLocator.peerRepository())
          .findByFingerprint(widget.peerId);
      final registry = serviceLocator.peerRegistry();
      var onlineEmoji = '';
      for (final o in [...registry.onlinePaired, ...registry.nearby]) {
        if (o.fingerprint == widget.peerId && o.emoji.trim().isNotEmpty) {
          onlineEmoji = o.emoji.trim();
          break;
        }
      }
      if (!mounted) return;
      setState(() {
        _selfName = self.deviceName.trim().isEmpty ? '我' : self.deviceName.trim();
        _selfEmoji = self.emoji.trim();
        _peerName = peer?.name.trim().isNotEmpty == true
            ? peer!.name.trim()
            : '对方';
        final stored = peer?.emoji.trim() ?? '';
        _peerEmoji = stored.isNotEmpty ? stored : onlineEmoji;
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _controller.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  String _senderName(ChatMessage msg) =>
      msg.direction == ChatDirection.outbound ? _selfName : _peerName;

  String _senderEmoji(ChatMessage msg) =>
      msg.direction == ChatDirection.outbound ? _selfEmoji : _peerEmoji;

  @override
  Widget build(BuildContext context) {
    final appBar = AppBar(
      automaticallyImplyLeading: !widget.embedded,
      leading: widget.embedded
          ? null
          : BackButton(
              onPressed: () => unawaited(goToDevicesList(context)),
            ),
      title: Text(_peerName == '对方' ? '聊天' : _peerName),
      bottom: _peerHasNas(widget.peerId)
          ? PreferredSize(
              preferredSize: const Size.fromHeight(40),
              child: _ChatNasFilesBar(peerId: widget.peerId),
            )
          : null,
    );

    final scaffold = Scaffold(
      // 键盘只垫输入栏，避免整页 resize 拖着消息列表每帧重布局。
      resizeToAvoidBottomInset: false,
      appBar: appBar,
        // 列表视口高度不变。键盘动画只平移列表，不改占位高度。
        body: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: _ChatListKeyboardShift(
                child: BlocConsumer<DeviceChatCubit, DeviceChatState>(
                listener: (context, state) {
                  if (state.error != null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(state.error!)),
                    );
                  }
                  // reverse 列表贴底偏移为 0。
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (_scroll.hasClients) {
                      _scroll.jumpTo(0);
                    }
                  });
                },
                builder: (context, state) {
                  if (state.connecting && state.messages.isEmpty) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (state.messages.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          '发送文字或文件开始互传',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    );
                  }
                  final messages = state.messages;
                  // +1：reverse 下 index0 为固定高度占位，不随键盘逐帧变高。
                  return ListView.builder(
                        controller: _scroll,
                        reverse: true,
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                        itemCount: messages.length + 1,
                        itemBuilder: (context, index) {
                          if (index == 0) {
                            return _ChatKeyboardSpacer(toolsOpen: _toolsOpen);
                          }
                          final msg = messages[messages.length - index];
                          if (msg.kind == ChatMessageKind.offer) {
                            final task = state.tasksById[msg.body];
                            final canPreview = isChatMediaPreviewable(task) ||
                                canPullChatImagePreview(task) ||
                                canPullChatVideoPreview(task);
                            return Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: ChatMessageFrame(
                                message: msg,
                                senderName: _senderName(msg),
                                senderEmoji: _senderEmoji(msg),
                                child: OfferCardWidget(
                                  message: msg,
                                  task: task,
                                  busy: state.busy,
                                  onOpenPreview: canPreview && task != null
                                      ? () => unawaited(
                                            _onOfferMediaTap(
                                              context,
                                              state,
                                              task,
                                              msg,
                                            ),
                                          )
                                      : null,
                                  onAccept: task == null ||
                                          msg.direction !=
                                              ChatDirection.inbound ||
                                          (task.state !=
                                                  TransferTaskState.offered &&
                                              task.state !=
                                                  TransferTaskState.failed)
                                      ? null
                                      : () => context
                                          .read<DeviceChatCubit>()
                                          .acceptOffer(task.id),
                                ),
                              ),
                            );
                          }
                          return Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: ChatMessageFrame(
                              message: msg,
                              senderName: _senderName(msg),
                              senderEmoji: _senderEmoji(msg),
                              child: ChatBubbleWidget(message: msg),
                            ),
                          );
                        },
                      );
                },
              ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _ChatComposerBar(
                toolsOpen: _toolsOpen,
                controller: _controller,
                focusNode: _focus,
                onToggleTools: _toggleTools,
                onSend: () => _send(context),
                onCloseTools: () {
                  if (_toolsOpen) setState(() => _toolsOpen = false);
                },
                onPickMedia: () {
                  setState(() => _toolsOpen = false);
                  unawaited(
                    context.read<DeviceChatCubit>().pickAndSendMedia(context),
                  );
                },
                onPickFiles: () {
                  setState(() => _toolsOpen = false);
                  unawaited(
                    context.read<DeviceChatCubit>().pickAndSendFiles(context),
                  );
                },
              ),
            ),
          ],
        ),
    );

    if (widget.embedded) return scaffold;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(goToDevicesList(context));
      },
      child: scaffold,
    );
  }

  void _send(BuildContext context) {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    setState(() => _toolsOpen = false);
    _controller.clear();
    context.read<DeviceChatCubit>().sendText(text);
  }

  Future<void> _onOfferMediaTap(
    BuildContext context,
    DeviceChatState state,
    TransferTask task,
    ChatMessage msg,
  ) async {
    await _openMediaPreview(context, state, task, msg);
  }

  Future<void> _openMediaPreview(
    BuildContext context,
    DeviceChatState state,
    TransferTask task,
    ChatMessage msg,
  ) async {
    final inboundPending = msg.direction == ChatDirection.inbound &&
        (task.state == TransferTaskState.offered ||
            task.state == TransferTaskState.failed);
    final alreadySaved = msg.direction == ChatDirection.inbound &&
        task.state == TransferTaskState.done;

    // 图片：先用海报/缩略图立刻打开，再后台拉原图替换（避免点开卡死）。
    if (_isImageFileName(task.fileName)) {
      await _openImagePreview(
        context,
        task: task,
        inboundPending: inboundPending,
        alreadySaved: alreadySaved,
      );
      return;
    }

    // 已正式落盘：只走 localPath，禁止再进预览缓存（策略 §B）。
    String? path = task.localPath;
    final localReady = path != null &&
        path.isNotEmpty &&
        File(path).existsSync();
    if (!localReady) {
      final needCache = !isChatMediaPreviewable(task) &&
          (canPullChatImagePreview(task) || canPullChatVideoPreview(task));
      if (needCache) {
        path = await context.read<DeviceChatCubit>().cacheOfferForPreview(task);
        if (!context.mounted) return;
        if (path == null) return;
      } else {
        path = await ChatOfferMediaCache().cachedPathIfReady(task);
      }
    }
    if (path == null || path.isEmpty || !File(path).existsSync()) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            task.state == TransferTaskState.done
                ? '本地文件已不存在'
                : '暂无法预览',
          ),
        ),
      );
      return;
    }

    if (_isVideoFileName(task.fileName)) {
      if (!context.mounted) return;
      await Navigator.of(context, rootNavigator: true).push<void>(
        MaterialPageRoute(
          builder: (ctx) => BlocProvider.value(
            value: context.read<DeviceChatCubit>(),
            child: _ChatVideoPreviewHost(
              taskId: task.id,
              videoPath: path!,
              title: task.fileName,
              showDownload: inboundPending,
              downloaded: alreadySaved,
              onDownload: inboundPending
                  ? () => context.read<DeviceChatCubit>().acceptOffer(task.id)
                  : null,
            ),
          ),
        ),
      );
      return;
    }

    // 其它媒体：走画廊。
    final current = fileEntryFromTransferTask(
      task,
      overrideAbsolutePath: path,
    );
    if (current == null) return;
    final cachedMap = <String, String>{task.id: path};
    var media = chatSessionMediaEntries(
      messages: state.messages,
      tasksById: state.tasksById,
      cachedPathsByTaskId: cachedMap,
    );
    if (media.isEmpty) media = [current];
    if (!context.mounted) return;
    await openGalleryPreview(
      context: context,
      mediaFiles: media,
      current: current,
      isSelf: true,
    );
  }
}

Future<void> _openImagePreview(
  BuildContext context, {
  required TransferTask task,
  required bool inboundPending,
  required bool alreadySaved,
}) async {
  String? path = task.localPath;
  final localReady =
      path != null && path.isNotEmpty && File(path).existsSync();

  var needsOriginalPull = false;
  if (!localReady) {
    final fullCached = await ChatOfferMediaCache().cachedPathIfReady(task);
    if (fullCached != null) {
      path = fullCached;
    } else {
      path = await ChatOfferPoster().cachedPathIfReady(task.id);
      needsOriginalPull = !isChatMediaPreviewable(task) &&
          canPullChatImagePreview(task);
      if (path == null && !needsOriginalPull) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              task.state == TransferTaskState.done
                  ? '本地文件已不存在'
                  : '暂无法预览',
            ),
          ),
        );
        return;
      }
    }
  }

  if (!context.mounted) return;
  await Navigator.of(context, rootNavigator: true).push<void>(
    MaterialPageRoute(
      builder: (ctx) => BlocProvider.value(
        value: context.read<DeviceChatCubit>(),
        child: _ChatImagePreviewHost(
          taskId: task.id,
          task: task,
          initialImagePath: path ?? '',
          needsOriginalPull: needsOriginalPull,
          title: task.fileName,
          showDownload: inboundPending,
          downloaded: alreadySaved,
          onDownload: inboundPending
              ? () => context.read<DeviceChatCubit>().acceptOffer(task.id)
              : null,
        ),
      ),
    ),
  );
}

/// 预览页：可先显示海报，再后台拉原图；并监听正式下载态。
class _ChatImagePreviewHost extends StatefulWidget {
  const _ChatImagePreviewHost({
    required this.taskId,
    required this.task,
    required this.initialImagePath,
    required this.needsOriginalPull,
    required this.title,
    required this.showDownload,
    required this.downloaded,
    this.onDownload,
  });

  final String taskId;
  final TransferTask task;
  final String initialImagePath;
  final bool needsOriginalPull;
  final String title;
  final bool showDownload;
  final bool downloaded;
  final Future<void> Function()? onDownload;

  @override
  State<_ChatImagePreviewHost> createState() => _ChatImagePreviewHostState();
}

class _ChatImagePreviewHostState extends State<_ChatImagePreviewHost> {
  late String _imagePath = widget.initialImagePath;
  late bool _loadingOriginal = widget.needsOriginalPull;

  @override
  void initState() {
    super.initState();
    if (widget.needsOriginalPull) {
      unawaited(_pullOriginal());
    }
  }

  Future<void> _pullOriginal() async {
    try {
      // 尚无海报时先补封面，再换原图。
      if (_imagePath.isEmpty) {
        final poster =
            await ChatOfferPoster().ensureRemotePoster(widget.task);
        if (mounted &&
            poster != null &&
            poster.isNotEmpty &&
            File(poster).existsSync()) {
          setState(() => _imagePath = poster);
        }
      }
      final path = await ChatOfferMediaCache().ensureOriginalCached(
        task: widget.task,
      );
      if (!mounted) return;
      if (path != null && path.isNotEmpty && File(path).existsSync()) {
        setState(() {
          _imagePath = path;
          _loadingOriginal = false;
        });
      } else {
        setState(() => _loadingOriginal = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loadingOriginal = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<DeviceChatCubit, DeviceChatState>(
      builder: (context, state) {
        final busy = state.busy;
        final latest = state.tasksById[widget.taskId];
        final done =
            widget.downloaded || latest?.state == TransferTaskState.done;
        return ChatImagePreviewPage(
          imagePath: _imagePath,
          title: widget.title,
          loadingOriginal: _loadingOriginal,
          downloading: busy && widget.showDownload && !done,
          downloaded: done,
          onDownload: widget.showDownload && !done && widget.onDownload != null
              ? () => unawaited(widget.onDownload!())
              : null,
        );
      },
    );
  }
}

class _ChatVideoPreviewHost extends StatelessWidget {
  const _ChatVideoPreviewHost({
    required this.taskId,
    required this.videoPath,
    required this.title,
    required this.showDownload,
    required this.downloaded,
    this.onDownload,
  });

  final String taskId;
  final String videoPath;
  final String title;
  final bool showDownload;
  final bool downloaded;
  final Future<void> Function()? onDownload;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<DeviceChatCubit, DeviceChatState>(
      builder: (context, state) {
        final busy = state.busy;
        final latest = state.tasksById[taskId];
        final done = downloaded || latest?.state == TransferTaskState.done;
        return ChatVideoPreviewPage(
          videoPath: videoPath,
          title: title,
          downloading: busy && showDownload && !done,
          downloaded: done,
          onDownload: showDownload && !done && onDownload != null
              ? () => unawaited(onDownload!())
              : null,
        );
      },
    );
  }
}

/// 键盘动画期间只平移列表，不让 [child] 因为 inset 重建。
class _ChatListKeyboardShift extends StatelessWidget {
  const _ChatListKeyboardShift({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    final navPad = MediaQuery.paddingOf(context).bottom;
    final shift = inset > navPad ? inset - navPad : 0.0;
    return Transform.translate(
      offset: Offset(0, -shift),
      child: child,
    );
  }
}

/// reverse 列表底部占位。高度固定：输入栏 + 底栏。
/// 键盘升起时由 [_ChatListKeyboardShift] 平移，这里不读 viewInsets。
class _ChatKeyboardSpacer extends StatelessWidget {
  const _ChatKeyboardSpacer({required this.toolsOpen});

  final bool toolsOpen;

  // 与输入栏大致对齐；工具面板展开时加高。略估即可，偏差几像素可接受。
  static const _barH = 64.0;
  static const _toolsH = 108.0;

  @override
  Widget build(BuildContext context) {
    final navPad = MediaQuery.paddingOf(context).bottom;
    final composer = toolsOpen ? _barH + _toolsH : _barH;
    return SizedBox(height: composer + navPad);
  }
}

/// 输入栏：单独订阅键盘 inset，消息列表不跟着每帧重建。
class _ChatComposerBar extends StatelessWidget {
  const _ChatComposerBar({
    required this.toolsOpen,
    required this.controller,
    required this.focusNode,
    required this.onToggleTools,
    required this.onSend,
    required this.onCloseTools,
    required this.onPickMedia,
    required this.onPickFiles,
  });

  final bool toolsOpen;
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onToggleTools;
  final VoidCallback onSend;
  final VoidCallback onCloseTools;
  final VoidCallback onPickMedia;
  final VoidCallback onPickFiles;

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final navPad = MediaQuery.paddingOf(context).bottom;
    // 收起时躲开底栏；弹起后键盘已盖住底栏，不再把底栏高度叠上去。
    final lift = keyboard > navPad ? keyboard : navPad;
    return Padding(
      padding: EdgeInsets.only(bottom: lift),
      child: Material(
        color: const Color(0xFFF7F7F7),
        elevation: 8,
        child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
                child: Row(
                  children: [
                    _ChatPlusButton(
                      open: toolsOpen,
                      onPressed: onToggleTools,
                    ),
                    Expanded(
                      child: TextField(
                        controller: controller,
                        focusNode: focusNode,
                        minLines: 1,
                        maxLines: 4,
                        decoration: InputDecoration(
                          hintText: '输入消息',
                          isDense: true,
                          filled: true,
                          fillColor: Colors.white,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                        ),
                        onTap: onCloseTools,
                        onSubmitted: (_) => onSend(),
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: '发送',
                      onPressed: onSend,
                      icon: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFFF7F7F7),
                          border: Border.all(
                            color: const Color(0xFF5C5C5C),
                            width: 1.6,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: const Icon(
                          Icons.arrow_forward_rounded,
                          size: 20,
                          color: Color(0xFF2C2C2C),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: toolsOpen
                    ? _ChatToolsPanel(
                        onPickMedia: onPickMedia,
                        onPickFiles: onPickFiles,
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
    );
  }
}

/// 微信式圆圈加号：展开时旋成关闭。
class _ChatPlusButton extends StatelessWidget {
  const _ChatPlusButton({
    required this.open,
    required this.onPressed,
  });

  final bool open;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: open ? '收起' : '更多',
      onPressed: onPressed,
      icon: AnimatedRotation(
        turns: open ? 0.125 : 0, // 45° → ×
        duration: const Duration(milliseconds: 200),
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0xFF5C5C5C), width: 1.6),
          ),
          alignment: Alignment.center,
          child: const Icon(
            Icons.add,
            size: 22,
            color: Color(0xFF2C2C2C),
          ),
        ),
      ),
    );
  }
}

/// 输入框下方工具格（内嵌，非 ModalBottomSheet）。
class _ChatToolsPanel extends StatelessWidget {
  const _ChatToolsPanel({
    required this.onPickMedia,
    required this.onPickFiles,
  });

  final VoidCallback onPickMedia;
  final VoidCallback onPickFiles;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
      child: Row(
        children: [
          _ChatToolTile(
            icon: Icons.photo_library_outlined,
            label: '相册',
            onTap: onPickMedia,
          ),
          const SizedBox(width: 28),
          _ChatToolTile(
            icon: Icons.folder_open_outlined,
            label: '文件',
            onTap: onPickFiles,
          ),
        ],
      ),
    );
  }
}

class _ChatToolTile extends StatelessWidget {
  const _ChatToolTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 64,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, size: 28, color: const Color(0xFF3D3D3D)),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: const TextStyle(fontSize: 12, color: Color(0xFF666666)),
            ),
          ],
        ),
      ),
    );
  }
}

/// AppBar 标题下方靠右：回对端文件浏览。
class _ChatNasFilesBar extends StatelessWidget {
  const _ChatNasFilesBar({required this.peerId});

  final String peerId;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.only(right: 8, bottom: 4),
        child: IconButton(
          tooltip: '文件',
          visualDensity: VisualDensity.compact,
          onPressed: () => context.go(RoutePaths.deviceFilesFor(peerId)),
          icon: const Icon(Icons.folder_outlined),
        ),
      ),
    );
  }
}
