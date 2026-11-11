import 'discovery_service.dart' show MulticastLock;

/// Windows 无需 Wi-Fi MulticastLock。
class PlatformMulticastLock implements MulticastLock {
  @override
  Future<void> acquire() async {}

  @override
  Future<void> release() async {}
}
