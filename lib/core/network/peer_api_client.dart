import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../auth/request_signer.dart';
import '../common/app_exception.dart';
import '../common/app_logger.dart';
import '../common/thumb_fetch_exception.dart';
import '../identity/peer.dart';
import '../identity/peer_repository.dart';
import '../identity/tls_certificate_builder.dart';
import '../protocol/nas_api_paths.dart';
import '../transfer/stream_transfer_tuning.dart';
import 'peer_address.dart';

export '../common/thumb_fetch_exception.dart';

/// 日常受信 API 客户端（doc/02 core/network：peer_api_client）。
///
/// 日常请求（非配对引导）统一走此栈：
/// ① 按指纹查 peers 表 → 取地址 + secret（不在表 = 未配对，直接失败）；
/// ② Bearer shared secret + X-Peer-Fingerprint；
/// ③ TLS 证书固定：badCertificateCallback 验对端证书 DER 指纹 = peer
///    指纹（防 MITM——announce 地址只是线索，证书才是身份）。
///
/// 连接复用：每 peer 一个缓存的 Dio 实例（HttpClient keep-alive）。
/// 本机指纹 [resolveSelfFingerprint] 用时解析，避免启动早期空串被冻死。
class PeerApiClient {
  PeerApiClient({
    required Future<PeerRepository> Function() peerRepository,
    Future<String> Function()? resolveSelfFingerprint,
    String selfFingerprint = '',
    RequestSigner signer = const RequestSigner(),
    Dio? dio,
    Duration connectTimeout = const Duration(seconds: 8),
    Duration receiveTimeout = const Duration(seconds: 12),
  })  : _peerRepository = peerRepository,
        _resolveSelfFingerprint = resolveSelfFingerprint ??
            (() async => selfFingerprint),
        _signer = signer,
        _dio = dio,
        _connectTimeout = connectTimeout,
        _receiveTimeout = receiveTimeout;

  final Future<PeerRepository> Function() _peerRepository;
  final Future<String> Function() _resolveSelfFingerprint;
  final RequestSigner _signer;
  final Dio? _dio;

  final Duration _connectTimeout;
  final Duration _receiveTimeout;

  final Map<String, Dio> _dioByFingerprint = {};

  /// 最近一次成功解析的本机指纹（仅诊断/兼容；发请求请走 [_requireSelfFingerprint]）。
  String get selfFingerprint => _lastSelfFingerprint;
  var _lastSelfFingerprint = '';

  /// 用时取本机指纹；空则再解析一次；仍空则抛错（禁止静默放弃 HTTP）。
  Future<String> _requireSelfFingerprint() async {
    var fp = (await _resolveSelfFingerprint()).trim();
    if (fp.isEmpty || fp == 'unavailable') {
      fp = (await _resolveSelfFingerprint()).trim();
    }
    if (fp.isEmpty || fp == 'unavailable') {
      throw const AppException(
        code: 'identity_not_ready',
        message: '本机身份未就绪，请稍后重试',
      );
    }
    _lastSelfFingerprint = fp;
    return fp;
  }

  /// GET 受信端点（ping/file_list 等幂等读）。
  Future<PeerApiResponse?> get(
    String fingerprint,
    String path, {
    Map<String, dynamic>? query,
    Duration? connectTimeout,
    Duration? receiveTimeout,
  }) =>
      _request(
        fingerprint,
        'GET',
        path,
        queryParameters: query,
        connectTimeout: connectTimeout,
        receiveTimeout: receiveTimeout,
      );

  /// POST 受信端点（阶段 2 互传写操作）。
  Future<PeerApiResponse?> post(
    String fingerprint,
    String path, {
    Object? body,
  }) =>
      _request(fingerprint, 'POST', path, data: body);

  /// PUT 受信端点（NAS 上传等）。
  Future<PeerApiResponse?> put(
    String fingerprint,
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) =>
      _request(fingerprint, 'PUT', path, data: body, queryParameters: query);

  /// PUT 原始字节（文件上传）。
  Future<PeerApiResponse?> putBytes(
    String fingerprint,
    String path, {
    required List<int> bytes,
    Map<String, dynamic>? query,
    String contentType = 'application/octet-stream',
    CancelToken? cancelToken,
    void Function(int sent, int total)? onSendProgress,
  }) =>
      putStream(
        fingerprint,
        path,
        stream: Stream<List<int>>.value(bytes),
        contentLength: bytes.length,
        query: query,
        contentType: contentType,
        cancelToken: cancelToken,
        onSendProgress: onSendProgress,
      );

