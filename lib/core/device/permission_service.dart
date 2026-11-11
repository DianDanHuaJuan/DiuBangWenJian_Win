/// Windows 无运行时存储/通知权限门禁；接口保留以免改散调用方。
class PermissionService {
  Future<bool> requestStoragePermission() async => true;

  Future<bool> requestPhotosPermission() async => true;

  Future<bool> requestVideosPermission() async => true;

  Future<bool> requestCameraPermission() async => true;

  Future<bool> requestNotificationPermission() async => true;

  Future<bool> checkNotificationPermission() async => true;

  Future<bool> requestNasEnableGates() async => true;

  Future<({bool manageExternalOk, bool mediaOk})>
      requestAllStorageForNas() async =>
          (manageExternalOk: true, mediaOk: true);

  Future<bool> ensureManageExternalStorage() async => true;

  Future<void> openAppSettings() async {}

  Future<void> openManageAllFilesSettings() async {}
}
