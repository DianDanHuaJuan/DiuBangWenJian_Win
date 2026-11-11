/// 互传保活（Windows：单进程托盘即可，无需安卓前台服务）。
class TransferKeepAlive {
  TransferKeepAlive._();

  static Future<void> start({
    String title = '文件传输中',
    String text = '正在接收文件',
  }) async {}

  static Future<void> stop() async {}
}
