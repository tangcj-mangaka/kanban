import 'dart:convert';

import 'package:shared/shared.dart';
import 'package:test/test.dart';

/// 走一遍真实链路：编码成 JSON 字符串再解回来。
///
/// 只测 toJson/fromJson 会漏掉「值不是 JSON 基本类型」这类问题，
/// 那种错误只有真的过一次 jsonEncode 才会暴露。
SyncMessage roundTrip(SyncMessage msg) => SyncMessage.fromJson(
  jsonDecode(jsonEncode(msg.toJson())) as Map<String, Object?>,
);

Op sampleOp({int? seq, Object? value = 'x'}) => Op(
  seq: seq,
  opId: 'op-1',
  boardId: 'b1',
  entity: Entity.card,
  entityId: 'c1',
  field: CardF.title,
  value: value,
  deviceId: 'dev-1',
  wallTs: 1700000000000,
);

void main() {
  group('Op 编解码', () {
    test('往返保持所有字段', () {
      final op = sampleOp(seq: 42);
      final back = Op.fromJson(
        jsonDecode(jsonEncode(op.toJson())) as Map<String, Object?>,
      );

      expect(back.seq, 42);
      expect(back.opId, op.opId);
      expect(back.boardId, op.boardId);
      expect(back.entity, op.entity);
      expect(back.entityId, op.entityId);
      expect(back.field, op.field);
      expect(back.value, op.value);
      expect(back.deviceId, op.deviceId);
      expect(back.wallTs, op.wallTs);
    });

    test('未确认的 op 不带 seq，解回来仍是 null', () {
      final back = Op.fromJson(
        jsonDecode(jsonEncode(sampleOp().toJson())) as Map<String, Object?>,
      );
      expect(back.seq, isNull);
      expect(back.isSynced, isFalse);
    });

    test('各种值类型都能往返', () {
      for (final value in <Object?>[
        'text',
        42,
        12.5,
        true,
        false,
        null,
      ]) {
        final back = Op.fromJson(
          jsonDecode(jsonEncode(sampleOp(value: value).toJson()))
              as Map<String, Object?>,
        );
        expect(back.value, value, reason: '值 $value 往返后变了');
      }
    });

    test('value 为 null 表示置空，与「没有这条 op」是两回事', () {
      final json =
          jsonDecode(jsonEncode(sampleOp(value: null).toJson()))
              as Map<String, Object?>;
      expect(json.containsKey('value'), isTrue);
      expect(json['value'], isNull);
    });

    test('withSeq 只改 seq，其余原样', () {
      final op = sampleOp();
      final acked = op.withSeq(7);
      expect(acked.seq, 7);
      expect(acked.opId, op.opId);
      expect(acked.value, op.value);
    });
  });

  group('消息编解码', () {
    test('HELLO', () {
      final msg = roundTrip(
        const HelloMessage(
          deviceId: 'dev-1',
          deviceName: '我的 Mac',
          token: 'tok',
          pairCode: null,
          lastSeq: 99,
        ),
      );
      expect(msg, isA<HelloMessage>());
      final hello = msg as HelloMessage;
      expect(hello.deviceId, 'dev-1');
      expect(hello.deviceName, '我的 Mac');
      expect(hello.token, 'tok');
      expect(hello.pairCode, isNull);
      expect(hello.lastSeq, 99);
    });

    test('HELLO 首次配对带配对码、不带 token', () {
      final hello =
          roundTrip(
                const HelloMessage(
                  deviceId: 'dev-1',
                  deviceName: '手机',
                  token: null,
                  pairCode: 'A1B2C3',
                  lastSeq: 0,
                ),
              )
              as HelloMessage;
      expect(hello.token, isNull);
      expect(hello.pairCode, 'A1B2C3');
    });

    test('PUSH 带多条 op', () {
      final msg =
          roundTrip(PushMessage([sampleOp(), sampleOp(seq: 3)])) as PushMessage;
      expect(msg.ops.length, 2);
      expect(msg.ops.first.seq, isNull);
      expect(msg.ops.last.seq, 3);
    });

    test('PUSH 空批次', () {
      expect((roundTrip(const PushMessage([])) as PushMessage).ops, isEmpty);
    });

    test('SYNC 带服务端当前 seq', () {
      final msg =
          roundTrip(SyncOpsMessage(ops: [sampleOp(seq: 5)], serverSeq: 120))
              as SyncOpsMessage;
      expect(msg.ops.single.seq, 5);
      expect(msg.serverSeq, 120);
    });

    test('ACK 的 opId → seq 映射', () {
      final msg =
          roundTrip(const AckMessage({'a': 1, 'b': 2})) as AckMessage;
      expect(msg.seqByOpId, {'a': 1, 'b': 2});
    });

    test('BROADCAST', () {
      final msg =
          roundTrip(BroadcastMessage([sampleOp(seq: 8)])) as BroadcastMessage;
      expect(msg.ops.single.seq, 8);
    });

    test('EDITING 客户端发出时不带设备名', () {
      final msg =
          roundTrip(const EditingMessage(cardId: 'c1', active: true))
              as EditingMessage;
      expect(msg.cardId, 'c1');
      expect(msg.active, isTrue);
      expect(msg.deviceName, isNull);
    });

    test('EDITING 服务端转发时填上是谁', () {
      final msg =
          roundTrip(
                const EditingMessage(
                  cardId: 'c1',
                  active: false,
                  deviceName: '台式机',
                ),
              )
              as EditingMessage;
      expect(msg.active, isFalse);
      expect(msg.deviceName, '台式机');
    });

    test('SNAPSHOT_REQUIRED / PING / PONG', () {
      expect(
        roundTrip(const SnapshotRequiredMessage()),
        isA<SnapshotRequiredMessage>(),
      );
      expect(roundTrip(const PingMessage()), isA<PingMessage>());
      expect(roundTrip(const PongMessage()), isA<PongMessage>());
    });

    test('ERROR', () {
      final msg =
          roundTrip(const ErrorMessage(ErrorCode.badToken, '令牌无效'))
              as ErrorMessage;
      expect(msg.code, ErrorCode.badToken);
      expect(msg.message, '令牌无效');
    });
  });

  group('向前兼容', () {
    test('认不出的消息类型退化成 UnknownMessage，不抛异常', () {
      // 服务端随身携带，新旧版本混跑是必然会遇到的情况。旧版本收到
      // 新消息时应当安静忽略，而不是断开连接。
      final msg = SyncMessage.fromJson({'type': '未来才有的消息', 'x': 1});
      expect(msg, isA<UnknownMessage>());
      expect((msg as UnknownMessage).rawType, '未来才有的消息');
    });

    test('缺 type 字段也不抛', () {
      expect(SyncMessage.fromJson({}), isA<UnknownMessage>());
    });

    test('HELLO 缺可选字段时取默认值', () {
      final hello =
          SyncMessage.fromJson({'type': 'HELLO', 'device_id': 'd'})
              as HelloMessage;
      expect(hello.deviceName, '未命名设备');
      expect(hello.lastSeq, 0);
      expect(hello.token, isNull);
    });

    test('带 op 的消息缺 ops 字段时当空批次', () {
      expect((SyncMessage.fromJson({'type': 'PUSH'}) as PushMessage).ops, isEmpty);
      expect(
        (SyncMessage.fromJson({'type': 'SYNC'}) as SyncOpsMessage).ops,
        isEmpty,
      );
    });
  });
}
