import 'package:flutter/foundation.dart';

/// 分类网格多选时，由文件页写入、导航壳读取的底栏状态。
///
/// 壳用它替换传输进度条那个槽位，避免文件页再往根 Overlay 插一层。
class GridSelectionChrome extends ChangeNotifier {
  var active = false;
  var count = 0;
  var canDownload = false;
  VoidCallback? onDownload;
  Future<void> Function()? onDelete;
  VoidCallback? onCancel;

  void publish({
    required int count,
    required bool canDownload,
    required VoidCallback onDownload,
    required Future<void> Function() onDelete,
    required VoidCallback onCancel,
  }) {
    final same = active && this.count == count && this.canDownload == canDownload;
    active = true;
    this.count = count;
    this.canDownload = canDownload;
    this.onDownload = onDownload;
    this.onDelete = onDelete;
    this.onCancel = onCancel;
    if (same) return;
    notifyListeners();
  }

  void clear() {
    if (!active) return;
    active = false;
    count = 0;
    canDownload = false;
    onDownload = null;
    onDelete = null;
    onCancel = null;
    notifyListeners();
  }
}

final gridSelectionChrome = GridSelectionChrome();
