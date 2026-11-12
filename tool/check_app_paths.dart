#!/usr/bin/env dart
// Path slash gate: protocol paths must go through AppPaths.
//
// Forbid scattered replaceAll('\\' → '/') outside the allowlist.
// Usage: dart run tool/check_app_paths.dart

import 'dart:io';

final _lib = Directory.current.uri.resolve('lib/').toFilePath();

/// 唯一允许手写 `\`→`/` 的地方。
const allowlist = <String>{
  'core/storage/app_paths.dart',
};

final banned = RegExp(r'''replaceAll\(\s*['"]\\\\['"]\s*,\s*['"]/['"]\s*\)''');

void main() {
  final violations = <String>[];
  for (final file in _dartFiles(Directory(_lib))) {
    final rel = file.path
        .replaceAll('\\', '/')
        .split('/lib/')
        .last;
    if (allowlist.contains(rel)) continue;
    final lines = File(file.path).readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final t = line.trimLeft();
      if (t.startsWith('//')) continue;
      if (banned.hasMatch(line)) {
        violations.add('$rel:${i + 1} :: $t');
      }
    }
  }

  if (violations.isEmpty) {
    stdout.writeln('check_app_paths: OK');
    exit(0);
  }
  stderr.writeln('check_app_paths: ${violations.length} violation(s)');
  stderr.writeln('Use AppPaths.portable / AppPaths.native instead of replaceAll.');
  for (final v in violations) {
    stderr.writeln('  $v');
  }
  exit(1);
}

Iterable<File> _dartFiles(Directory dir) sync* {
  if (!dir.existsSync()) return;
  for (final entity in dir.listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) yield entity;
  }
}
