import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared/shared.dart';

/// 一张网卡的必要信息。
///
/// 单独定义而不直接用 `NetworkInterface`，是为了让挑选逻辑成为可测的纯
/// 函数——真实的网卡列表在测试里造不出来，但这个结构可以。
class NetInterfaceInfo {
  final String name;
  final List<String> ipv4;

  const NetInterfaceInfo(this.name, this.ipv4);

  factory NetInterfaceInfo.from(NetworkInterface i) => NetInterfaceInfo(
    i.name,
    [
      for (final a in i.addresses)
        if (a.type == InternetAddressType.IPv4) a.address,
    ],
  );
}

/// 这张网卡是不是虚拟的 / 不该用来做局域网发现。
///
/// 这是设计文档点名的坑：多网卡环境（WiFi + VPN + VMware + Docker）下，
/// 如果挑错网卡，广播出去的是一个**别的设备根本连不上的地址**，
/// 用户看到"发现了服务端"却连不上，比没发现更让人困惑。
bool isVirtualInterface(String name) {
  final n = name.toLowerCase();

  // Unix 风格的名字用前缀判断
  const prefixes = [
    'lo', // 回环
    'utun', // VPN 隧道
    'ipsec', // VPN
    'awdl', // AirDrop
    'llw', // 苹果低延迟无线
    'bridge', // 网桥
    'vmnet', // VMware
    'vboxnet', // VirtualBox
    'anpi', // 苹果内部
    'gif', 'stf', // 隧道
    'tun', 'tap', // 通用隧道
    'docker', 'veth', // 容器
  ];
  for (final p in prefixes) {
    if (n == p || n.startsWith(p) && _startsWithPrefixThenDigit(n, p)) {
      return true;
    }
  }

  // Windows 的名字是描述性的，用子串判断
  const substrings = [
    'vmware',
    'virtualbox',
    'hyper-v',
    'vethernet',
    'loopback',
    'teredo',
    'bluetooth',
    'tailscale',
    'zerotier',
    'wireguard',
    'tap-windows',
  ];
  return substrings.any(n.contains);
}

/// `utun0`、`vmnet1` 这类"前缀 + 数字"才算命中，避免 `tun` 误伤
/// 真名里恰好含这几个字母的网卡。
bool _startsWithPrefixThenDigit(String name, String prefix) {
  if (name.length <= prefix.length) return name == prefix;
  final rest = name.substring(prefix.length);
  return RegExp(r'^\d').hasMatch(rest);
}

bool _isUsableIpv4(String address) {
  if (address.startsWith('127.')) return false; // 回环
  if (address.startsWith('169.254.')) return false; // 链路本地（DHCP 失败时的地址）
  if (address.startsWith('0.')) return false;
  return true;
}

/// 私有网段的地址排在前面——局域网里几乎一定是这些。
bool _isPrivate(String address) {
  if (address.startsWith('192.168.') || address.startsWith('10.')) return true;
  final m = RegExp(r'^172\.(\d+)\.').firstMatch(address);
  if (m == null) return false;
  final second = int.parse(m.group(1)!);
  return second >= 16 && second <= 31;
}

/// 挑出适合对外公布的本机 IPv4 地址，最合适的排在最前。
///
/// **强制 IPv4**：设计文档记过一次真实的教训——IPv6 链路本地地址带
/// 作用域后缀，跨设备直接用会连不上。
List<String> pickLanAddresses(List<NetInterfaceInfo> interfaces) {
  final candidates = <String>[];
  for (final i in interfaces) {
    if (isVirtualInterface(i.name)) continue;
    for (final a in i.ipv4) {
      if (_isUsableIpv4(a)) candidates.add(a);
    }
  }

  candidates.sort((a, b) {
    final pa = _isPrivate(a) ? 0 : 1;
    final pb = _isPrivate(b) ? 0 : 1;
    return pa != pb ? pa.compareTo(pb) : a.compareTo(b);
  });
  return candidates;
}

/// 定时往局域网广播自己的地址。
///
/// 客户端据此自动发现服务端，省得用户手抄 IP。
class DiscoveryBroadcaster {
  final int syncPort;
  final String serverName;
  final void Function(String message)? onLog;

  /// 手动指定要公布的地址。多网卡环境下自动挑选选错时的兜底。
  final String? overrideHost;

  RawDatagramSocket? _socket;
  Timer? _timer;

  DiscoveryBroadcaster({
    required this.syncPort,
    required this.serverName,
    this.overrideHost,
    this.onLog,
  });

  /// 每 2 秒一次。客户端打开设置页时不该等太久才看到服务端，
  /// 但也没必要更频繁——这是个空闲时的背景动作。
  static const interval = Duration(seconds: 2);

  Future<List<String>> currentAddresses() async {
    if (overrideHost != null) return [overrideHost!];
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    return pickLanAddresses([
      for (final i in interfaces) NetInterfaceInfo.from(i),
    ]);
  }

  Future<void> start() async {
    if (_socket != null) return;
    try {
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _socket!.broadcastEnabled = true;
    } catch (e) {
      onLog?.call('局域网广播启动失败：$e');
      return;
    }

    final addresses = await currentAddresses();
    if (addresses.isEmpty) {
      onLog?.call('没找到可用的局域网地址，自动发现不可用（仍可手动填地址连接）');
    } else {
      onLog?.call('局域网地址：${addresses.join('、')}');
    }

    _timer = Timer.periodic(interval, (_) => _broadcast());
    await _broadcast();
  }

  Future<void> _broadcast() async {
    final socket = _socket;
    if (socket == null) return;

    final addresses = await currentAddresses();
    for (final host in addresses) {
      final beacon = DiscoveryBeacon(
        host: host,
        port: syncPort,
        name: serverName,
      );
      try {
        socket.send(
          utf8.encode(jsonEncode(beacon.toJson())),
          InternetAddress('255.255.255.255'),
          kDiscoveryPort,
        );
      } catch (_) {
        // 某张网卡当下发不出去很正常（刚断网、正在切换），下一轮再试。
      }
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _socket?.close();
    _socket = null;
  }
}
