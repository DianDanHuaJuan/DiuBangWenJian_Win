import 'dart:io';

import 'package:path/path.dart' as p;

import 'storage_constants.dart';

/// 探测默认可写共享目录（Downloads/diubangfiles）。
abstract class DefaultShareDirectoryProbe {
  Future<Directory?> probe();

  static DefaultShareDirectoryProbe create() =>
      const WindowsDefaultShareDirectoryProbe();
}

class WindowsDefaultShareDirectoryProbe implements DefaultShareDirectoryProbe {
  const WindowsDefaultShareDirectoryProbe();

  @override
  Future<Directory?> probe() async {
    try {
      final userProfile = Platform.environment['USERPROFILE'];
      if (userProfile == null || userProfile.trim().isEmpty) return null;
      return Directory(
        p.join(userProfile, 'Downloads', StorageConstants.folderName),
      );
    } catch (_) {
      return null;
    }
  }
}
