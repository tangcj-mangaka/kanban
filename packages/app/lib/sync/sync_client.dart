import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared/shared.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../data/database.dart';

/// 设置表里用到的键。
abstract final class SyncKeys {
  static const host = 'sync.host';
  static const port = 'sync.port';
  static const token = 'sync.token';
  static const deviceId = 'sync.device_id';
  static const deviceName = 'sync.device_name';

  /// 设备 ID → 名字，JSON。服务端推来的名单。
  static const deviceNames = 'sync.device_names';
  static const lastSeq = 'sync.last_seq';
}

enum SyncStatus {
  /// 没配服务器，或用户主动关了同步。
  disabled('未连接'),

  /// 配了但连不上。**这不是错误状态**——本地优先，离线照常用。
  offline('离线'),

  connecting('连接中'),

  /// 已连上，待发队列是空的。
  online('已同步'),

  /// 已连上，还有 op 在路上。
  syncing('同步中');

  final String label;

  const SyncStatus(this.label);
}

/// 同步层的对外状态。
@immutable
class SyncState {
  final SyncStatus status;

  /// 待发队列里还剩多少条。
  final int pending;

  /// 最近一次失败的原因，供设置页显示。连不上服务器不算失败原因，
  /// 只有鉴权被拒这类需要用户处理的才填。
  final String? error;

  /// 别的设备正在编辑哪些卡片：cardId → 设备名。
  final Map<String, String> editingByOthers;

  const SyncState({
    this.status = SyncStatus.disabled,
    this.pending = 0,
    this.error,
    this.editingByOthers = const {},
  });

  SyncState copyWith({
    SyncStatus? status,
    int? pending,
    String? error,
    bool clearError = false,
    Map<String, String>? editingByOthers,
  }) => SyncState(
    status: status ?? this.status,
    pending: pending ?? this.pending,
    error: clearError ? null : (error ?? this.error),
    editingByOthers: editingByOthers ?? this.editingByOthers,
  );
}

/// 局域网同步客户端。
///
/// 本地优先：**它从不阻塞任何本地操作。** 连不上就安静排队，连上了再补发。
/// 用户不需要知道它在不在，只有想知道时抬头看一眼状态就行。
class SyncClient {
  final AppDatabase db;

  /// 诊断日志。同步的问题几乎都是时序问题，靠事后推理很难对上，
  /// 得看事情实际发生的顺序。
  final void Function(String message)? onLog;

  SyncClient(this.db, {this.onLog});

  void _log(String message) => onLog?.call(message);

  final _stateController = StreamController<SyncState>.broadcast();

  /// 状态流。新订阅者会**立刻**收到当前状态，不用干等下一次变化——
  /// 否则界面刚打开时那一格是空的。
  Stream<SyncState> get stateStream async* {
    yield _state;
    yield* _stateController.stream;
  }
  SyncState get state => _state;
  SyncState _state = const SyncState();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _socketSub;
  StreamSubscription<void>? _localOpSub;
  Timer? _reconnectTimer;
  Timer? _heartbeat;
  Timer? _flushDebounce;

  bool _started = false;
  bool _handshaken = false;

  /// 鉴权被拒。停掉自动重连，但**不阻止用户重新配置**——
  /// 令牌失效正是需要人来处理的情况，把重新配对的路也堵死就没救了。
  bool _authBlocked = false;
  bool _flushing = false;
  int _reconnectAttempt = 0;

  /// 连接代次。每发起一次连接就加一，**只有最新那次有权改状态**。
  ///
  /// 没有它就会出这种事：应用启动时用旧设置连了一次，用户几乎同时用新
  /// 配对码连了第二次；第二次成功了，但第一次被拒的错误后到，
  /// 把"已同步"盖回了"令牌无效"。
  int _connectGen = 0;

  /// 连接相关的动作排队执行，一次只跑一个。
  ///
  /// 不串行化会出这种事：`configure()` 的一串 await 中间，`start()` 发起的
  /// 那条连接把刚设好的一次性配对码用掉并配对成功了；`configure()` 接着
  /// 照旧「关掉重连」，把唯一能用的连接掐了，而配对码已经消耗完——
  /// 结果是配对成功过、却停在「令牌无效」。
  Future<void> _queue = Future<void>.value();

  Future<void> _serialized(Future<void> Function() action) {
    final next = _queue.then((_) => action()).catchError((_) {});
    _queue = next;
    return next;
  }

  String? _host;
  int _port = 8765;
  String? _token;
  String? _pairCode;
  String _deviceId = '';
  String _deviceName = '';

