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

/// 某个本机地址对应的子网广播地址。
///
/// **macOS 上发往 255.255.255.255 会直接失败**（send 返回 0），必须用
/// 子网定向广播。Dart 的 NetworkInterface 不暴露子网掩码，所以按 /24 推算
/// ——家庭和办公网络几乎都是 /24，个别不是的还有手动填地址那条路兜底。
String? subnetBroadcast(String address) {
  final parts = address.split('.');
  if (parts.length != 4) return null;
  if (parts.any((p) => int.tryParse(p) == null)) return null;
  return '${parts[0]}.${parts[1]}.${parts[2]}.255';
}

/// 一个本机地址要往哪些目标发广播。
///
/// [includeLimitedBroadcast] 只在 Windows 上开。**在 macOS 上发往
/// 255.255.255.255 不只是失败，还会把 socket 弄坏**——之后连回环地址
/// 都发不出去了。为了一个注定失败的目标搭上整轮广播不值得。
List<String> broadcastTargetsFor(
  String address, {
  bool includeLimitedBroadcast = false,
}) => [
  // 子网定向广播：真正能到达局域网里其他设备的那个
  ?subnetBroadcast(address),
  if (includeLimitedBroadcast) '255.255.255.255',
  // 回环：服务端和客户端跑在同一台笔记本上是最常见的用法，
  // 而广播不会回环到本机
  '127.0.0.1',
];

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

    // **必须给 onError。** RawDatagramSocket 的发送失败不是同步抛异常，
    // 而是通过错误流异步报出来的——所以包在 send 外面的 try/catch 根本
    // 拦不住它。没有 onError 的话，一次发往不可达地址的广播就会变成
    // 未捕获的异步错误，把整个服务端进程干掉。
    //
    // 局域网发现是锦上添花的功能，绝不能拖垮同步。
    _socket!.listen(
      (event) {
        if (event == RawSocketEvent.write) _flush();
      },
      onError: (Object e) => onLog?.call('广播出错（已忽略）：$e'),
      cancelOnError: false,
    );

    _timer = Timer.periodic(interval, (_) => _broadcast());
    await _broadcast();
  }

  /// 这一轮还没发出去的包。
  ///
  /// `RawDatagramSocket.send()` 在 socket 尚未写就绪时会**静默返回 0**，
  /// 包根本没发出去。所以先直接试一次，没发完的等写就绪事件再补。
  ///
  /// 每轮都重建这个列表：发不出去的目标（比如 macOS 上的 255.255.255.255）
  /// 不该赖在队列里反复触发写事件，下一轮 2 秒后自然会重试。
  List<(List<int>, InternetAddress)> _pending = [];

  Future<void> _broadcast() async {
    final socket = _socket;
    if (socket == null) return;

    final addresses = await currentAddresses();
    final batch = <(List<int>, InternetAddress)>[];
    for (final host in addresses) {
      final beacon = DiscoveryBeacon(
        host: host,
        port: syncPort,
        name: serverName,
      );
      final payload = utf8.encode(jsonEncode(beacon.toJson()));
      for (final target in broadcastTargetsFor(
        host,
        includeLimitedBroadcast: Platform.isWindows,
      )) {
        try {
          batch.add((payload, InternetAddress(target)));
        } catch (_) {
          // 地址解析不了就跳过。
        }
      }
    }

    _pending = batch;
    _flush();
    // 还有没发出去的，等写就绪再补一次。
    if (_pending.isNotEmpty) socket.writeEventsEnabled = true;
  }

  void _flush() {
    final socket = _socket;
    if (socket == null || _pending.isEmpty) return;

    final remaining = <(List<int>, InternetAddress)>[];
    for (final (payload, target) in _pending) {
      try {
        if (socket.send(payload, target, kDiscoveryPort) == 0) {
          remaining.add((payload, target));
        }
      } catch (_) {
        // 某个目标不可达（比如 macOS 上的受限广播地址）。下一轮再说。
      }
    }
    _pending = remaining;
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _socket?.close();
    _socket = null;
  }
}
