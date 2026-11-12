import 'package:diubangwenjian/core/network/local_ipv4.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('真实局域网排在虚拟网卡和 Meta TUN 前面', () {
    final ranked = rankLocalIpv4Candidates(const [
      LocalIpv4Candidate(
        address: '192.168.135.17',
        interfaceName: 'vEthernet (Default Switch)',
      ),
      LocalIpv4Candidate(
        address: '198.18.0.1',
        interfaceName: 'Meta',
      ),
      LocalIpv4Candidate(
        address: '192.168.3.58',
        interfaceName: '以太网 2',
      ),
    ]);
    expect(ranked.first.address, '192.168.3.58');
    expect(ranked.last.address, isNot('192.168.3.58'));
  });

  test('198.18/15 视为非局域网首选', () {
    expect(
      isDeprioritizedLanCandidate(
        const LocalIpv4Candidate(address: '198.18.0.1', interfaceName: 'Meta'),
      ),
      isTrue,
    );
    expect(
      isDeprioritizedLanCandidate(
        const LocalIpv4Candidate(address: '192.168.3.58', interfaceName: '以太网'),
      ),
      isFalse,
    );
  });
}
