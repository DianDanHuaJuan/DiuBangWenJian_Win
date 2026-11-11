import 'package:flutter_test/flutter_test.dart';

import 'package:diubangwenjian/core/transfer/nas_transfer_service.dart';

void main() {
  test('encode/decode remotePath', () {
    final encoded = NasTransferService.encodeRemotePath(
      rootId: 'r1',
      relativePath: 'album/a.jpg',
    );
    final decoded = NasTransferService.decodeRemotePath(encoded);
    expect(decoded, isNotNull);
    expect(decoded!.rootId, 'r1');
    expect(decoded.path, 'album/a.jpg');
  });

  test('decode 非法串返回 null', () {
    expect(NasTransferService.decodeRemotePath(null), isNull);
    expect(NasTransferService.decodeRemotePath(''), isNull);
    expect(NasTransferService.decodeRemotePath('not-json'), isNull);
  });
}