  /// 重连退避：1s 起步翻倍，封顶 30s。
  ///
  /// 封顶是必要的——服务端是随身携带的笔记本，可能一整天都不在，
  /// 无上限退避会让它回来后要等很久才重连上。
  static const _maxBackoff = Duration(seconds: 30);

  /// 攒一下再推。用户拖一张卡片会连续产生 x、y 两条 op，
  /// 分两次发是浪费。
  static const _flushDelay = Duration(milliseconds: 150);

  /// 服务端连接信息，供附件的 HTTP 通道用。没配服务器或没配对时为 null。
  ///
  /// 附件走独立的 HTTP 通道（文件塞不进 WebSocket 的 JSON 消息），
  /// 但用的是同一台服务器、同一个令牌。
  ({String host, int port, String token})? get serverEndpoint {
    final host = _host;
    final token = _token;
    if (host == null || token == null || token.isEmpty) return null;
    return (host: host, port: _port, token: token);
  }

  // -------------------------------------------------------------------------
  // 生命周期
  // -------------------------------------------------------------------------

  /// 只做初始化（读设置、订阅本地 op），**不发起连接**。
  ///
  /// 幂等，并发调用会等到同一次完成。这一步要和「连接」分开，否则
  /// [configure] 得先跑一次用旧配置的连接——旧配置多半是错的，
  /// 那次注定被拒的连接还会把状态搅浑。
  ///
  /// 拆开之前踩过一次：`configure()` 在 `start()` 还在读设置时就去写设置，
  /// `_loadSettings` 随后用读到的旧值把刚写进去的服务器地址覆盖成了 null，
  /// 结果两边都以为"没配服务器"，连接根本没发起。
  Future<void> _ensureInit() => _initFuture ??= _init();
  Future<void>? _initFuture;

  Future<void> _init() async {
    await _loadSettings();
    _localOpSub ??= db.localOpAdded.listen((_) => _scheduleFlush());
  }

  Future<void> start() async {
    await _ensureInit();
    return _serialized(() async {
      _started = true;
      _log('start()：地址 ${_host ?? '未配置'}');

      if (_host == null) {
        _emit(_state.copyWith(status: SyncStatus.disabled));
        return;
      }
      await _connect();
    });
  }

  Future<void> stop() async {
    _started = false;
    _reconnectTimer?.cancel();
    _heartbeat?.cancel();
    _flushDebounce?.cancel();
    await _localOpSub?.cancel();
    await _closeSocket();
    _emit(const SyncState(status: SyncStatus.disabled));
  }

  Future<void> dispose() async {
    await stop();
    await _stateController.close();
  }

  /// 配置服务器地址并（重新）连接。
  ///
  /// [pairCode] 只在首次配对时给；配对成功后服务端下发的长期令牌会存下来。
  Future<void> configure({
    required String host,
    required int port,
    String? pairCode,
  }) async {
    // 只做初始化，不连接：这里马上要用新配置连，先用旧配置连一次
    // 是白费力气，而且那次多半会被拒、把状态搅浑。
    await _ensureInit();
    return _serialized(() async {
      _started = true;
      _authBlocked = false;
      _log('configure()：$host:$port，配对码${pairCode ?? '无'}');

      // 已经连着同一台、又没给新配对码，就别多此一举断开重连——
      // 断开重连本身没有坏处，但会白白浪费一次性配对码。
      if (_handshaken && _host == host && _port == port && pairCode == null) {
        _log('已连着同一台服务端，无需重连');
        return;
      }

      _host = host;
      _port = port;
      _pairCode = pairCode;
      await db.setSetting(SyncKeys.host, host);
      await db.setSetting(SyncKeys.port, '$port');
      if (pairCode != null) await db.setSetting(SyncKeys.token, null);
      _token = await db.getSetting(SyncKeys.token);

      _reconnectAttempt = 0;
      await _closeSocket();
      await _connect();
    });
  }

  /// 忘掉这台服务器：断开、清掉地址和令牌。
  Future<void> forgetServer() async {
    _host = null;
    _token = null;
    await db.setSetting(SyncKeys.host, null);
    await db.setSetting(SyncKeys.port, null);
    await db.setSetting(SyncKeys.token, null);
    await _closeSocket();
    _emit(const SyncState(status: SyncStatus.disabled));
  }

