import 'buffered_byte_stream.dart';
import 'progress_callback_throttler.dart';

/// NAS 流式上下传调参（详见 docs/流式传输关键指标设置.md）。
abstract final class StreamTransferTuning {
  StreamTransferTuning._();

  /// 上传流重切块大小。
  static const int uploadStreamBufferSize = 4 * 1024 * 1024;

  /// 下载落盘写缓冲。
  static const int downloadWriteBufferSize = 1 * 1024 * 1024;

  static const int uploadProgressMinStepBytes = 8 * 1024 * 1024;
  static const Duration uploadProgressMinInterval =
      Duration(milliseconds: 500);

  static const int downloadProgressMinStepBytes = 512 * 1024;
  static const Duration downloadProgressMinInterval =
      Duration(milliseconds: 150);

  /// 传输中连续无字节进展超时（发完等响应阶段应 [IdleWatchdog.releaseForResponse]）。
  static const Duration midTransferIdleTimeout = Duration(seconds: 45);

  static Stream<List<int>> bufferUploadStream(Stream<List<int>> source) {
    return bufferByteStream(source, uploadStreamBufferSize);
  }

  static Stream<List<int>> bufferDownloadWriteStream(
    Stream<List<int>> source,
  ) {
    return bufferByteStream(source, downloadWriteBufferSize);
  }

  static ProgressCallbackThrottler uploadProgressThrottler() {
    return ProgressCallbackThrottler(
      minStepBytes: uploadProgressMinStepBytes,
      minInterval: uploadProgressMinInterval,
    );
  }

  static ProgressCallbackThrottler downloadProgressThrottler() {
    return ProgressCallbackThrottler(
      minStepBytes: downloadProgressMinStepBytes,
      minInterval: downloadProgressMinInterval,
    );
  }
}
