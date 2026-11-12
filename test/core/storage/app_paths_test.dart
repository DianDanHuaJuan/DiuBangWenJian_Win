import 'package:flutter_test/flutter_test.dart';

import 'package:diubangwenjian/core/storage/app_paths.dart';

void main() {
  group('AppPaths.portable', () {
    test('统一反斜杠与盘符', () {
      expect(AppPaths.portable(r'C:\Users\a\b.jpg'), 'C:/Users/a/b.jpg');
      expect(AppPaths.portable('C:/Users/a/b.jpg'), 'C:/Users/a/b.jpg');
      expect(AppPaths.portable('c:/users/a'), 'C:/users/a');
      expect(AppPaths.portable('C:'), 'C:/');
      expect(AppPaths.portable('C:/'), 'C:/');
      expect(AppPaths.portable(r'C:\'), 'C:/');
      expect(AppPaths.portable('C'), 'C:/');
      expect(AppPaths.portable('/C:/Users'), 'C:/Users');
      expect(AppPaths.portable('/C:'), 'C:/');
    });

    test('相对路径永远 /', () {
      expect(AppPaths.portable(r'photos\a.jpg'), 'photos/a.jpg');
      expect(AppPaths.portable('photos/./a.jpg'), 'photos/a.jpg');
      expect(AppPaths.portable('photos//a.jpg'), 'photos/a.jpg');
    });
  });

  group('AppPaths.equals / join / within', () {
    test('斜杠与大小写等价', () {
      expect(AppPaths.equals(r'C:\A', 'C:/a'), isTrue);
      expect(AppPaths.equals('photos\\x', 'photos/x'), isTrue);
    });

    test('joinPortable 盘符根', () {
      expect(AppPaths.joinPortable('C:/', 'Users'), 'C:/Users');
      expect(AppPaths.joinPortable(r'C:\', r'Users\a'), 'C:/Users/a');
      expect(AppPaths.joinPortable('photos', 'a.jpg'), 'photos/a.jpg');
    });

    test('isWithinPortable', () {
      expect(AppPaths.isWithinPortable(r'C:\Share', r'C:\Share\a.jpg'), isTrue);
      expect(AppPaths.isWithinPortable('C:/Share', 'C:/Other/a.jpg'), isFalse);
      expect(AppPaths.isWindowsDriveRoot('C:'), isTrue);
      expect(AppPaths.isWindowsDriveRoot('C:/Users'), isFalse);
    });
  });

  group('AppPaths.native', () {
    test('盘符根固定为本机根形式；往返仍 portable', () {
      expect(AppPaths.native('C:/'), r'C:\');
      expect(AppPaths.portable(AppPaths.native(r'C:\Users\a')), 'C:/Users/a');
      expect(AppPaths.portable(AppPaths.native('photos/a.jpg')), 'photos/a.jpg');
    });
  });
}
