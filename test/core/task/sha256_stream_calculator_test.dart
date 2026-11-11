import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:diubangwenjian/core/task/sha256_stream_calculator.dart';

void main() {
  test('hashFile 与 hashBytes 一致', () async {
    final dir = await Directory.systemTemp.createTemp('sha_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final file = File('${dir.path}/a.bin');
    final bytes = List<int>.generate(100, (i) => i % 256);
    await file.writeAsBytes(bytes);

    const calc = Sha256StreamCalculator();
    final a = await calc.hashFile(file);
    final b = await calc.hashBytes(bytes);
    expect(a, b);
    expect(a.length, 64);
  });
}
