/// NAS 开关与宿主对齐（Windows 单进程：始终由 UI isolate 持有宿主）。
class NasKeepAlive {
  NasKeepAlive._();

  static Future<void> Function()? ensureHost;

  static Future<void> start() => sync(true);

  static Future<void> stop() => sync(false);

  /// 开/关均确保本进程宿主与发现可用（路由守卫负责 NAS 面 503）。
  static Future<void> sync(bool enabled) async {
    await (ensureHost ?? () async {})();
  }
}
