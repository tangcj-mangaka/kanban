import 'dart:async';
import 'dart:convert';

import 'package:shared/shared.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'store.dart';

/// 一条已建立的连接。
class ClientConnection {
  final WebSocketChannel channel;

  String? deviceId;
  String deviceName = '未知设备';
  bool authed = false;

  ClientConnection(this.channel);

  void send(SyncMessage msg) {
    try {
      channel.sink.add(jsonEncode(msg.toJson()));
    } catch (_) {
      // 对端刚断开，写失败很正常，不值得吵。
    }
  }
}

/// 局域网同步服务端。
///
/// 职责只有三件：给 op 分配全局序号、把 op 广播给其他在线设备、管理配对。
/// 它**不理解数据模型**，也从不物化——那是客户端的事。
class SyncServer {
  final Store store;
  final void Function(String message)? onLog;

  final Set<ClientConnection> _clients = {};

  String? _pairCode;
  DateTime? _pairCodeExpiresAt;

  /// 配对码的有效期。够从一台设备抄到另一台，又短到丢了也不要紧。
  static const pairCodeTtl = Duration(minutes: 5);

  SyncServer(this.store, {this.onLog});

  /// 当前在线的设备名。
  List<String> get onlineDevices => [
    for (final c in _clients)
      if (c.authed) c.deviceName,
  ];

  int get onlineCount => _clients.where((c) => c.authed).length;

  /// 当前有效的配对码，过期或用掉后为 null。
  String? get currentPairCode {
    if (_pairCode == null || _pairCodeExpiresAt == null) return null;
    if (DateTime.now().isAfter(_pairCodeExpiresAt!)) return null;
    return _pairCode;
  }

  /// 生成一个新的一次性配对码，覆盖掉旧的。
  String newPairCode() {
    _pairCode = generatePairCode();
    _pairCodeExpiresAt = DateTime.now().add(pairCodeTtl);
    _log('配对码 $_pairCode，${pairCodeTtl.inMinutes} 分钟内有效');
    return _pairCode!;
  }

  bool _pairCodeValid(String? code) {
    if (code == null || _pairCode == null) return false;
    if (_pairCodeExpiresAt == null ||
        DateTime.now().isAfter(_pairCodeExpiresAt!)) {
      return false;
    }
    return code.toUpperCase() == _pairCode;
  }

  Handler get handler => webSocketHandler(_onConnect);

  void _onConnect(WebSocketChannel channel, _) {
    final client = ClientConnection(channel);
    _clients.add(client);

    channel.stream.listen(
      (raw) => _onMessage(client, raw),
      onDone: () => _onDisconnect(client),
      onError: (_) => _onDisconnect(client),
      cancelOnError: true,
    );
  }

  void _onDisconnect(ClientConnection client) {
    _clients.remove(client);
    if (client.authed) _log('${client.deviceName} 断开，在线 $onlineCount');
  }

  void _onMessage(ClientConnection client, Object? raw) {
    late final SyncMessage msg;
    try {
      msg = SyncMessage.fromJson(
        jsonDecode(raw as String) as Map<String, Object?>,
      );
    } catch (_) {
      client.send(const ErrorMessage(ErrorCode.badMessage, '消息解析失败'));
      return;
    }

    // 握手之前只认 HELLO。
    if (!client.authed && msg is! HelloMessage) {
      client.send(const ErrorMessage(ErrorCode.badToken, '请先握手'));
      client.channel.sink.close();
      return;
    }

    switch (msg) {
      case HelloMessage():
        _onHello(client, msg);
      case PushMessage():
        _onPush(client, msg);
      case EditingMessage():
        _onEditing(client, msg);
      case PingMessage():
        client.send(const PongMessage());
      default:
        // 认不出的消息安静忽略——新旧版本混跑是随身携带的服务端必然
        // 会遇到的情况，不该因此断开。
        break;
    }
  }

