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

/// 枚举本机非回环 IPv4，供二维码 / announce / UI 选择。
Future<List<LocalIpv4Candidate>> listLocalIpv4Candidates() async {
  final result = <LocalIpv4Candidate>[];
  final seen = <String>{};
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLinkLocal: false,
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
  return result;
}