  Future<void> _loadSettings() async {
    _host = await db.getSetting(SyncKeys.host);
    _port = await db.getIntSetting(SyncKeys.port, fallback: 8765);
    _token = await db.getSetting(SyncKeys.token);

    _deviceId = await db.getSetting(SyncKeys.deviceId) ?? '';
    if (_deviceId.isEmpty) {
      _deviceId = const Uuid().v4();
      await db.setSetting(SyncKeys.deviceId, _deviceId);
    }
    _deviceName = await db.getSetting(SyncKeys.deviceName) ?? defaultDeviceName();
    db.deviceId = _deviceId;
  }

  Future<void> setDeviceName(String name) async {
    _deviceName = name;
    await db.setSetting(SyncKeys.deviceName, name);
  }

  // -------------------------------------------------------------------------
  // 连接
  // -------------------------------------------------------------------------

  Future<void> _connect() async {
    if (!_started || _host == null) return;

    final gen = ++_connectGen;
    _log('连接#$gen 开始 → $_host:$_port'
        '（令牌${_token == null ? '无' : '有'}，配对码${_pairCode ?? '无'}）');
    _reconnectTimer?.cancel();
    _emit(_state.copyWith(status: SyncStatus.connecting, clearError: true));

    try {
      final channel = WebSocketChannel.connect(
        Uri.parse('ws://$_host:$_port/sync'),
      );
      await channel.ready;
      // 等待期间又发起了新连接，这一条已经过期，直接扔掉。
      if (gen != _connectGen) {
        _log('连接#$gen 已过期（当前#$_connectGen），丢弃');
        await channel.sink.close();
        return;
      }
      _channel = channel;
      _handshaken = false;

      _socketSub = channel.stream.listen(
        (raw) => _onRaw(gen, raw),
        onDone: () => _onSocketClosed(gen),
        onError: (_) => _onSocketClosed(gen),
        cancelOnError: true,
      );

      _send(
        HelloMessage(
          deviceId: _deviceId,
          deviceName: _deviceName,
          token: _token,
          pairCode: _pairCode,
          lastSeq: await db.getIntSetting(SyncKeys.lastSeq),
        ),
      );
    } catch (_) {
      // 连不上很正常——服务端是台随身携带的笔记本。安静重试，不打扰用户。
      _onSocketClosed(gen);
    }
  }

  void _onSocketClosed(int gen) {
    if (gen != _connectGen) {
      _log('连接#$gen 断开（已过期，忽略）');
      return;
    }
    _log('连接#$gen 断开');
    _heartbeat?.cancel();
    _socketSub?.cancel();
    _socketSub = null;
    _channel = null;
    _handshaken = false;
    if (!_started || _host == null) return;

    _emit(_state.copyWith(status: SyncStatus.offline));
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    // 令牌不对时重试多少次都是一样的结果，等用户来处理。
    if (_authBlocked) return;
    _reconnectTimer?.cancel();
    final seconds = 1 << _reconnectAttempt.clamp(0, 5);
    final delay = Duration(seconds: seconds) > _maxBackoff
        ? _maxBackoff
        : Duration(seconds: seconds);
    _reconnectAttempt++;
    _reconnectTimer = Timer(delay, () => _serialized(_connect));
  }

  Future<void> _closeSocket() async {
    // 让所有在飞的连接失效。
    _connectGen++;
    _heartbeat?.cancel();
    await _socketSub?.cancel();
    _socketSub = null;
    await _channel?.sink.close();
    _channel = null;
    _handshaken = false;
  }

  // -------------------------------------------------------------------------
  // 收消息
  // -------------------------------------------------------------------------

