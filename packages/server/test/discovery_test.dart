import 'package:server/src/discovery.dart';
import 'package:test/test.dart';

void main() {
  group('识别虚拟网卡', () {
    // 这是设计文档点名的坑：多网卡环境下挑错网卡，广播出去的是一个
    // 别的设备根本连不上的地址——用户看到"发现了服务端"却连不上，
    // 比没发现更让人困惑。
    test('macOS 上的真实网卡不该被排除', () {
      for (final name in ['en0', 'en1', 'en5']) {
        expect(isVirtualInterface(name), isFalse, reason: '$name 是真网卡');
      }
    });

    test('macOS 上的虚拟网卡要排除', () {
      for (final name in [
        'lo0', // 回环
        'utun0', 'utun3', // VPN
        'awdl0', // AirDrop
        'llw0', // 苹果低延迟无线
        'bridge0', // 网桥
        'vmnet1', 'vmnet8', // VMware
        'vboxnet0', // VirtualBox
        'anpi0', // 苹果内部
        'gif0', 'stf0',
      ]) {
        expect(isVirtualInterface(name), isTrue, reason: '$name 该被排除');
      }
    });

    test('Windows 上的真实网卡不该被排除', () {
      for (final name in ['Ethernet', 'Wi-Fi', '以太网', '本地连接']) {
        expect(isVirtualInterface(name), isFalse, reason: '$name 是真网卡');
      }
    });

    test('Windows 上的虚拟网卡要排除', () {
      for (final name in [
        'VMware Network Adapter VMnet1',
        'VirtualBox Host-Only Network',
        'vEthernet (Default Switch)',
        'Hyper-V Virtual Ethernet Adapter',
        'Software Loopback Interface 1',
        'Teredo Tunneling Pseudo-Interface',
        'Bluetooth Network Connection',
        'Tailscale',
        'ZeroTier One',
        'WireGuard Tunnel',
      ]) {
        expect(isVirtualInterface(name), isTrue, reason: '$name 该被排除');
      }
    });

    test('判断不区分大小写', () {
      expect(isVirtualInterface('VMNET1'), isTrue);
      expect(isVirtualInterface('vmware network adapter'), isTrue);
    });

    test('名字里恰好含 tun / tap 的真网卡不被误伤', () {
      // 只有"前缀 + 数字"才算命中，不做裸子串匹配。
      expect(isVirtualInterface('tuna'), isFalse);
      expect(isVirtualInterface('taproom'), isFalse);
      expect(isVirtualInterface('tun0'), isTrue);
    });
  });

  group('挑选局域网地址', () {
    test('排除回环', () {
      final got = pickLanAddresses([
        const NetInterfaceInfo('lo0', ['127.0.0.1']),
        const NetInterfaceInfo('en0', ['192.168.1.23']),
      ]);
      expect(got, ['192.168.1.23']);
    });

    test('排除链路本地地址', () {
      // 169.254.* 是 DHCP 失败时自己给自己发的地址，公布出去必然连不上。
      final got = pickLanAddresses([
        const NetInterfaceInfo('en0', ['169.254.12.7']),
        const NetInterfaceInfo('en1', ['10.0.0.5']),
      ]);
      expect(got, ['10.0.0.5']);
    });

    test('排除虚拟网卡上的地址', () {
      final got = pickLanAddresses([
        const NetInterfaceInfo('vmnet1', ['192.168.181.1']),
        const NetInterfaceInfo('vboxnet0', ['192.168.56.1']),
        const NetInterfaceInfo('en0', ['192.168.1.23']),
      ]);
      expect(
        got,
        ['192.168.1.23'],
        reason: 'VMware 和 VirtualBox 的网段别的设备根本到不了',
      );
    });

    test('私有网段排在公网地址前面', () {
      final got = pickLanAddresses([
        const NetInterfaceInfo('en0', ['203.0.113.9']),
        const NetInterfaceInfo('en1', ['192.168.1.23']),
      ]);
      expect(got.first, '192.168.1.23');
      expect(got, contains('203.0.113.9'), reason: '不确定的也留着当备选');
    });

    test('三个私有网段都认得', () {
      final got = pickLanAddresses([
        const NetInterfaceInfo('en0', ['172.20.1.5']),
        const NetInterfaceInfo('en1', ['198.51.100.7']),
      ]);
      expect(got.first, '172.20.1.5');
    });

    test('172.32 不是私有网段（私有段只到 172.31）', () {
      final got = pickLanAddresses([
        const NetInterfaceInfo('en0', ['172.32.1.5']),
        const NetInterfaceInfo('en1', ['10.1.1.1']),
      ]);
      expect(got.first, '10.1.1.1');
    });

    test('一张网卡多个地址都收下', () {
      final got = pickLanAddresses([
        const NetInterfaceInfo('en0', ['192.168.1.23', '192.168.1.24']),
      ]);
      expect(got.length, 2);
    });

    test('一个可用地址都没有时返回空，不报错', () {
      final got = pickLanAddresses([
        const NetInterfaceInfo('lo0', ['127.0.0.1']),
        const NetInterfaceInfo('utun0', ['10.8.0.2']),
      ]);
      expect(got, isEmpty);
    });

    test('空输入返回空', () {
      expect(pickLanAddresses([]), isEmpty);
    });

    test('典型的开发机环境：一堆虚拟网卡里挑出唯一那张真的', () {
      final got = pickLanAddresses([
        const NetInterfaceInfo('lo0', ['127.0.0.1']),
        const NetInterfaceInfo('en0', ['192.168.1.23']),
        const NetInterfaceInfo('awdl0', ['169.254.44.1']),
        const NetInterfaceInfo('llw0', ['169.254.55.2']),
        const NetInterfaceInfo('utun0', ['10.8.0.2']),
        const NetInterfaceInfo('utun1', ['100.64.0.1']),
        const NetInterfaceInfo('bridge0', ['192.168.99.1']),
        const NetInterfaceInfo('vmnet1', ['192.168.181.1']),
        const NetInterfaceInfo('vmnet8', ['192.168.235.1']),
      ]);
      expect(got, ['192.168.1.23']);
    });
  });
}
