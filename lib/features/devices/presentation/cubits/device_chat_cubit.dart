import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../app/di/service_locator.dart';
import '../../../../core/device/local_pick_facade.dart';
import '../../../../core/task/transfer_task.dart';
import '../../application/chat_offer_media_cache.dart';
import '../../application/chat_offer_poster.dart';
import '../../application/offer_accept_service.dart';
import '../../domain/entities/chat_message.dart';

class DeviceChatState {
  const DeviceChatState({
    this.messages = const [],
    this.tasksById = const {},
    this.connecting = false,
    this.busy = false,
    this.error,
  });

  final List<ChatMessage> messages;
  final Map<String, TransferTask> tasksById;
  final bool connecting;
  final bool busy;
  final String? error;

  DeviceChatState copyWith({
    List<ChatMessage>? messages,
    Map<String, TransferTask>? tasksById,
    bool? connecting,
    bool? busy,
    String? error,
    bool clearError = false,
  }) =>
      DeviceChatState(
        messages: messages ?? this.messages,
        tasksById: tasksById ?? this.tasksById,
        connecting: connecting ?? this.connecting,
        busy: busy ?? this.busy,
        error: clearError ? null : (error ?? this.error),
      );
}

class DeviceChatCubit extends Cubit<DeviceChatState> {
  DeviceChatCubit({required this.peerId}) : super(const DeviceChatState()) {
    // 进聊天页立刻消红点（勿等 ensureHost / WS，否则快速返回会消不掉）。
    serviceLocator.chatUnreadStore().setViewingPeer(peerId);
  }

  final String peerId;
  OfferAcceptService? _offers;
  StreamSubscription? _changesSub;

  Future<void> start() async {
    emit(state.copyWith(connecting: true, clearError: true));
    try {
      await serviceLocator.ensureTransferStack();
      await serviceLocator.ensureHostRunning();
      _offers = await serviceLocator.offerAcceptService();
      // 出站 session 事件由 OfferAcceptService.attachSessionEvents 全局处理。
      serviceLocator.chatUnreadStore().setViewingPeer(peerId);
      await _offers!.expireOffers();
      await serviceLocator.peerWsSession().enter(peerId);
      await _offers!.syncPendingFromPeer(peerId);
      await _reload();
      _changesSub ??= _offers!.changes.listen((_) => _reload());
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
    } finally {
      emit(state.copyWith(connecting: false));
    }
  }

  Future<void> _reload() async {
    final chat = await serviceLocator.chatRepository();
    final messages = await chat.messagesFor(peerId);
    final store = await serviceLocator.transferTaskStore();
    final tasks = <String, TransferTask>{};
    for (final m in messages) {
      if (m.kind != ChatMessageKind.offer) continue;
      final t = await store.findById(m.body);
      if (t != null) tasks[t.id] = t;
    }
    if (!isClosed) {
      emit(state.copyWith(messages: messages, tasksById: tasks));
    }
  }

  Future<void> sendText(String text) async {
    final offers = _offers;
    if (offers == null) return;
    // 空消息静默忽略，不弹错误（由 UI 禁用发送键）。
    if (text.trim().isEmpty) return;
    emit(state.copyWith(busy: true, clearError: true));
    try {
      await offers.sendText(peerFingerprint: peerId, text: text);
      await _reload();
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
    } finally {
      emit(state.copyWith(busy: false));
    }
  }

  /// 相册多选（图/视频）后发送。
  Future<void> pickAndSendMedia(BuildContext context) async {
    final offers = _offers;
    if (offers == null) return;
    final picked =
        await serviceLocator.localPickFacade().pickMedia(context);
    await _sendPicked(offers, picked);
  }

  /// 系统文件选择器多选后发送（无底部表叠层）。
  Future<void> pickAndSendFiles(BuildContext context) async {
    final offers = _offers;
    if (offers == null) return;
    final picked = await serviceLocator.localPickFacade().pickFiles();
    await _sendPicked(offers, picked);
  }

  Future<void> _sendPicked(
    OfferAcceptService offers,
    LocalPickFacadeResult picked,
  ) async {
    if (picked.isEmpty) return;
    final files = <File>[
      for (final item in picked.items) File(item.localPath),
    ];
    if (files.isEmpty) return;
    final assetIds = <String, String>{
      for (final item in picked.items)
        if (ChatOfferPoster.isLikelyMediaStoreId(item.id))
          item.localPath: item.id.trim(),
    };

    emit(state.copyWith(busy: true, clearError: true));
    try {
      await offers.sendFiles(
        peerFingerprint: peerId,
        files: files,
        mediaAssetIdByPath: assetIds,
      );
      await _reload();
      if (picked.unavailableCount > 0) {
        emit(
          state.copyWith(
            error: '有 ${picked.unavailableCount} 个文件无法访问，已跳过',
          ),
        );
      }
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
    } finally {
      emit(state.copyWith(busy: false));
    }
  }

  Future<void> acceptOffer(String taskId) async {
    final offers = _offers;
    if (offers == null) return;
    emit(state.copyWith(busy: true, clearError: true));
    try {
      await offers.acceptOffer(taskId);
      await _reload();
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
      await _reload();
    } finally {
      emit(state.copyWith(busy: false));
    }
  }

  /// 入站媒体：拉到 App 缓存（非正式公共库），供预览播放。
  Future<String?> cacheOfferForPreview(TransferTask task) async {
    emit(state.copyWith(busy: true, clearError: true));
    try {
      final path =
          await ChatOfferMediaCache().ensureOriginalCached(task: task);
      return path;
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
      return null;
    } finally {
      emit(state.copyWith(busy: false));
    }
  }

  Future<void> refresh() async {
    final offers = _offers;
    if (offers == null) return;
    await offers.syncPendingFromPeer(peerId);
    await _reload();
  }

  @override
  Future<void> close() async {
    await _changesSub?.cancel();
    serviceLocator.chatUnreadStore().clearViewingIf(peerId);
    return super.close();
  }
}
