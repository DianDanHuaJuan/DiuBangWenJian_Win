import 'package:shelf/shelf.dart';

/// 极简路由表：精确匹配 + 可选前缀匹配；支持任意 HTTP 方法（含 PROPFIND）。
class Router {
  final List<_Route> _routes = [];

  void get(String path, Handler handler, {bool prefix = false}) =>
      add('GET', path, handler, prefix: prefix);

  void post(String path, Handler handler, {bool prefix = false}) =>
      add('POST', path, handler, prefix: prefix);

  void put(String path, Handler handler, {bool prefix = false}) =>
      add('PUT', path, handler, prefix: prefix);

  void add(
    String method,
    String path,
    Handler handler, {
    bool prefix = false,
  }) =>
      _routes.add(_Route(method, path, handler, prefix: prefix));

  Handler get handler => (Request request) async {
        for (final route in _routes) {
          if (route.matches(request)) return route.handler(request);
        }
        return Response.notFound('no route');
      };
}

class _Route {
  final String method;
  final String path;
  final Handler handler;
  final bool prefix;

  _Route(this.method, this.path, this.handler, {this.prefix = false});

  bool matches(Request request) {
    if (request.method.toUpperCase() != method.toUpperCase()) return false;
    final incoming = _normalize('/${request.url.path}');
    final expected = _normalize(path.startsWith('/') ? path : '/$path');
    if (prefix) {
      return incoming == expected || incoming.startsWith('$expected/');
    }
    return incoming == expected;
  }

  static String _normalize(String path) =>
      path.replaceAll(RegExp(r'/+'), '/');
}
