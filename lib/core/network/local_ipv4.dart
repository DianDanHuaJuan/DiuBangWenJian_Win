import 'dart:io';

/// 本机一张可用的局域网 IPv4（多网卡列表项）。
class LocalIpv4Candidate {
  const LocalIpv4Candidate({
    required this.address,
    required this.interfaceName,
  });

  final String address;
  final String interfaceName;

  String get label => '$address（$interfaceName）';
}

/// 虚拟网卡 / TUN / 基准地址段：不作为二维码与组播的默认出口。
bool isDeprioritizedLanCandidate(LocalIpv4Candidate candidate) {
  final name = candidate.interfaceName.toLowerCase();
  const virtualHints = [
    'vethernet',
    'hyper-v',
    'wsl',
    'vmware',
    'virtualbox',
    'vbox',
    'docker',
    'meta',
    'clash',
    'tun',
    'tap',
    'vpn',
    'bluetooth',
    'loopback',
    'zerotier',
    'hamachi',
  ];
  if (virtualHints.any(name.contains)) return true;
  return _isBenchmarkRange(candidate.address);
}

/// 真实局域网优先（192.168 / 10 / 172.16），虚拟网卡与 198.18/15 垫底。
List<LocalIpv4Candidate> rankLocalIpv4Candidates(
  List<LocalIpv4Candidate> candidates,
) {
  final ranked = [...candidates];
  ranked.sort((a, b) {
    final byScore = _lanScore(b).compareTo(_lanScore(a));
    if (byScore != 0) return byScore;
    return a.address.compareTo(b.address);
  });
  return ranked;
}

int _lanScore(LocalIpv4Candidate candidate) {
  if (isDeprioritizedLanCandidate(candidate)) return 0;
  final parts = candidate.address.split('.');
  if (parts.length != 4) return 10;
  final a = int.tryParse(parts[0]);
  final b = int.tryParse(parts[1]);
  if (a == 192 && b == 168) return 300;
  if (a == 10) return 200;
  if (a == 172 && b != null && b >= 16 && b <= 31) return 200;
  return 50;
}

bool _isBenchmarkRange(String ip) {
  final parts = ip.split('.');
  if (parts.length != 4) return false;
  final a = int.tryParse(parts[0]);
  final b = int.tryParse(parts[1]);
  return a == 198 && b != null && b >= 18 && b <= 19;
}

/// 枚举本机非回环 IPv4，供二维码 / announce / UI 选择。
/// 返回顺序：真实局域网优先，虚拟网卡与 TUN 在后。
Future<List<LocalIpv4Candidate>> listLocalIpv4Candidates() async {
  final result = <LocalIpv4Candidate>[];
  final seen = <String>{};
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLinkLocal: true,
    );
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (address.isLoopback) continue;
        if (!seen.add(address.address)) continue;
        result.add(
          LocalIpv4Candidate(
            address: address.address,
            interfaceName: interface.name,
          ),
        );
      }
    }
  } catch (_) {}
  return rankLocalIpv4Candidates(result);
}