  void _onHello(ClientConnection client, HelloMessage hello) {
    final known = store.deviceById(hello.deviceId);
    String? issuedToken;

    // 老设备改了名字的话要记下来，否则名单里永远是配对那天报的名字。
    var renamed = false;

    if (known != null && hello.token == known.token) {
      // 老设备，令牌对得上。
      if (known.name != hello.deviceName && hello.deviceName.isNotEmpty) {
        store.renameDevice(hello.deviceId, hello.deviceName);
        renamed = true;
      }
    } else if (_pairCodeValid(hello.pairCode)) {
      issuedToken = store.pair(hello.deviceId, hello.deviceName).token;
      // 配对码是一次性的，用掉即焚。
      _pairCode = null;
      _pairCodeExpiresAt = null;
      _log('${hello.deviceName} 配对成功');
    } else {
      client.send(
        ErrorMessage(
          ErrorCode.badToken,
          known == null ? '尚未配对，请输入配对码' : '令牌无效，请重新配对',
        ),
      );
      client.channel.sink.close();
      return;
    }

    // 同一台设备重连时，把旧连接踢掉，免得广播发两份。
    for (final other in [..._clients]) {
      if (other != client && other.deviceId == hello.deviceId) {
        other.channel.sink.close();
        _clients.remove(other);
      }
    }

    client
      ..deviceId = hello.deviceId
      ..deviceName = hello.deviceName
      ..authed = true;
    store.touchDevice(hello.deviceId);

    if (issuedToken != null) client.send(PairedMessage(issuedToken));

    final ops = store.opsSince(hello.lastSeq);
    client.send(SyncOpsMessage(ops: ops, serverSeq: store.maxSeq));
    _log('${hello.deviceName} 上线，补齐 ${ops.length} 条，在线 $onlineCount');

    // 设备名单只有服务端知道（每台设备只在 HELLO 里报自己的名字），
    // 客户端要靠它把 op 日志里的设备 ID 翻译成人看得懂的名字。
    //
    // 刚上线的这台一定要发——它需要整份名单。
    // 其余设备只在名单**真的变了**时才发（新配对，或者这台改了名）：
    // 每次有人重连就给所有人广播一遍纯属噪音，而且会让「自己推送的
    // 改动不该收到回音」这类断言变得难写。
    final rosterChanged = issuedToken != null || renamed;
    if (rosterChanged) {
      _broadcastDevices();
    } else {
      client.send(_devicesMessage());
    }
  }

  DevicesMessage _devicesMessage() =>
      DevicesMessage({for (final d in store.devices) d.id: d.name});

  /// 把「设备 ID → 名字」推给所有已认证的连接。
  void _broadcastDevices() {
    final msg = _devicesMessage();
    for (final c in _clients) {
      if (c.authed) c.send(msg);
    }
  }

  void _onPush(ClientConnection client, PushMessage push) {
    if (push.ops.isEmpty) return;

    final assigned = store.append(push.ops);

    // 先 ACK 给发起方：它要用这些 seq 回填并重放受影响的字段。
    client.send(AckMessage(assigned));

    // 再把带上 seq 的完整 op 广播给其他人。发起方不用收——它本地早就
    // 应用过了，重复发一遍只是浪费。
    final stored = store.opsByIds(assigned.keys);
    if (stored.isEmpty) return;
    for (final other in _clients) {
      if (other == client || !other.authed) continue;
      other.send(BroadcastMessage(stored));
    }
  }

  void _onEditing(ClientConnection client, EditingMessage editing) {
    final forwarded = EditingMessage(
      cardId: editing.cardId,
      active: editing.active,
      deviceName: client.deviceName,
    );
    for (final other in _clients) {
      if (other == client || !other.authed) continue;
      other.send(forwarded);
    }
  }

  /// 断开所有连接，准备停服。
  Future<void> shutdown() async {
    for (final c in [..._clients]) {
      await c.channel.sink.close();
    }
    _clients.clear();
  }

  void _log(String message) => onLog?.call(message);
}
