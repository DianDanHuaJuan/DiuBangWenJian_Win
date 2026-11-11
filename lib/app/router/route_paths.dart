/// 三导航路由路径常量（doc/04 §7.2，决策 #16）。
class RoutePaths {
  static const home = '/';

  // 三 Tab 分支
  static const overview = '/overview'; // Tab0 初始路由
  static const devices = '/devices'; // Tab1 列表级
  static const devicesSelfFiles =
      '/devices/self/files'; // Tab1 子路由（本机卡；self 为保留字）
  static const deviceChat = '/devices/:peerId/chat'; // chat 子页
  static const deviceFiles = '/devices/:peerId/files'; // files 子页
  static const settings = '/settings'; // Tab2

  // 顶层 push 弹出页
  static const transfers = '/transfers';
  static const deviceInfo = '/device/:peerId';
  static const previewVideo = '/preview/video';
  static const backupPlans = '/backup/plans';
  static const backupEdit = '/backup/edit';
  static const settingsPeers = '/settings/peers';
  static const settingsAvatar = '/settings/avatar';
  static const settingsIdentity = '/settings/identity';
  // 参数化路径拼接（页面跳转用）
  static String deviceChatFor(String peerId) => '/devices/$peerId/chat';
  static String deviceFilesFor(String peerId) => '/devices/$peerId/files';
}