  /// PUT 流式上传（大文件备份）。
  Future<PeerApiResponse?> putStream(
    String fingerprint,
    String path, {
    required Stream<List<int>> stream,
    int? contentLength,
    Map<String, dynamic>? query,
    String contentType = 'application/octet-stream',
    CancelToken? cancelToken,
    void Function(int sent, int total)? onSendProgress,
  }) async {
    final selfFp = await _requireSelfFingerprint();
    final repository = await _peerRepository();
    final peer = await repository.findByFingerprint(fingerprint);
    if (peer == null) return null;
    final parsed = PeerAddress.tryParse(peer.lastSeenAddress);
    if (parsed == null) return null;
    final dio = _dioFor(peer);
    dio.options.receiveTimeout = const Duration(minutes: 30);
    dio.options.sendTimeout = const Duration(minutes: 30);
    final headers = _signer
        .sign(fingerprint: selfFp, secret: peer.secret)
        .toMap();
    headers['content-type'] = contentType;
    if (contentLength != null) {
      headers['content-length'] = '$contentLength';
    }
    final uri = parsed.toHttpsUri(path);
    try {
      final response = await dio.put<dynamic>(
        uri.toString(),
        data: stream,
        queryParameters: query,
        cancelToken: cancelToken,
        onSendProgress: onSendProgress,
        options: Options(
          headers: headers,
          contentType: contentType,
          validateStatus: (status) =>
              status != null && status >= 200 && status < 300,
        ),
      );
      return PeerApiResponse(
        statusCode: response.statusCode ?? 200,
        data: response.data,
      );
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) {
        throw AppException(
          code: error.error == 'idle_timeout' ? 'idle_timeout' : 'cancelled',
          message: error.error == 'idle_timeout'
              ? '传输超时无进度，已跳过'
              : '上传已取消',
          originalError: error,
        );
      }
      AppLogger.log(
        'putStream failed: ${_classifyDialFailure(error)}',
        scope: 'dial',
        details: {'status': error.response?.statusCode},
      );
      return null;
    }
  }

  /// 解析受信 GET 的绝对 URL + 鉴权头（供 media_kit 在线流式播放）。
  ///
  /// 注意：media_kit/mpv 不走 Dio 证书钉扎；调用方需自行配置 TLS
  ///（局域网可 `tls-verify=no`，鉴权仍靠 Bearer）。
  Future<({String url, Map<String, String> headers})?> authenticatedGetTarget(
    String fingerprint,
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final selfFp = await _requireSelfFingerprint();
    final repository = await _peerRepository();
    final peer = await repository.findByFingerprint(fingerprint);
    if (peer == null) return null;
    final parsed = PeerAddress.tryParse(peer.lastSeenAddress);
    if (parsed == null) return null;
    final headers = _signer
        .sign(fingerprint: selfFp, secret: peer.secret)
        .toMap();
    var uri = parsed.toHttpsUri(path);
    if (query != null && query.isNotEmpty) {
      uri = uri.replace(
        queryParameters: {
          for (final e in query.entries)
            if (e.value != null) e.key: '${e.value}',
        },
      );
    }
    return (url: uri.toString(), headers: headers);
  }

  /// 下载整文件（报价原件）；失败返回 null。
  ///
  /// 小文件/测试仍可用；大文件请用 [downloadToFile]。
  Future<List<int>?> downloadBytes(
    String fingerprint,
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final isThumb = path == NasApiPaths.thumbnail ||
        path.endsWith(NasApiPaths.thumbnail);
    final thumbType = query?['type']?.toString() ?? '';
    final thumbName = query?['name']?.toString() ?? '';

    final selfFp = await _requireSelfFingerprint();
    final repository = await _peerRepository();
    final peer = await repository.findByFingerprint(fingerprint);
    if (peer == null) return null;
    final parsed = PeerAddress.tryParse(peer.lastSeenAddress);
    if (parsed == null) return null;

    final dio = _dioFor(peer);
    // 缩略图用短超时，避免占满客户端并发槽；大文件下载仍用长超时。
    const thumbReceiveTimeout = Duration(seconds: 15);
    const thumbConnectTimeout = Duration(seconds: 8);
    final headers = _signer
        .sign(fingerprint: selfFp, secret: peer.secret)
        .toMap();
    final uri = parsed.toHttpsUri(path);
    try {
      final response = await dio.get<List<int>>(
        uri.toString(),
        queryParameters: query,
        options: Options(
          headers: headers,
          responseType: ResponseType.bytes,
          validateStatus: (status) => status == 200,
          receiveTimeout:
              isThumb ? thumbReceiveTimeout : const Duration(minutes: 30),
          connectTimeout: isThumb ? thumbConnectTimeout : _connectTimeout,
        ),
      );
      return response.data;
    } on DioException catch (error) {
      final reason = _classifyDialFailure(error);
      if (isThumb) {
        // 超时/网络类：可重试；404 等业务失败：硬失败（返回 null）。
        if (_isRetryableDialFailure(error)) {
          throw ThumbFetchException(
            retryable: true,
            reason: reason,
            name: thumbName,
            type: thumbType,
          );
        }
        return null;
      }
      AppLogger.log(
        'download failed: $reason',
        scope: 'dial',
        details: {
          'fp': fingerprint.substring(0, 8),
          'uri': uri.toString(),
        },
      );
      return null;
    }
  }

  bool _isRetryableDialFailure(DioException error) {
    final type = error.type;
    return type == DioExceptionType.connectionTimeout ||
        type == DioExceptionType.receiveTimeout ||
        type == DioExceptionType.sendTimeout ||
        type == DioExceptionType.connectionError ||
        type == DioExceptionType.unknown;
  }

  /// 流式下载到本地文件（整文件重写；失败删除未完成文件，不做单文件续传）。
  ///
  /// 成功返回写入总字节；[onBytes] 每块回调累计已写字节。
  /// [cancelToken] 取消时抛 [AppException]（`idle_timeout` / `cancelled`）。
  Future<int?> downloadToFile(
    String fingerprint,
    String path, {
    required File destFile,
    Map<String, dynamic>? query,
    void Function(int cumulativeBytes)? onBytes,
    void Function(List<int> chunk)? onChunk,
    CancelToken? cancelToken,
  }) async {
    final selfFp = await _requireSelfFingerprint();
    final repository = await _peerRepository();
    final peer = await repository.findByFingerprint(fingerprint);
    if (peer == null) return null;
    final parsed = PeerAddress.tryParse(peer.lastSeenAddress);
    if (parsed == null) return null;

    final dio = _dioFor(peer);
    dio.options.receiveTimeout = const Duration(minutes: 30);
    final headers = _signer
        .sign(fingerprint: selfFp, secret: peer.secret)
        .toMap();
    final uri = parsed.toHttpsUri(path);
    try {
      final response = await dio.get<ResponseBody>(
        uri.toString(),
        queryParameters: query,
        cancelToken: cancelToken,
        options: Options(
          headers: headers,
          responseType: ResponseType.stream,
          validateStatus: (status) => status == 200,
        ),
      );
      final body = response.data;
      if (body == null) {
        await _deleteIncompleteDownload(destFile);
        return null;
      }

      final sink = destFile.openWrite(mode: FileMode.write);
      var written = 0;
      try {
        // 按固定块写盘，减少小 chunk 系统调用；进度仍按累计字节回调。
        await for (final chunk in StreamTransferTuning.bufferDownloadWriteStream(
          body.stream,
        )) {
          sink.add(chunk);
          onChunk?.call(chunk);
          written += chunk.length;
          onBytes?.call(written);
        }
        await sink.flush();
        await sink.close();
        if (written <= 0) {
          await _deleteIncompleteDownload(destFile);
          return null;
        }
        return written;
      } catch (e) {
        try {
          await sink.close();
        } catch (_) {}
        await _deleteIncompleteDownload(destFile);
        rethrow;
      }
    } on AppException {
      await _deleteIncompleteDownload(destFile);
      rethrow;
    } on DioException catch (error) {
      await _deleteIncompleteDownload(destFile);
      if (CancelToken.isCancel(error)) {
        throw AppException(
          code: error.error == 'idle_timeout' ? 'idle_timeout' : 'cancelled',
          message: error.error == 'idle_timeout'
              ? '传输超时无进度，已跳过'
              : '下载已取消',
          originalError: error,
        );
      }
      AppLogger.log(
        'downloadToFile failed: ${_classifyDialFailure(error)}',
        scope: 'dial',
        details: {
          'fp': fingerprint.substring(0, 8),
          'uri': uri.toString(),
        },
      );
      return null;
    } catch (_) {
      await _deleteIncompleteDownload(destFile);
      return null;
    }
  }

  Future<void> _deleteIncompleteDownload(File destFile) async {
    try {
      if (await destFile.exists()) await destFile.delete();
    } catch (_) {}
  }

  Future<PeerApiResponse?> _request(
    String fingerprint,
    String method,
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Duration? connectTimeout,
    Duration? receiveTimeout,
  }) async {
    late final String selfFp;
    try {
      selfFp = await _requireSelfFingerprint();
    } on AppException {
      return null;
    }
    final repository = await _peerRepository();
    final peer = await repository.findByFingerprint(fingerprint);
    if (peer == null) return null;
    final parsed = PeerAddress.tryParse(peer.lastSeenAddress);
    if (parsed == null) return null;

    final uri = parsed.toHttpsUri(path);
    final dio = _dioFor(peer);
    final savedReceive = dio.options.receiveTimeout;
    if (receiveTimeout != null) {
      dio.options.receiveTimeout = receiveTimeout;
    }
    final headers = _signer
        .sign(
          fingerprint: selfFp,
          secret: peer.secret,
        )
        .toMap();
    if (data != null) {
      headers['content-type'] = 'application/json';
    }
    try {
      final response = await dio.request<dynamic>(
        uri.toString(),
        data: data is Map || data is List ? jsonEncode(data) : data,
        queryParameters: queryParameters,
        options: Options(
          method: method,
          headers: headers,
          connectTimeout: connectTimeout,
          receiveTimeout: receiveTimeout,
          // 放行业务层常见状态，由调用方区分 503/401，避免一律当成「不可达」。
          validateStatus: (status) =>
              status != null && status >= 200 && status < 600,
        ),
      );
      return PeerApiResponse(
        statusCode: response.statusCode ?? 0,
        data: response.data,
      );
    } on DioException catch (error) {
      final reason = _classifyDialFailure(error);
      AppLogger.log(
        'dial failed: $reason',
        scope: 'dial',
        details: {
          'fp': fingerprint.substring(0, 8),
          'uri': uri.toString(),
          'type': error.type.name,
          'status': error.response?.statusCode,
        },
      );
      return null;
    } finally {
      if (receiveTimeout != null) {
        dio.options.receiveTimeout = savedReceive;
      }
    }
  }

  String _classifyDialFailure(DioException error) {
    final status = error.response?.statusCode;
    if (status == 401) return 'unauthorized';
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout) {
      return 'timeout';
    }
    if (error.type == DioExceptionType.badCertificate) {
      return 'tls_pin_mismatch';
    }
    if (error.type == DioExceptionType.connectionError) {
      return 'unreachable';
    }
    if (status != null) return 'http_$status';
    return 'unknown';
  }

  /// 每 peer 专属 Dio（证书固定绑定指纹；HttpClient 内部连接池复用）。
  Dio _dioFor(Peer peer) {
    final injected = _dio;
    if (injected != null) return injected; // 测试注入单例
    final cached = _dioByFingerprint[peer.fingerprint];
    if (cached != null) return cached;

    final dio = Dio();
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        return HttpClient()
          ..badCertificateCallback = (cert, _, _) {
            return CertificateFingerprint.fromDer(cert.der) == peer.fingerprint;
          };
      },
    );
    dio.options
      ..connectTimeout = _connectTimeout
      ..receiveTimeout = _receiveTimeout;
    _dioByFingerprint[peer.fingerprint] = dio;
    return dio;
  }

  /// 对端吊销/地址变更后清缓存。
  void invalidate(String fingerprint) => _dioByFingerprint.remove(fingerprint);
}

/// 受信应答（200 才非 null）。
class PeerApiResponse {
  const PeerApiResponse({required this.statusCode, required this.data});

  final int statusCode;
  final dynamic data;
}
