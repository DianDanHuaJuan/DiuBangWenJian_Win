/// Unified exception wrapper for underlying errors
/// (client core/error/app_exception.dart as baseline, doc/02 §3.2).
class AppException implements Exception {
  final String code;
  final String message;
  final dynamic originalError;
  final StackTrace? stackTrace;

  const AppException({
    required this.code,
    required this.message,
    this.originalError,
    this.stackTrace,
  });

  @override
  String toString() => 'AppException(code: $code, message: $message)';
}
