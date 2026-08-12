import 'package:meta/meta.dart';

import 'op.dart';

/// WebSocket 上的消息类型。
///
/// 走 JSON，每条消息一个 `type` 字段。协议定义放在 shared 里，客户端和
/// 服务端共用同一份——协议改了两边一起改，不会漏。
abstract final class MsgType {
  // 客户端 → 服务端
  static const hello = 'HELLO';
  static const push = 'PUSH';
  static const ping = 'PING';

  // 服务端 → 客户端
  static const sync = 'SYNC';
  static const ack = 'ACK';
  static const broadcast = 'BROADCAST';
  static const snapshotRequired = 'SNAPSHOT_REQUIRED';
  static const error = 'ERROR';
  static const pong = 'PONG';

  /// 配对成功，下发长期令牌。
  static const paired = 'PAIRED';

  /// 双向：谁在编辑哪张卡片。
  static const editing = 'EDITING';
}

abstract final class ErrorCode {
  static const badToken = 'BAD_TOKEN';
  static const badMessage = 'BAD_MESSAGE';
  static const serverError = 'SERVER_ERROR';
}

/// 协议消息的基类。
@immutable
sealed class SyncMessage {
  const SyncMessage();

  String get type;

  Map<String, Object?> toJson();

  /// 解析一条消息。
  ///
  /// 未知的 `type` 返回 [UnknownMessage] 而不是抛异常——协议以后加了新
  /// 消息类型时，旧版本的客户端应当安静忽略，而不是断开连接。
  static SyncMessage fromJson(Map<String, Object?> json) {
    return switch (json['type']) {
      MsgType.hello => HelloMessage.fromJson(json),
      MsgType.push => PushMessage.fromJson(json),
      MsgType.ping => const PingMessage(),
      MsgType.pong => const PongMessage(),
      MsgType.sync => SyncOpsMessage.fromJson(json),
      MsgType.ack => AckMessage.fromJson(json),
      MsgType.broadcast => BroadcastMessage.fromJson(json),
      MsgType.editing => EditingMessage.fromJson(json),
      MsgType.paired => PairedMessage.fromJson(json),
      MsgType.snapshotRequired => const SnapshotRequiredMessage(),
      MsgType.error => ErrorMessage.fromJson(json),
      final other => UnknownMessage('$other'),
    };
  }
}

/// 建连握手。
class HelloMessage extends SyncMessage {
  final String deviceId;
  final String deviceName;

  /// 配对时签发的长期令牌。首次配对走一次性配对码，这里为 null。
  final String? token;

  /// 一次性配对码，仅首次配对时带。
  final String? pairCode;

  /// 本机已经同步到的最大 seq。服务端据此补齐增量。
  final int lastSeq;

  const HelloMessage({
    required this.deviceId,
    required this.deviceName,
    required this.token,
    required this.pairCode,
    required this.lastSeq,
  });

  @override
  String get type => MsgType.hello;

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'device_id': deviceId,
    'device_name': deviceName,
    if (token != null) 'token': token,
    if (pairCode != null) 'pair_code': pairCode,
    'last_seq': lastSeq,
  };

  factory HelloMessage.fromJson(Map<String, Object?> json) => HelloMessage(
    deviceId: json['device_id']! as String,
    deviceName: (json['device_name'] as String?) ?? '未命名设备',
    token: json['token'] as String?,
    pairCode: json['pair_code'] as String?,
    lastSeq: (json['last_seq'] as num?)?.toInt() ?? 0,
  );
}

/// 提交一批 op。
///
/// 批量操作（例如清空干草仓库可能涉及几百张卡）必须打包成一条消息，
/// 不能拆成几百条。
class PushMessage extends SyncMessage {
  final List<Op> ops;

  const PushMessage(this.ops);

  @override
  String get type => MsgType.push;

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'ops': [for (final op in ops) op.toJson()],
  };

  factory PushMessage.fromJson(Map<String, Object?> json) => PushMessage([
    for (final o in (json['ops'] as List? ?? const []))
      Op.fromJson((o as Map).cast<String, Object?>()),
  ]);
}

/// 增量补齐：`last_seq` 之后的所有 op。
class SyncOpsMessage extends SyncMessage {
  final List<Op> ops;

  /// 服务端当前的最大 seq。客户端应用完后把 last_seq 推到这里。
  final int serverSeq;

  const SyncOpsMessage({required this.ops, required this.serverSeq});

  @override
  String get type => MsgType.sync;

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'ops': [for (final op in ops) op.toJson()],
    'server_seq': serverSeq,
  };

  factory SyncOpsMessage.fromJson(Map<String, Object?> json) => SyncOpsMessage(
    ops: [
      for (final o in (json['ops'] as List? ?? const []))
        Op.fromJson((o as Map).cast<String, Object?>()),
    ],
    serverSeq: (json['server_seq'] as num?)?.toInt() ?? 0,
  );
}

