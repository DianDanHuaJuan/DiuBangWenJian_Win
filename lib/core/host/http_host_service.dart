import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:stream_channel/stream_channel.dart';

import '../common/app_logger.dart';
import 'router.dart';

export 'router.dart';

/// 常驻 HTTP 宿主（插座，doc/02 core/host）。
///
/// 自定义 shelf adapter（不用 shelf_io.serve）：需要 shared 绑定（热重载
/// /重建不断口）与注入中间件管道。TLS 只做服务端侧加密（客户端用
/// onBadCertificate 验指纹）；客户端身份认证走应用层
/// `X-Peer-Fingerprint` + `Authorization: Bearer <shared_secret>`。
/// dart:io 无 CA 层架构下不请求客户端证书。
///
/// 管道顺序：log（内置最前）→ [middlewares]（认证等，DI 组装）→ 路由表。
/// 阶段 1 挂配对端点（认证豁免）+ ping；阶段 2 增挂互传端点。
class HttpHostService {
  HttpHostService({
    required this.port,
    required this.securityContext,
    required this.publicRoutes,
    this.middlewares = const [],
    this.bindAddress,
  });

  final int port;
  final Future<SecurityContext> securityContext;
  final Router publicRoutes;

  /// 认证等中间件（log 恒在最前，doc/01 §五：宿主负责中间件管道）。
  final List<Middleware> middlewares;

  /// Windows：绑到选定局域网地址，避免 TUN/虚拟网卡抢走回包。
  /// 空则 `0.0.0.0`。
  final InternetAddress? Function()? bindAddress;

  HttpServer? _server;
  bool _starting = false;
  bool _userStopped = false;
  int _rebindLeft = 0;

  /// 套接字仍绑在端口上才算在听。对象还在但端口已松开时为 false。
  bool get isRunning => boundPort != null;

  /// 实际监听端口（port=0 时由系统分配；未绑定为 null，不抛异常）。
  int? get boundPort {
    final server = _server;
    if (server == null) return null;
    try {
      return server.port;
    } on HttpException {
      return null;
    }
  }

  /// 启动（幂等；bootstrap 调用）。套接字已松开时会丢掉旧对象再绑定。
  Future<void> start() async {
    if (_starting || isRunning) return;
    _starting = true;
    _userStopped = false;
    try {
      final stale = _server;
      _server = null;
      if (stale != null) {
        try {
          await stale.close(force: true);
        } catch (_) {}
      }

      var pipeline = const Pipeline();
      for (final middleware in middlewares) {
        pipeline = pipeline.addMiddleware(middleware);
      }
      final handler = pipeline.addHandler(publicRoutes.handler);

      final preferred = _resolveBindAddress();
      HttpServer server;
      try {
        server = await HttpServer.bindSecure(
          preferred,
          port,
          await securityContext,
          shared: true,
        );
      } catch (error) {
        if (preferred.address == InternetAddress.anyIPv4.address) rethrow;
        AppLogger.log(
          'HTTPS bind preferred address failed, fallback any',
          scope: 'host',
          error: error,
          details: {'address': preferred.address, 'port': port},
        );
        server = await HttpServer.bindSecure(
          InternetAddress.anyIPv4,
          port,
          await securityContext,
          shared: true,
        );
      }
      server.listen(
        (httpRequest) => _handleRequest(httpRequest, handler),
        onError: (Object error, StackTrace stackTrace) {
          AppLogger.log(
            'Host stream error: $error',
            scope: 'host',
            error: error,
            stackTrace: stackTrace,
          );
        },
        onDone: () {
          if (!identical(_server, server)) return;
          _server = null;
          if (_userStopped || _starting) return;
          _rebindLeft = 3;
          unawaited(_rebind());
        },
      );
      _server = server;
      _rebindLeft = 0;
      AppLogger.log(
        'HTTPS host listening',
        scope: 'host',
        details: {
          'port': server.port,
          'address': server.address.address,
          'shared': true,
        },
      );
    } finally {
      _starting = false;
    }
  }

  InternetAddress _resolveBindAddress() {
    final chosen = bindAddress?.call();
    if (chosen == null ||
        chosen.type != InternetAddressType.IPv4 ||
        chosen.address == '0.0.0.0') {
      return InternetAddress.anyIPv4;
    }
    return chosen;
  }

