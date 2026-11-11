import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart';

import 'package:diubangwenjian/core/host/nas_route_guard.dart';

void main() {
  group('nasRouteGuard', () {
    Handler build({required bool enabled}) {
      return const Pipeline()
          .addMiddleware(nasRouteGuard(isEnabled: () => enabled))
          .addHandler((request) => Response.ok('ok'));
    }

    Request req(String path, {String method = 'GET'}) => Request(
          method,
          Uri.parse('http://localhost$path'),
        );

    test('非守卫路径不受影响', () async {
      final response = await build(enabled: false)(req('/api/v1/ping'));
      expect(response.statusCode, 200);
    });

    test('守卫路径在关闭时 503', () async {
      final response = await build(enabled: false)(req('/api/v1/files'));
      expect(response.statusCode, 503);
      expect(await response.readAsString(), 'nas service off');
    });

    test('守卫前缀子路径在关闭时 503', () async {
      final response =
          await build(enabled: false)(req('/api/v1/files/content'));
      expect(response.statusCode, 503);
    });

    test('preview 路径在关闭时 503', () async {
      final response =
          await build(enabled: false)(req('/api/v1/preview/hls'));
      expect(response.statusCode, 503);
    });

    test('开启后放行', () async {
      final response = await build(enabled: true)(req('/api/v1/files'));
      expect(response.statusCode, 200);
      expect(await response.readAsString(), 'ok');
    });
  });
}
