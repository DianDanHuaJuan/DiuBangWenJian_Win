/// 写入后媒体入库（Android MediaStore）。Windows 无对应系统库，空操作。
class MediaScanner {
  MediaScanner();

  Future<void> scanPath(String absolutePath) async {}
}
