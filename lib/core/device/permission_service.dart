/// Windows 无运行时存储/通知权限门禁；接口保留以免改散调用方。
class PermissionService {
  Future<bool> requestNasEnableGates() async => true;

  Future<({bool manageExternalOk, bool mediaOk})>
      requestAllStorageForNas() async =>
          (manageExternalOk: true, mediaOk: true);

  Future<void> openAppSettings() async {}
}
