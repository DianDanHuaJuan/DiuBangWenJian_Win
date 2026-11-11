/// 缩略图拉取失败；[retryable] 为 true 时客户端用短 TTL 后自动再试。
class ThumbFetchException implements Exception {
  const ThumbFetchException({
    required this.retryable,
    required this.reason,
    this.name = '',
    this.type = '',
  });

  final bool retryable;
  final String reason;
  final String name;
  final String type;

  @override
  String toString() =>
      'ThumbFetchException(retryable=$retryable, reason=$reason, type=$type, name=$name)';
}
