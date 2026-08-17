import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:server/src/store.dart';
import 'package:server/src/sync_server.dart';
import 'package:shared/shared.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// 一个测试用的客户端，把 WebSocket 包成「发一条、等一条」的形式。
class TestClient {
  final WebSocketChannel channel;
  final StreamQueue<SyncMessage> incoming;

  TestClient(this.channel)
    : incoming = StreamQueue(
        channel.stream.map(
          (raw) => SyncMessage.fromJson(
            jsonDecode(raw as String) as Map<String, Object?>,
          ),
        ),
      );

  static Future<TestClient> connect(int port) async {
    final ch = WebSocketChannel.connect(
      Uri.parse('ws://localhost:$port/sync'),
    );
    await ch.ready;
    return TestClient(ch);
  }

  void send(SyncMessage msg) => channel.sink.add(jsonEncode(msg.toJson()));

  /// 收到过的设备名单，按到达顺序。
  final List<DevicesMessage> devices = [];

  /// 等下一条消息，**跳过设备名单**。
  ///
  /// DEVICES 是旁路通知：握手后会来一条，之后任何设备配对或改名也会来。
  /// 它落在哪两条消息之间不属于协议约定，大多数测试不该因此改写。
  /// 真要断言名单内容的用 [nextDevices]。
  Future<SyncMessage> next() async {
    while (true) {
      final msg = await incoming.next.timeout(const Duration(seconds: 5));
      if (msg is DevicesMessage) {
        devices.add(msg);
        continue;
      }
      return msg;
    }
  }

  /// 等下一条设备名单，中间别的消息一律丢掉。
  Future<DevicesMessage> nextDevices() async {
    while (true) {
      final msg = await incoming.next.timeout(const Duration(seconds: 5));
      if (msg is DevicesMessage) {
        devices.add(msg);
        return msg;
      }
    }
  }

  /// 一段时间内没有新消息才算通过——用来断言「不该收到」。
  ///
  /// 和 [next] 一样跳过设备名单：那是旁路通知，不算「回应」。
  Future<void> expectSilence([
    Duration window = const Duration(milliseconds: 300),
  ]) async {
    while (true) {
      final got = await incoming.hasNext
          .timeout(window, onTimeout: () => false)
          .catchError((_) => false);
      if (!got) return;

      final msg = await incoming.next;
      if (msg is DevicesMessage) {
        devices.add(msg);
        continue;
      }
      fail('不该收到消息，却收到了 ${msg.type}');
    }
  }

  Future<void> close() async {
    await incoming.cancel(immediate: true);
    await channel.sink.close();
  }
}

Op op(String id, {String field = CardF.title, Object? value = 'x'}) => Op(
  opId: id,
  boardId: 'b1',
  entity: Entity.card,
  entityId: 'c1',
  field: field,
  value: value,
  deviceId: 'dev',
  wallTs: 0,
);

