import 'dart:async';
import 'dart:typed_data';

/// 将任意字节流重切为约 [bufferSize] 的块（末块可更短）。
Stream<List<int>> bufferByteStream(
  Stream<List<int>> stream,
  int bufferSize,
) async* {
  if (bufferSize <= 0) {
    throw ArgumentError.value(
      bufferSize,
      'bufferSize',
      'must be greater than zero',
    );
  }

  final buffer = BytesBuilder(copy: false);

  await for (final chunk in stream) {
    buffer.add(chunk);
    while (buffer.length >= bufferSize) {
      final data = buffer.takeBytes();
      yield Uint8List.sublistView(data, 0, bufferSize);
      final remainingLength = data.length - bufferSize;
      if (remainingLength > 0) {
        buffer.add(Uint8List.sublistView(data, bufferSize));
      }
    }
  }

  if (buffer.isNotEmpty) {
    yield buffer.takeBytes();
  }
}