/// 确认 PUSH，回填 seq。
///
/// 客户端收到后不能只把 seq 填进去——还必须重放受影响的字段，
/// 否则会丢更新。原因见设计文档 §4.5。
class AckMessage extends SyncMessage {
  /// opId → 服务端分配的 seq。
  final Map<String, int> seqByOpId;

  const AckMessage(this.seqByOpId);

  @override
  String get type => MsgType.ack;

  @override
  Map<String, Object?> toJson() => {'type': type, 'seqs': seqByOpId};

  factory AckMessage.fromJson(Map<String, Object?> json) => AckMessage({
    for (final e in (json['seqs'] as Map? ?? const {}).entries)
      '${e.key}': (e.value as num).toInt(),
  });
}

/// 别的设备的改动。
class BroadcastMessage extends SyncMessage {
  final List<Op> ops;

  const BroadcastMessage(this.ops);

  @override
  String get type => MsgType.broadcast;

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'ops': [for (final op in ops) op.toJson()],
  };

  factory BroadcastMessage.fromJson(Map<String, Object?> json) =>
      BroadcastMessage([
        for (final o in (json['ops'] as List? ?? const []))
          Op.fromJson((o as Map).cast<String, Object?>()),
      ]);
}

/// 谁正在编辑哪张卡片。
///
/// 两端同时改同一段长正文时，字段级 LWW 会整段丢掉一方的改动。真正的
/// 协同编辑要上 CRDT，对个人项目太重，不做。但局域网是实时连接的，
/// 这条消息成本极低，能挡掉绝大部分实际冲突。
class EditingMessage extends SyncMessage {
  final String cardId;
  final bool active;

  /// 客户端发出时留空，服务端转发时填上是谁。
  final String? deviceName;

  const EditingMessage({
    required this.cardId,
    required this.active,
    this.deviceName,
  });

  @override
  String get type => MsgType.editing;

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'card_id': cardId,
    'active': active,
    if (deviceName != null) 'device_name': deviceName,
  };

  factory EditingMessage.fromJson(Map<String, Object?> json) => EditingMessage(
    cardId: json['card_id']! as String,
    active: json['active'] == true,
    deviceName: json['device_name'] as String?,
  );
}

/// 配对成功，下发长期令牌。
///
/// 客户端把它存起来，之后每次连接用令牌而不是配对码——配对码是一次性的，
/// 5 分钟就过期。
class PairedMessage extends SyncMessage {
  final String token;

  const PairedMessage(this.token);

  @override
  String get type => MsgType.paired;

  @override
  Map<String, Object?> toJson() => {'type': type, 'token': token};

  factory PairedMessage.fromJson(Map<String, Object?> json) =>
      PairedMessage((json['token'] as String?) ?? '');
}

/// 要求客户端丢弃本地状态、走全量重建。
///
/// 目前的压缩（每个字段只留最新一条）**不需要**触发它：被删掉的 op 一定
/// 是被某条更晚的 op 顶掉的，而那条更晚的 op 还在，任何客户端补增量时
/// 都会收到它。留着这条消息是给以后的墓碑回收用——那才是真的会让离线
/// 太久的客户端漏掉信息的操作。
class SnapshotRequiredMessage extends SyncMessage {
  const SnapshotRequiredMessage();

  @override
  String get type => MsgType.snapshotRequired;

  @override
  Map<String, Object?> toJson() => {'type': type};
}

class ErrorMessage extends SyncMessage {
  final String code;
  final String message;

  const ErrorMessage(this.code, this.message);

  @override
  String get type => MsgType.error;

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'code': code,
    'message': message,
  };

  factory ErrorMessage.fromJson(Map<String, Object?> json) => ErrorMessage(
    (json['code'] as String?) ?? ErrorCode.serverError,
    (json['message'] as String?) ?? '',
  );
}

class PingMessage extends SyncMessage {
  const PingMessage();

  @override
  String get type => MsgType.ping;

  @override
  Map<String, Object?> toJson() => {'type': type};
}

class PongMessage extends SyncMessage {
  const PongMessage();

  @override
  String get type => MsgType.pong;

  @override
  Map<String, Object?> toJson() => {'type': type};
}

/// 认不出来的消息类型。
///
/// 以后协议加了新消息时，旧版本应当安静忽略而不是断开连接——
/// 新旧版本混跑是随身携带的服务端必然会遇到的情况。
class UnknownMessage extends SyncMessage {
  final String rawType;

  const UnknownMessage(this.rawType);

  @override
  String get type => rawType;

  @override
  Map<String, Object?> toJson() => {'type': rawType};
}