  Future<void> _onRaw(int gen, dynamic raw) async {
    // 旧连接的消息一律不理——它说的是过时的事。
    if (gen != _connectGen) return;

    late final SyncMessage msg;
    try {
      msg = SyncMessage.fromJson(
        jsonDecode(raw as String) as Map<String, Object?>,
      );
    } catch (_) {
      return;
    }
    _log('连接#$gen 收到 ${msg.type}');

    switch (msg) {
      case PairedMessage():
        _token = msg.token;
        _pairCode = null;
        await db.setSetting(SyncKeys.token, msg.token);

      case SyncOpsMessage():
        for (final op in msg.ops) {
          await db.applyOp(op);
        }
        await db.setSetting(SyncKeys.lastSeq, '${msg.serverSeq}');
        _handshaken = true;
        _reconnectAttempt = 0;
        _emit(_state.copyWith(status: SyncStatus.online, clearError: true));
        _startHeartbeat();
        // 握手完成后立刻把离线期间攒的 op 补发出去。
        await _flush();

      case AckMessage():
        // 关键：不能只回填 seq，必须重放受影响的字段，否则会丢更新。
        // 原因见设计文档 §4.5。
        await db.ackOps(msg.seqByOpId);
        final maxAcked = msg.seqByOpId.values.fold<int>(0, (a, b) => a > b ? a : b);
        final known = await db.getIntSetting(SyncKeys.lastSeq);
        if (maxAcked > known) {
          await db.setSetting(SyncKeys.lastSeq, '$maxAcked');
        }
        _flushing = false;
        await _refreshPending();

      case BroadcastMessage():
        var maxSeq = await db.getIntSetting(SyncKeys.lastSeq);
        for (final op in msg.ops) {
          await db.applyOp(op);
          if ((op.seq ?? 0) > maxSeq) maxSeq = op.seq!;
        }
        await db.setSetting(SyncKeys.lastSeq, '$maxSeq');

      case EditingMessage():
        final next = {..._state.editingByOthers};
        if (msg.active) {
          next[msg.cardId] = msg.deviceName ?? '别的设备';
        } else {
          next.remove(msg.cardId);
        }
        _emit(_state.copyWith(editingByOthers: next));

      case ErrorMessage():
        // 鉴权被拒是用户要处理的事（重新配对），不能静默重试到天荒地老。
        if (msg.code == ErrorCode.badToken) {
          _emit(_state.copyWith(status: SyncStatus.offline, error: msg.message));
          _authBlocked = true;
          await _closeSocket();
        }

      case DevicesMessage():
        // 存起来给改动记录用：op 日志里记的是设备 ID，要靠这份名单
        // 翻译成「手机」「台式机」。存到设置表而不是内存里——离线时
        // 也得能显示名字，不然一断网改动记录就退回一串 ID。
        await db.setSetting(SyncKeys.deviceNames, jsonEncode(msg.names));

      case SnapshotRequiredMessage():
        // 当前的压缩策略不会触发它（见协议里的说明），留给以后的墓碑回收。
        _emit(
          _state.copyWith(error: '服务端要求全量重建，此版本尚未实现'),
        );

      default:
        break;
    }
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _send(const PingMessage()),
    );
  }

  // -------------------------------------------------------------------------
  // 发消息
  // -------------------------------------------------------------------------

  void _send(SyncMessage msg) {
    final channel = _channel;
    if (channel == null) return;
    try {
      channel.sink.add(jsonEncode(msg.toJson()));
    } catch (_) {
      _onSocketClosed(_connectGen);
    }
  }

  /// 告诉别的设备「我在编辑这张卡」。
  ///
  /// 两端同时改同一段长正文时，字段级 LWW 会整段丢掉一方的改动。真正的
  /// 协同编辑要上 CRDT，太重；这条提示成本极低，能挡掉绝大部分实际冲突。
  void reportEditing(String cardId, {required bool active}) {
    if (!_handshaken) return;
    _send(EditingMessage(cardId: cardId, active: active));
  }

  void _scheduleFlush() {
    _flushDebounce?.cancel();
    _flushDebounce = Timer(_flushDelay, _flush);
  }

  Future<void> _flush() async {
    await _refreshPending();
    if (!_handshaken || _flushing) return;

    final pending = await db.pendingOps();
    if (pending.isEmpty) {
      _emit(_state.copyWith(status: SyncStatus.online));
      return;
    }

    _flushing = true;
    _emit(_state.copyWith(status: SyncStatus.syncing, pending: pending.length));
    _send(
      PushMessage([
        for (final row in pending)
          Op(
            opId: row.opId,
            boardId: row.boardId,
            entity: row.entity,
            entityId: row.entityId,
            field: row.field,
            value: jsonDecode(row.valueJson),
            deviceId: row.deviceId,
            wallTs: row.wallTs,
          ),
      ]),
    );
  }

  Future<void> _refreshPending() async {
    final count = (await db.pendingOps()).length;
    if (count == _state.pending) return;
    _emit(
      _state.copyWith(
        pending: count,
        status: _handshaken
            ? (count == 0 ? SyncStatus.online : SyncStatus.syncing)
            : _state.status,
      ),
    );
  }

  void _emit(SyncState next) {
    _state = next;
    if (!_stateController.isClosed) _stateController.add(next);
  }
}

/// 默认设备名，取个人一眼认得出的。
String defaultDeviceName() {
  if (kIsWeb) return '浏览器';
  return switch (defaultTargetPlatform) {
    TargetPlatform.macOS => 'Mac',
    TargetPlatform.windows => 'Windows',
    TargetPlatform.android => 'Android 手机',
    TargetPlatform.iOS => 'iPhone',
    TargetPlatform.linux => 'Linux',
    TargetPlatform.fuchsia => '设备',
  };
}