  Future<void> _rebind() async {
    if (_userStopped || _starting || isRunning || _rebindLeft <= 0) return;
    _rebindLeft--;
    try {
      await start();
    } catch (error, stackTrace) {
      AppLogger.log(
        'Host rebind failed: $error',
        scope: 'host',
        error: error,
        stackTrace: stackTrace,
      );
      if (_userStopped || _rebindLeft <= 0) return;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await _rebind();
    }
  }

  Future<void> stop() async {
    _userStopped = true;
    _rebindLeft = 0;
    final server = _server;
    _server = null;
    if (server == null) return;
    AppLogger.log(
      'HTTPS host stopped',
      scope: 'host',
      details: {'wasPort': (() {
        try {
          return server.port;
        } catch (_) {
          return null;
        }
      })()},
    );
    await server.close(force: true);
  }

  /// 请求分发（仿 shelf_io.handleRequest：hijack 旁路 + 500 兜底）。
  Future<void> _handleRequest(
    HttpRequest httpRequest,
    Handler handler,
  ) async {
    final shelfRequest = _toShelfRequest(httpRequest);
    final path = '/${shelfRequest.url.path}';
    final remote = httpRequest.connectionInfo?.remoteAddress.address ?? '?';
    final started = DateTime.now();
    var response = Response.internalServerError();
    try {
      response = await handler(shelfRequest);
    } on HijackException {
      // 已 hijack（WebSocket 升级等）：连接被业务接管，跳过写回
      AppLogger.log(
        'HTTPS hijack',
        scope: 'host',
        details: {
          'method': shelfRequest.method,
          'path': path,
          'remote': remote,
        },
      );
      if (!shelfRequest.canHijack) return;
    } catch (error, stackTrace) {
      AppLogger.log(
        'Handler error: $error\n$stackTrace',
        scope: 'host',
        details: {
          'method': shelfRequest.method,
          'path': path,
          'remote': remote,
        },
      );
    }
    final ms = DateTime.now().difference(started).inMilliseconds;
    // 默认静默成功路径；仅错误或极慢（≥3s）打重要日志。
    // 全量 HTTP 明细需 AppLogger.verboseHttp=true。
    final failed = response.statusCode >= 400;
    final verySlow = ms >= 3000;
    if (failed || verySlow) {
      AppLogger.log(
        'HTTPS ${shelfRequest.method} $path → ${response.statusCode}',
        scope: 'host',
        details: {
          'remote': remote,
          'ms': ms,
          'status': response.statusCode,
        },
      );
    } else {
      AppLogger.logVerbose(
        'HTTPS ${shelfRequest.method} $path → ${response.statusCode}',
        scope: 'host',
        details: {
          'remote': remote,
          'ms': ms,
          'status': response.statusCode,
        },
      );
    }
    try {
      await _writeResponse(response, httpRequest.response);
    } catch (error) {
      // 客户端中断等写回失败：连接级错误，宿主不因此退出
      AppLogger.log(
        'Response write failed: $error',
        scope: 'host',
        details: {'path': path, 'remote': remote, 'ms': ms},
      );
    }
  }

  /// HttpRequest → shelf Request（仿 shelf_io._fromHttpRequest，
  /// 增补证书指纹注入）。
  Request _toShelfRequest(HttpRequest request) {
    final headers = <String, List<String>>{};
    request.headers.forEach((key, value) {
      headers[key] = value;
    });
    // adapter 规范：剥离 Transfer-Encoding（由 dart:io 管理）
    headers.remove(HttpHeaders.transferEncodingHeader);

    void onHijack(void Function(StreamChannel<List<int>>) callback) {
      request.response
          .detachSocket(writeHeaders: false)
          .then((socket) => callback(StreamChannel(socket, socket)));
    }

    return Request(
      request.method,
      request.requestedUri,
      protocolVersion: request.protocolVersion,
      headers: headers,
      body: request,
      onHijack: onHijack,
      context: {'shelf.io.connection_info': request.connectionInfo!},
    );
  }

  /// Response 写回（仿 shelf_io._writeResponse 简化版：dart:io 自动
  /// 处理 chunked 传输；Content-Length 已由 shelf 头透传）。
  Future<void> _writeResponse(
    Response response,
    HttpResponse httpResponse,
  ) async {
    httpResponse.statusCode = response.statusCode;
    response.headersAll.forEach((header, value) {
      httpResponse.headers.set(header, value);
    });
    await httpResponse.addStream(response.read());
    await httpResponse.close();
  }
}
