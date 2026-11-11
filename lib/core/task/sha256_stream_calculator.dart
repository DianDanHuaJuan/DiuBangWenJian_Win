import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// 流式 SHA-256（互传校验）。
class Sha256StreamCalculator {
  const Sha256StreamCalculator();

  Future<String> hashFile(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  Future<String> hashBytes(List<int> bytes) =>
      Future.value(sha256.convert(bytes).toString());

  /// 边写边算：返回可 [add]/finish] 的累加器。
  Sha256Accumulator accumulator() => Sha256Accumulator();
}

/// 增量 SHA-256（流式下载落盘时用）。
class Sha256Accumulator {
  final _DigestSink _out = _DigestSink();
  late final ByteConversionSink _sink = sha256.startChunkedConversion(_out);

  void add(List<int> chunk) => _sink.add(chunk);

  String finish() {
    _sink.close();
    return (_out.value ?? sha256.convert(const [])).toString();
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
