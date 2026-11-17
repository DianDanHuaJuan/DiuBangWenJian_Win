/// 对端 NAS 同时在线设备槽已满。
class NasPeerLimitException implements Exception {
  NasPeerLimitException({this.limit});

  final int? limit;

  @override
  String toString() {
    final n = limit;
    if (n != null && n > 0) {
      return '对端同时连接已满（最多 $n 台）';
    }
    return '对端同时连接已满';
  }
}
