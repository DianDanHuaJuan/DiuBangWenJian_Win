import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../../../../core/common/app_logger.dart';
import '../../../../core/identity/tls_certificate_builder.dart';
import '../../../../core/network/peer_address.dart';

/// 配对 enroll 上报通道抽象（cubit 依赖此接口；测试注入假实现）。
abstract class PairingEnrollTransport {
  /// POST 加密 enroll 到对端配对端点。
  ///
  /// 返回应答 sealed 字符串；失败抛 [PairingTransportException]。
  Future<String?> postEnroll({
    required String host,
    required int port,
    required String path,
    required String sealed,
    String? expectedFingerprint,
    Map<String, dynamic>? extraBody,
  });
}

/// 配对传输层失败（带可读原因，供 UI 展示）。
class PairingTransportException implements Exception {
  PairingTransportException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// dio 实现：自签证书指纹校验（无 CA 层，Syncthing 式证书固定）。
class PairingRemoteDataSource implements PairingEnrollTransport {
  const PairingRemoteDataSource();

  @override
  Future<String?> postEnroll({
    required String host,
    required int port,
    required String path,
    required String sealed,
    String? expectedFingerprint,
    Map<String, dynamic>? extraBody,
  }) async {
    final uri = PeerAddress(host: host, port: port).toHttpsUri(path);

    final dio = Dio();
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () => HttpClient()
        ..badCertificateCallback = (cert, hostName, portNum) {
          if (expectedFingerprint == null) return true;
          final actual = CertificateFingerprint.fromDer(cert.der);
          final ok = actual == expectedFingerprint;
          if (!ok) {
            AppLogger.log(
              'TLS pin MISMATCH',
              scope: 'pairing',
              details: {
                'host': hostName,
                'port': portNum,
                'expected': expectedFingerprint,
                'actual': actual,
              },
            );
          }
          return ok;
        },
    );
    dio.options
      ..connectTimeout = const Duration(seconds: 10)
      ..receiveTimeout = const Duration(seconds: 45);

    try {
      final response = await dio.post<dynamic>(
        uri.toString(),
        data: <String, dynamic>{
          'sealed': sealed,
          ...?extraBody,
        },
        options: Options(
          contentType: 'application/json',
          responseType: ResponseType.json,
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      final status = response.statusCode ?? 0;
      if (status == 403) {
        throw PairingTransportException('对方拒绝配对（密码错误或票据失效）');
      }
      if (status == 401) {
        throw PairingTransportException('对方未开放配对接口（认证拦截）');
      }
      if (status == 400) {
        throw PairingTransportException('配对请求格式错误');
      }
      if (status != 200) {
        throw PairingTransportException('对方返回异常状态 $status');
      }

      final data = response.data;
      if (data is Map) {
        final sealedResponse = data['sealed'];
        if (sealedResponse is String && sealedResponse.isNotEmpty) {
          return sealedResponse;
        }
      }
      throw PairingTransportException('对方应答缺少 sealed 字段');
    } on PairingTransportException {
      rethrow;
    } on DioException catch (error) {
      final reason = _dioReason(error);
      AppLogger.log(
        'POST enroll DioException',
        scope: 'pairing',
        details: {
          'uri': uri.toString(),
          'reason': reason,
          'type': error.type.name,
          'status': error.response?.statusCode,
        },
        error: error,
      );
      throw PairingTransportException(reason);
    } catch (error, st) {
      AppLogger.log(
        'POST enroll error',
        scope: 'pairing',
        error: error,
        stackTrace: st,
      );
      throw PairingTransportException('无法连接对方（$error）');
    }
  }

  String _dioReason(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '连接超时（请确认对方已打开本 APP 且端口可达）';
      case DioExceptionType.connectionError:
        return '无法连接对方（地址/端口错误或防火墙拦截）';
      case DioExceptionType.badCertificate:
        return '证书指纹不匹配（请双方重启 APP 后重新扫码）';
      case DioExceptionType.unknown:
        final underlying = error.error?.toString() ?? '';
        if (underlying.contains('CERTIFICATE_VERIFY_FAILED')) {
          return '证书指纹不匹配（请双方重启 APP 后重新扫码）';
        }
        return '无法连接对方';
      default:
        final status = error.response?.statusCode;
        if (status == 403) return '对方拒绝配对（密码错误或票据失效）';
        if (status != null) return '对方返回异常状态 $status';
        return '无法连接对方';
    }
  }
}
