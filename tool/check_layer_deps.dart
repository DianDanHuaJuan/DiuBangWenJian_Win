#!/usr/bin/env dart
// Dependency layer gate (doc/01 §七 期 E).
//
// Forbid:
//   - lib/core/** importing package:.../features/**
//   - lib/features/A importing lib/features/B (except allowlist)
//
// Usage: dart run tool/check_layer_deps.dart
// Exit 0 = pass; non-zero = violations printed.

import 'dart:io';

final _root = Directory.current.uri.resolve('lib/').toFilePath();

/// feature→feature allowlist (E2 residual until GalleryOpener lands in core/DI).
const allowFeatureCross = <String, Set<String>>{
  'devices': {'preview'}, // gallery_launcher only (via DeviceFilesCubit)
  'overview': {'devices', 'nas'}, // peer landing + NasControlCubit
  'home': {'overview', 'devices', 'settings'}, // tab shell
  'settings': {'overview'}, // deep-link to NAS panel
  'transfer': <String>{}, // should stay self-contained
  'preview': <String>{},
  'nas': <String>{},
  'common': <String>{},
};

final featureImportRe = RegExp(
  r'''import\s+['"](?:package:diubangwenjian/|(\.\./)+)features/([a-z_]+)/''',
);
final coreToFeaturesRe = RegExp(
  r'''import\s+['"](?:package:diubangwenjian/|(\.\./)+)features/''',
);

void main() {
  final violations = <String>[];

  for (final file in _dartFiles(Directory('${_root}core'))) {
    final rel = _rel(file.path);
    final text = File(file.path).readAsStringSync();
    for (final line in text.split('\n')) {
      final t = line.trimLeft();
      if (t.startsWith('//')) continue;
      if (coreToFeaturesRe.hasMatch(t)) {
        violations.add('E-core→features  $rel :: $t');
      }
    }
  }

  for (final file in _dartFiles(Directory('${_root}features'))) {
    final rel = _rel(file.path);
    final from = _featureOf(rel);
    if (from == null) continue;
    final text = File(file.path).readAsStringSync();
    for (final line in text.split('\n')) {
      final t = line.trimLeft();
      if (t.startsWith('//')) continue;
      final m = featureImportRe.firstMatch(t);
      if (m == null) continue;
      final to = m.group(2)!;
      if (to == from) continue;
      final allowed = allowFeatureCross[from] ?? const <String>{};
      if (!allowed.contains(to)) {
        violations.add('E-feature→feature  $rel → $to :: $t');
      }
    }
  }

  if (violations.isEmpty) {
    stdout.writeln('check_layer_deps: OK');
    exit(0);
  }
  stderr.writeln('check_layer_deps: ${violations.length} violation(s)');
  for (final v in violations) {
    stderr.writeln('  $v');
  }
  exit(1);
}

Iterable<File> _dartFiles(Directory dir) {
  if (!dir.existsSync()) return const [];
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'));
}

String _rel(String path) {
  final norm = path.replaceAll('\\', '/');
  final i = norm.indexOf('/lib/');
  return i >= 0 ? norm.substring(i + 1) : norm;
}

String? _featureOf(String rel) {
  // lib/features/<name>/...
  final parts = rel.replaceAll('\\', '/').split('/');
  final i = parts.indexOf('features');
  if (i < 0 || i + 1 >= parts.length) return null;
  return parts[i + 1];
}
