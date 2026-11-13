import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../../core/common/app_logger.dart';
import '../../application/nas_video_player_config.dart';

/// 已配置缓冲定案的 media_kit 会话（画廊 / 兼容预览页共用）。
class NasVideoSession {
  NasVideoSession();

  Player? _player;
  VideoController? _controller;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _bufferingSub;
  double _playbackSpeed = 1.0;
  final ValueNotifier<double> speedNotifier = ValueNotifier(1.0);

  Player? get player => _player;
  VideoController? get controller => _controller;
  bool get isReady => _player != null && _controller != null;

  /// 打开本机文件。
  Future<void> openLocal(String path, {bool play = true}) async {
    AppLogger.log(
      'NasVideoSession.openLocal',
      scope: 'video_diag',
      details: {'path': path, 'play': play},
    );
    await _preparePlayer(disableTlsVerify: false);
    await _player!.setRate(_playbackSpeed);
    await _player!.open(Media(path), play: play);
  }

  /// 打开对端 HTTPS 流（Bearer 头由调用方提供）。
  Future<void> openRemote({
    required String url,
    required Map<String, String> headers,
    bool play = true,
  }) async {
    AppLogger.log(
      'NasVideoSession.openRemote',
      scope: 'video_diag',
      details: {
        'url': url,
        'play': play,
        'headerCount': headers.length,
        'headerKeys': headers.keys.toList(growable: false),
      },
    );
    await _preparePlayer(disableTlsVerify: true);
    await _player!.setRate(_playbackSpeed);
    await _player!.open(
      Media(url, httpHeaders: headers),
      play: play,
    );
  }

  Future<void> _preparePlayer({required bool disableTlsVerify}) async {
    await dispose();
    final player = NasVideoPlayerConfig.createPlayer();
    await NasVideoPlayerConfig.applyMpvProperties(
      player,
      disableTlsVerify: disableTlsVerify,
    );
    _attachDiagStreams(player);
    _player = player;
    _controller = VideoController(player);
    AppLogger.log(
      'NasVideoSession.player ready',
      scope: 'video_diag',
      details: {'disableTlsVerify': disableTlsVerify},
    );
  }

  void _attachDiagStreams(Player player) {
    _errorSub = player.stream.error.listen((msg) {
      if (msg.isEmpty) return;
      AppLogger.log(
        'media_kit error',
        scope: 'video_diag',
        details: {'error': msg},
      );
    });
    _playingSub = player.stream.playing.listen((playing) {
      AppLogger.log(
        'media_kit playing',
        scope: 'video_diag',
        details: {'playing': playing},
      );
    });
    _bufferingSub = player.stream.buffering.listen((buffering) {
      AppLogger.log(
        'media_kit buffering',
        scope: 'video_diag',
        details: {'buffering': buffering},
      );
    });
  }

  Future<void> _cancelDiagStreams() async {
    await _errorSub?.cancel();
    await _playingSub?.cancel();
    await _bufferingSub?.cancel();
    _errorSub = null;
    _playingSub = null;
    _bufferingSub = null;
  }

  Future<void> play() async => _player?.play();

  Future<void> pause() async => _player?.pause();

  Future<void> setPlaybackSpeed(double speed) async {
    final player = _player;
    if (player == null) {
      _playbackSpeed = speed;
      speedNotifier.value = speed;
      return;
    }
    await player.setRate(speed);
    _playbackSpeed = speed;
    speedNotifier.value = speed;
  }

  /// 倍速按钮（ValueNotifier 绕过 MaterialVideoControlsTheme 不刷新）。
  Widget buildSpeedButton() {
    return ValueListenableBuilder<double>(
      valueListenable: speedNotifier,
      builder: (context, speed, _) {
        return PopupMenuButton<double>(
          tooltip: '播放倍速',
          onSelected: (s) => unawaited(setPlaybackSpeed(s)),
          itemBuilder: (context) => [
            for (final s in NasVideoPlayerConfig.speedOptions)
              PopupMenuItem<double>(
                value: s,
                child: Row(
                  children: [
                    if (s == speed)
                      const Icon(Icons.check, size: 18)
                    else
                      const SizedBox(width: 18),
                    const SizedBox(width: 8),
                    Text('${NasVideoPlayerConfig.formatSpeed(s)}x'),
                  ],
                ),
              ),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              '${NasVideoPlayerConfig.formatSpeed(speed)}x',
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        );
      },
    );
  }

  MaterialVideoControlsThemeData buildControlsTheme({
    List<Widget> trailing = const [],
  }) {
    return MaterialVideoControlsThemeData(
      seekOnDoubleTap: true,
      seekOnDoubleTapForwardDuration: const Duration(seconds: 5),
      seekOnDoubleTapBackwardDuration: const Duration(seconds: 5),
      speedUpOnLongPress: true,
      speedUpFactor: 2.0,
      controlsHoverDuration: const Duration(seconds: 5),
      bottomButtonBar: [
        const MaterialPlayOrPauseButton(),
        const MaterialPositionIndicator(),
        const Spacer(),
        buildSpeedButton(),
        ...trailing,
      ],
      seekBarMargin: const EdgeInsets.only(left: 16, right: 16, bottom: 48),
      bottomButtonBarMargin: const EdgeInsets.only(
        left: 16,
        right: 8,
        bottom: 4,
      ),
      buttonBarHeight: 40,
    );
  }

  Future<void> dispose() async {
    await _cancelDiagStreams();
    final player = _player;
    _player = null;
    _controller = null;
    if (player != null) {
      try {
        await player.dispose();
      } catch (_) {}
    }
  }

  void disposeNotifiers() {
    speedNotifier.dispose();
  }
}