void main() {
  late Store store;
  late SyncServer sync;
  late HttpServer server;
  late int port;

  setUp(() async {
    store = Store.memory();
    sync = SyncServer(store);
    server = await shelf_io.serve(
      (request) => request.url.path == 'sync'
          ? sync.handler(request)
          : throw UnsupportedError('只测 /sync'),
      InternetAddress.loopbackIPv4,
      0,
    );
    port = server.port;
  });

  tearDown(() async {
    await sync.shutdown();
    await server.close(force: true);
    store.close();
  });

  /// 完成一次配对握手，返回已连上的客户端和它的令牌。
  Future<(TestClient, String)> pairedClient(
    String deviceId,
    String name, {
    int lastSeq = 0,
  }) async {
    final code = sync.newPairCode();
    final client = await TestClient.connect(port);
    client.send(
      HelloMessage(
        deviceId: deviceId,
        deviceName: name,
        token: null,
        pairCode: code,
        lastSeq: lastSeq,
      ),
    );
    final paired = await client.next() as PairedMessage;
    await client.next(); // SYNC
    return (client, paired.token);
  }

  group('握手', () {
    test('没配对过、也没配对码，被拒绝', () async {
      final client = await TestClient.connect(port);
      client.send(
        const HelloMessage(
          deviceId: 'dev-1',
          deviceName: '陌生设备',
          token: null,
          pairCode: null,
          lastSeq: 0,
        ),
      );

      final msg = await client.next();
      expect(msg, isA<ErrorMessage>());
      expect((msg as ErrorMessage).code, ErrorCode.badToken);
      await client.close();
    });

    test('配对码正确，签发令牌并补齐增量', () async {
      final code = sync.newPairCode();
      final client = await TestClient.connect(port);
      client.send(
        HelloMessage(
          deviceId: 'dev-1',
          deviceName: '我的 Mac',
          token: null,
          pairCode: code,
          lastSeq: 0,
        ),
      );

      final paired = await client.next();
      expect(paired, isA<PairedMessage>());
      expect((paired as PairedMessage).token, isNotEmpty);

      expect(await client.next(), isA<SyncOpsMessage>());
      expect(store.devices.single.name, '我的 Mac');
      await client.close();
    });

    test('配对码是一次性的，第二台设备用同一个码会被拒', () async {
      final code = sync.newPairCode();

      final first = await TestClient.connect(port);
      first.send(
        HelloMessage(
          deviceId: 'dev-1',
          deviceName: 'A',
          token: null,
          pairCode: code,
          lastSeq: 0,
        ),
      );
      await first.next();
      await first.next();

      final second = await TestClient.connect(port);
      second.send(
        HelloMessage(
          deviceId: 'dev-2',
          deviceName: 'B',
          token: null,
          pairCode: code,
          lastSeq: 0,
        ),
      );
      expect(await second.next(), isA<ErrorMessage>());

      await first.close();
      await second.close();
    });

    test('配对过的设备可以用令牌重连', () async {
      final (first, token) = await pairedClient('dev-1', 'A');
      await first.close();

      final again = await TestClient.connect(port);
      again.send(
        HelloMessage(
          deviceId: 'dev-1',
          deviceName: 'A',
          token: token,
          pairCode: null,
          lastSeq: 0,
        ),
      );

      expect(await again.next(), isA<SyncOpsMessage>());
      await again.close();
    });

    test('令牌不对的老设备被拒', () async {
      final (first, _) = await pairedClient('dev-1', 'A');
      await first.close();

      final again = await TestClient.connect(port);
      again.send(
        const HelloMessage(
          deviceId: 'dev-1',
          deviceName: 'A',
          token: '伪造的令牌',
          pairCode: null,
          lastSeq: 0,
        ),
      );

      expect(await again.next(), isA<ErrorMessage>());
      await again.close();
    });

    test('握手前发别的消息会被拒并断开', () async {
      final client = await TestClient.connect(port);
      client.send(PushMessage([op('a')]));

      final msg = await client.next();
      expect(msg, isA<ErrorMessage>());
      await client.close();
    });
  });

  group('推送与广播', () {
    test('PUSH 得到 ACK，seq 由服务端分配', () async {
      final (client, _) = await pairedClient('dev-1', 'A');

      client.send(PushMessage([op('a'), op('b')]));
      final ack = await client.next() as AckMessage;

      expect(ack.seqByOpId.keys.toSet(), {'a', 'b'});
      expect(ack.seqByOpId['b']!, greaterThan(ack.seqByOpId['a']!));
      await client.close();
    });

    test('其他设备收到广播，发起方自己不收', () async {
      final (a, _) = await pairedClient('dev-1', 'A');
      final (b, _) = await pairedClient('dev-2', 'B');

      a.send(PushMessage([op('a', value: '新标题')]));

      final ack = await a.next();
      expect(ack, isA<AckMessage>(), reason: '发起方应当先收到 ACK');

      final broadcast = await b.next() as BroadcastMessage;
      expect(broadcast.ops.single.opId, 'a');
      expect(broadcast.ops.single.value, '新标题');
      expect(
        broadcast.ops.single.seq,
        isNotNull,
        reason: '广播出去的 op 必须带 seq，否则对方无法定序',
      );

      // 发起方本地早就应用过了，不该再收一遍。
      await a.expectSilence();

      await a.close();
      await b.close();
    });

    test('重连时按 last_seq 补齐落下的改动', () async {
      final (a, _) = await pairedClient('dev-1', 'A');
      a.send(PushMessage([op('a'), op('b')]));
      final ack = await a.next() as AckMessage;
      final firstSeq = ack.seqByOpId['a']!;

      // 另一台设备只同步到第一条
      final code = sync.newPairCode();
      final late = await TestClient.connect(port);
      late.send(
        HelloMessage(
          deviceId: 'dev-2',
          deviceName: 'B',
          token: null,
          pairCode: code,
          lastSeq: firstSeq,
        ),
      );
      await late.next(); // PAIRED
      final syncMsg = await late.next() as SyncOpsMessage;

      expect(syncMsg.ops.map((o) => o.opId), ['b']);
      expect(syncMsg.serverSeq, store.maxSeq);

      await a.close();
      await late.close();
    });

    test('重复推送同一条 op，ACK 给回原来的 seq', () async {
      final (client, _) = await pairedClient('dev-1', 'A');

      client.send(PushMessage([op('a')]));
      final first = await client.next() as AckMessage;

      client.send(PushMessage([op('a')]));
      final again = await client.next() as AckMessage;

      expect(again.seqByOpId['a'], first.seqByOpId['a']);
      expect(store.opCount, 1, reason: '同一次修改不该在 log 里出现两遍');
      await client.close();
    });

    test('空的 PUSH 不产生任何回应', () async {
      final (client, _) = await pairedClient('dev-1', 'A');
      client.send(const PushMessage([]));
      await client.expectSilence();
      await client.close();
    });
  });

  group('编辑态转发', () {
    test('转发给其他设备并带上是谁', () async {
      final (a, _) = await pairedClient('dev-1', '我的 Mac');
      final (b, _) = await pairedClient('dev-2', '台式机');

      a.send(const EditingMessage(cardId: 'c1', active: true));

      final msg = await b.next() as EditingMessage;
      expect(msg.cardId, 'c1');
      expect(msg.active, isTrue);
      expect(msg.deviceName, '我的 Mac');

      await a.close();
      await b.close();
    });
  });

  group('连接管理', () {
    test('同一设备重连时旧连接被踢掉，不会收到两份广播', () async {
      final (a, tokenA) = await pairedClient('dev-1', 'A');
      final (b, _) = await pairedClient('dev-2', 'B');

      // A 用同一个 deviceId 再连一次
      final aAgain = await TestClient.connect(port);
      aAgain.send(
        HelloMessage(
          deviceId: 'dev-1',
          deviceName: 'A',
          token: tokenA,
          pairCode: null,
          lastSeq: 0,
        ),
      );
      await aAgain.next(); // SYNC

      expect(sync.onlineCount, 2, reason: '旧连接应当已被踢掉');

      b.send(PushMessage([op('x')]));
      await b.next(); // ACK

      final got = await aAgain.next();
      expect(got, isA<BroadcastMessage>());
      await aAgain.expectSilence();

      await a.close();
      await b.close();
      await aAgain.close();
    });

    test('PING 得到 PONG', () async {
      final (client, _) = await pairedClient('dev-1', 'A');
      client.send(const PingMessage());
      expect(await client.next(), isA<PongMessage>());
      await client.close();
    });

    test('认不出的消息被安静忽略，连接不断', () async {
      final (client, _) = await pairedClient('dev-1', 'A');
      client.channel.sink.add(jsonEncode({'type': '未来才有的消息'}));
      await client.expectSilence();

      // 连接还活着
      client.send(const PingMessage());
      expect(await client.next(), isA<PongMessage>());
      await client.close();
    });
  });

  group('设备名单', () {
    test('握手后收到一份名单，包含自己', () async {
      final (client, _) = await pairedClient('dev-1', '台式机');
      final msg = await client.nextDevices();
      expect(msg.names, {'dev-1': '台式机'});
      await client.close();
    });

    test('新设备配对时，已在线的设备也收到更新后的名单', () async {
      // 这是名单必须广播的理由：别的设备靠它才知道新来的这台叫什么，
      // 否则改动记录里只能显示一串设备 ID。
      final (a, _) = await pairedClient('dev-1', '台式机');
      await a.nextDevices();

      final (b, _) = await pairedClient('dev-2', '手机');

      final updated = await a.nextDevices();
      expect(updated.names, {'dev-1': '台式机', 'dev-2': '手机'});

      await a.close();
      await b.close();
    });

    test('老设备只是重连时，不打扰别人', () async {
      // 名单没变就不该广播——每次有人重连都给所有人发一遍纯属噪音。
      final (a, tokenA) = await pairedClient('dev-1', '台式机');
      final (b, _) = await pairedClient('dev-2', '手机');
      await a.nextDevices();
      await a.nextDevices();
      await b.nextDevices();

      final again = await TestClient.connect(port);
      again.send(
        HelloMessage(
          deviceId: 'dev-1',
          deviceName: '台式机',
          token: tokenA,
          pairCode: null,
          lastSeq: 0,
        ),
      );
      await again.next(); // SYNC
      expect(await again.nextDevices(), isNotNull, reason: '重连的这台自己要收到');

      // b 不该因为 a 重连而收到新名单。
      await b.expectSilence();
      expect(b.devices, hasLength(1), reason: 'b 只在自己配对时收过一份');

      await a.close();
      await b.close();
      await again.close();
    });

    test('设备改名后，名单跟着更新并广播', () async {
      final (a, tokenA) = await pairedClient('dev-1', '旧名字');
      final (b, _) = await pairedClient('dev-2', '手机');
      await b.nextDevices();

      final renamed = await TestClient.connect(port);
      renamed.send(
        HelloMessage(
          deviceId: 'dev-1',
          deviceName: '新名字',
          token: tokenA,
          pairCode: null,
          lastSeq: 0,
        ),
      );
      await renamed.next(); // SYNC

      final onB = await b.nextDevices();
      expect(onB.names['dev-1'], '新名字');
      expect(
        store.deviceById('dev-1')!.name,
        '新名字',
        reason: '改名要落库，不然下次启动又回到旧名字',
      );

      await a.close();
      await b.close();
      await renamed.close();
    });

    test('踢掉设备后，名单里不再有它', () async {
      final (a, _) = await pairedClient('dev-1', '台式机');
      final (b, _) = await pairedClient('dev-2', '手机');
      await a.nextDevices();
      await a.nextDevices();

      store.unpair('dev-2');
      expect(
        {for (final d in store.devices) d.id},
        {'dev-1'},
      );

      await a.close();
      await b.close();
    });
  });
}
