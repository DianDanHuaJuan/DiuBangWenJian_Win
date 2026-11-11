import 'package:media_kit/media_kit.dart';

/// 局域网 NAS / 对等 HTTPS 视频缓冲定案（对齐原项目 a1225da）。
///
/// 根因：MP4 mdat 音视频交错时 demuxer 在 audio/video 间约 ±1.1MB 跳转；
/// `stream-buffer-size` 过小会打穿滑动窗口，触发 TLS 断连重连，表现为
/// 中后段卡住、缓冲越来越慢。
class NasVideoPlayerConfig {
  NasVideoPlayerConfig._();

  /// 对应 mpv `demuxer-max-bytes`（前向缓存上限）。
  static const int bufferSizeBytes = 256 * 1024 * 1024;

  /// 服务端读盘块（见 [kNasFileReadChunkBytes]）。
  static const int serverReadChunkBytes = 256 * 1024;

  static const List<double> speedOptions = [0.5, 1.0, 1.5, 2.0, 3.0];

  /// 创建已带 bufferSize 的 Player（open 前再 [applyMpvProperties]）。
  static Player createPlayer() {
    MediaKit.ensureInitialized();
    return Player(
      configuration: const PlayerConfiguration(bufferSize: bufferSizeBytes),
    );
  }

  /// 在 [Player.open] 前调用。
  ///
  /// [disableTlsVerify]：对等自签 HTTPS 播流时为 true（鉴权仍靠 Bearer）。
  static Future<void> applyMpvProperties(
    Player player, {
    required bool disableTlsVerify,
  }) async {
    final platform = player.platform;
    if (platform is! NativePlayer) return;

    final props = <String, String>{
      // 低端 Android 上磁盘缓存会阻塞 demuxer。
      'cache-on-disk': 'no',
      // FFmpeg http：前向短 seek <2MB 时在当前连接跳过字节，避免重连。
      'stream-lavf-o': 'short_seek_size=2097152',
      'demuxer-readahead-secs': '15',
      // 后向 = 总缓存 1/8，避免挤占前向。
      'demuxer-max-back-bytes': '33554432',
      // lavf 内部缓冲（mpv issue #6802）。
      'demuxer-lavf-buffersize': '4194304',
      // 核心：覆盖 ±1.1MB 交错跳转，命中缓冲不再 TLS 重连。
      'stream-buffer-size': '8388608',
    };
    if (disableTlsVerify) {
      props['tls-verify'] = 'no';
    }
    for (final e in props.entries) {
      await platform.setProperty(e.key, e.value);
    }
  }

  static String formatSpeed(double speed) {
    if (speed == speed.roundToDouble()) {
      return speed.toStringAsFixed(1);
    }
    return speed.toString();
  }
}
