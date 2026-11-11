import 'package:flutter_test/flutter_test.dart';

import 'package:diubangwenjian/core/device/local_media_picker.dart';
import 'package:diubangwenjian/core/device/local_pick_facade.dart';
import 'package:diubangwenjian/core/storage/mime_types.dart';

void main() {
  group('MimeTypes.fromFileName', () {
    test('常见图片/视频扩展名', () {
      expect(MimeTypes.fromFileName('a.JPG'), 'image/jpeg');
      expect(MimeTypes.fromFileName('b.png'), 'image/png');
      expect(MimeTypes.fromFileName('c.mp4'), 'video/mp4');
      expect(MimeTypes.fromFileName('d.pdf'), isNull);
      expect(MimeTypes.fromFileNameOrOctet('d.pdf'), 'application/octet-stream');
    });
  });

  group('LocalPickFacadeResult', () {
    test('空结果与 unavailable 计数', () {
      const empty = LocalPickFacadeResult(items: [], unavailableCount: 2);
      expect(empty.isEmpty, isTrue);
      expect(empty.unavailableCount, 2);
    });
  });

  group('mediaScanShouldContinue', () {
    test('无取消回调继续', () {
      expect(mediaScanShouldContinue(), isTrue);
    });

    test('取消回调为 true 则停止', () {
      expect(mediaScanShouldContinue(shouldCancel: () => true), isFalse);
    });
  });
}
