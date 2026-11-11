import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 本机文件读写与选择（阶段 A：一律 path，禁止 withData）。
class DeviceFileService {
  Future<String?> pickFile() async {
    final files = await pickUploadFiles();
    if (files.isEmpty) return null;
    return files.first;
  }

  Future<List<String>?> pickMultipleFiles() async {
    final files = await pickUploadFiles();
    if (files.isEmpty) return null;
    return files;
  }

  /// 多选任意文件；只返回可读 path（不含内存 bytes）。
  ///
  /// 与原项目一致：统一 [file_picker]（`FileType.any`，禁止 withData）。
  Future<List<String>> pickUploadFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.any,
      withData: false,
      withReadStream: false,
      dialogTitle: '选择要上传的文件',
    );
    if (result == null || result.files.isEmpty) {
      return [];
    }
    return result.files
        .map((file) => file.path)
        .whereType<String>()
        .where((path) => path.trim().isNotEmpty)
        .toList();
  }

  Future<String?> pickDirectory() async {
    return FilePicker.platform.getDirectoryPath();
  }

  Future<Stream<List<int>>> readFileAsStream(String path) async {
    return File(path).openRead();
  }

  Future<Uint8List> readFileAsBytes(String path) async {
    return File(path).readAsBytes();
  }

  Future<String> readFileAsString(String path) async {
    return File(path).readAsString();
  }

  Future<void> writeFile(String path, Uint8List bytes) async {
    await File(path).writeAsBytes(bytes);
  }

  Future<void> writeFileFromStream(
    String path,
    Stream<List<int>> stream,
  ) async {
    final sink = File(path).openWrite();
    await for (final chunk in stream) {
      sink.add(chunk);
    }
    await sink.close();
  }

  Future<int> getFileSize(String path) async {
    return File(path).length();
  }

  Future<String> getFileName(String path) async {
    return p.basename(path);
  }

  Future<String> getAppCacheDirectory() async {
    return (await getTemporaryDirectory()).path;
  }

  Future<String> getAppDocumentsDirectory() async {
    return (await getApplicationDocumentsDirectory()).path;
  }

  Future<bool> fileExists(String path) async {
    return File(path).exists();
  }

  Future<bool> directoryExists(String path) async {
    return Directory(path).exists();
  }

  Future<void> deleteFile(String path) async {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }
}
