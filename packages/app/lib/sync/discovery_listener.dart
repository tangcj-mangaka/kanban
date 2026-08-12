import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared/shared.dart';

/// 一台在局域网里发现的服务端。
@immutable
class DiscoveredServer {
  final DiscoveryBeacon beacon;
  final DateTime lastSeen;

  const DiscoveredServer(this.beacon, this.lastSeen);

  String get host => beacon.host;
  int get port => beacon.port;
  String get name => beacon.name;
}

/// 监听局域网里的服务端广播。
///
/// 有它就不用手抄 IP——打开设置页，同一网段的服务端会自己冒出来。
/// 手动填的入口仍然保留：跨网段、广播被路由器拦掉、或者干脆没广播的
/// 情况都存在，自动发现只是省事，不能是唯一的路。
class DiscoveryListener {
  RawDatagramSocket? _socket;
  Timer? _sweep;

  final _servers = <String, DiscoveredServer>{};
  final _controller = StreamController<List<DiscoveredServer>>.broadcast();

  /// 超过这么久没再收到广播，就认为那台服务端下线了。
  ///
  /// 服务端每 2 秒广播一次，给到 8 秒是留了几次丢包的余量——
  /// 局域网 UDP 丢一两个包很正常，因为一次丢包就把服务端从列表里抹掉
  /// 会让界面闪个不停。
  static const staleAfter = Duration(seconds: 8);

  Stream<List<DiscoveredServer>> get stream async* {
    yield _sorted();
    yield* _controller.stream;
  }

  List<DiscoveredServer> get servers => _sorted();

  Future<void> start() async {
    if (_socket != null) return;
    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        kDiscoveryPort,
        // 同一台机器上可能同时跑着服务端和客户端，也可能开了两个客户端，
        // 不复用端口的话第二个就绑不上。
        reuseAddress: true,
        reusePort: true,
      );
    } catch (_) {
      // 端口被占、系统不给权限之类。自动发现不可用不是致命问题，
      // 手动填地址那条路照常走。
      return;
    }

    _socket!.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = _socket!.receive();
      if (datagram == null) return;
      _onDatagram(datagram);
    });

    _sweep = Timer.periodic(const Duration(seconds: 3), (_) => _dropStale());
  }

  void _onDatagram(Datagram datagram) {
    try {
      final json = jsonDecode(utf8.decode(datagram.data)) as Map<String, Object?>;
      final beacon = DiscoveryBeacon.fromJson(json);
      // 局域网里什么广播都有，认不出的安静丢掉。
      if (beacon == null) return;

      final key = '${beacon.host}:${beacon.port}';
      final existed = _servers.containsKey(key);
      _servers[key] = DiscoveredServer(beacon, DateTime.now());
      // 只在列表真的变了时通知界面，不要每 2 秒重建一次。
      if (!existed) _controller.add(_sorted());
    } catch (_) {
      // 不是我们的包。
    }
  }

  void _dropStale() {
    final cutoff = DateTime.now().subtract(staleAfter);
    final before = _servers.length;
    _servers.removeWhere((_, s) => s.lastSeen.isBefore(cutoff));
    if (_servers.length != before) _controller.add(_sorted());
  }

  List<DiscoveredServer> _sorted() {
    final list = _servers.values.toList();
    list.sort((a, b) => a.name.compareTo(b.name));
    return list;
  }

  void stop() {
    _sweep?.cancel();
    _sweep = null;
    _socket?.close();
    _socket = null;
    _servers.clear();
  }

  void dispose() {
    stop();
    _controller.close();
  }
}
