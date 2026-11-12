import 'dart:io';

/// 对等拨号地址（host + port），统一格式化与 HTTPS URI 构造。
///
/// 存储约定（`peers.lastSeenAddress` / announce `address`）：
/// - IPv4：`192.168.1.10:5244`
/// - IPv6：`[fe80::1]:5244`（方括号，禁止裸拼接）
class PeerAddress {
  const PeerAddress({required this.host, required this.port});

  final String host;
  final int port;

  /// 写入 peers / UI 展示用字符串。
  String get formatted {
    final h = _stripBrackets(host);
    if (_looksIpv6(h)) return '[$h]:$port';
    return '$h:$port';
  }

  /// 构造 HTTPS 请求 URI（禁止 `'https://$host:$port$path'` 手写拼接）。
  Uri toHttpsUri(String path) {
    final normalizedPath =
        path.startsWith('/') ? path : '/$path';
    return Uri(
      scheme: 'https',
      host: _stripBrackets(host),
      port: port,
      path: normalizedPath,
    );
  }

  /// 从 `host:port` / `[ipv6]:port` 解析；失败返回 null。
  static PeerAddress? tryParse(String? raw) {
    if (raw == null) return null;
    final s = raw.trim();
    if (s.isEmpty) return null;

    if (s.startsWith('[')) {
      final close = s.indexOf(']');
      if (close <= 1) return null;
      final host = s.substring(1, close);
      if (host.isEmpty) return null;
      final rest = s.substring(close + 1);
      if (!rest.startsWith(':')) return null;
      final port = int.tryParse(rest.substring(1));
      if (port == null || port <= 0 || port > 65535) return null;
      return PeerAddress(host: host, port: port);
    }

    final colon = s.lastIndexOf(':');
    if (colon <= 0 || colon == s.length - 1) return null;
    final host = s.substring(0, colon);
    final port = int.tryParse(s.substring(colon + 1));
    if (host.isEmpty || port == null || port <= 0 || port > 65535) {
      return null;
    }
    // 裸 IPv6 无括号且含多个冒号：拒绝（避免歧义）
    if (_looksIpv6(host) && host.contains(':')) {
      // host 本身是 IPv6 但未加括号的 "fe80::1:5244" 会被 lastIndexOf 拆错；
      // 若去掉端口段后仍含 ':'，视为非法裸 IPv6。
      return null;
    }
    return PeerAddress(host: host, port: port);
  }

  /// host + port → 规范存储串；host 非法时返回 null。
  static String? format(String? host, int? port) {
    if (host == null || port == null) return null;
    final h = preferIpv4(_stripBrackets(host.trim()));
    if (h == null || h.isEmpty || !_isUsableHost(h)) return null;
    if (port <= 0 || port > 65535) return null;
    return PeerAddress(host: h, port: port).formatted;
  }

  /// 入站已认证 HTTPS 探活：用 TCP 源 IP 合成拨号串。
  ///
  /// 若 [lastSeenAddress] 的 host 与 [remoteIp] 相同则沿用其 port，
  /// 否则使用 [defaultPort]（协议默认宿主端口）。
  static String? dialFromInboundPing({
    required String? remoteIp,
    String? lastSeenAddress,
    int defaultPort = 5244,
  }) {
    final host = preferIpv4(remoteIp);
    if (host == null) return null;
    var port = defaultPort;
    final known = tryParse(lastSeenAddress);
    if (known != null &&
        preferIpv4(known.host)?.toLowerCase() == host.toLowerCase()) {
      port = known.port;
    }
    return format(host, port);
  }

  /// 优先保留可用 IPv4；空 / 占位地址 → null。
  static String? preferIpv4(String? ip) {
    if (ip == null) return null;
    final h = _stripBrackets(ip.trim());
    if (h.isEmpty || h == '0.0.0.0' || h == '::') return null;
    // IPv4-mapped IPv6：::ffff:192.168.1.1
    final mapped = RegExp(r'^::ffff:(\d+\.\d+\.\d+\.\d+)$', caseSensitive: false)
        .firstMatch(h);
    if (mapped != null) return mapped.group(1);
    return h;
  }

  static bool _isUsableHost(String host) =>
      host.isNotEmpty && host != '0.0.0.0' && host != '::';

  static String _stripBrackets(String host) {
    if (host.startsWith('[') && host.endsWith(']') && host.length > 2) {
      return host.substring(1, host.length - 1);
    }
    return host;
  }

  static bool _looksIpv6(String host) {
    try {
      return InternetAddress(host).type == InternetAddressType.IPv6;
    } catch (_) {
      return host.contains(':');
    }
  }
}
