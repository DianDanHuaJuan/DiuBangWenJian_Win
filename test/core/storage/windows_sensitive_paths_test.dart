import 'package:diubangwenjian/core/storage/windows_sensitive_paths.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isWindowsSensitiveDirectory', () {
    test('blocks classic names at drive root', () {
      expect(
        isWindowsSensitiveDirectory(
          name: 'Windows',
          absolutePath: r'C:\Windows',
        ),
        isTrue,
      );
      expect(
        isWindowsSensitiveDirectory(
          name: 'Program Files',
          absolutePath: 'D:/Program Files',
        ),
        isTrue,
      );
      expect(
        isWindowsSensitiveDirectory(
          name: r'$Recycle.Bin',
          absolutePath: r'C:\$Recycle.Bin',
        ),
        isTrue,
      );
    });

    test('blocks classic name without absolutePath (volume-root listing)', () {
      expect(
        isWindowsSensitiveDirectory(name: 'ProgramData', absolutePath: null),
        isTrue,
      );
    });

    test('does not block same name nested under user folder', () {
      expect(
        isWindowsSensitiveDirectory(
          name: 'Windows',
          absolutePath: r'C:\Users\yao\Documents\Windows',
        ),
        isFalse,
      );
    });

    test('blocks Users/*/AppData', () {
      expect(
        isWindowsSensitiveDirectory(
          name: 'AppData',
          absolutePath: r'C:\Users\yao\AppData',
        ),
        isTrue,
      );
      expect(
        isWindowsSensitiveDirectory(
          name: 'Local',
          absolutePath: r'C:\Users\yao\AppData\Local',
        ),
        isTrue,
      );
    });

    test('allows normal folders', () {
      expect(
        isWindowsSensitiveDirectory(
          name: 'Users',
          absolutePath: r'C:\Users',
        ),
        isFalse,
      );
      expect(
        isWindowsSensitiveDirectory(
          name: 'Photos',
          absolutePath: r'D:\Photos',
        ),
        isFalse,
      );
    });
  });
}
