import 'package:server/src/store.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

var _counter = 0;

Op op({String? id, String field = CardF.title, Object? value = 'x'}) => Op(
  opId: id ?? 'op-${_counter++}',
  boardId: 'b1',
  entity: Entity.card,
  entityId: 'c1',
  field: field,
  value: value,
  deviceId: 'dev-1',
  wallTs: 0,
);

void main() {
  late Store store;

  setUp(() {
    store = Store.memory();
    _counter = 0;
  });
  tearDown(() => store.close());

  group('序号分配', () {
    test('空库时最大 seq 为 0', () {
      expect(store.maxSeq, 0);
    });

    test('按到达顺序严格递增', () {
      final a = store.append([op(id: 'a')]);
      final b = store.append([op(id: 'b')]);
      final c = store.append([op(id: 'c')]);

      expect(a['a']! < b['b']!, isTrue);
      expect(b['b']! < c['c']!, isTrue);
      expect(store.maxSeq, c['c']);
    });

    test('一批里的多条也各自拿到递增的号', () {
      final got = store.append([op(id: 'a'), op(id: 'b'), op(id: 'c')]);
      final seqs = ['a', 'b', 'c'].map((k) => got[k]!).toList();
      expect(seqs, [seqs[0], seqs[0] + 1, seqs[0] + 2]);
    });

    test('空批次不出错', () {
      expect(store.append([]), isEmpty);
      expect(store.maxSeq, 0);
    });
  });

  group('按 opId 去重', () {
    test('重复提交同一条 op 不会分配新号', () {
      // 客户端重连补发时会把同一批 op 再发一次。若每次都分配新号，
      // 同一次修改会在 log 里出现两遍。
      final first = store.append([op(id: 'a')]);
      final again = store.append([op(id: 'a')]);

      expect(again['a'], first['a'], reason: '应当把原来的 seq 告诉它');
      expect(store.opCount, 1);
    });

    test('重复的那条也要出现在 ACK 里', () {
      store.append([op(id: 'a')]);
      final got = store.append([op(id: 'a'), op(id: 'b')]);

      expect(got.containsKey('a'), isTrue, reason: '否则客户端会一直以为它没被确认');
      expect(got.containsKey('b'), isTrue);
    });

    test('重复提交不会改写原来的值', () {
      store.append([op(id: 'a', value: '原值')]);
      store.append([op(id: 'a', value: '新值')]);

      expect(store.opsSince(0).single.value, '原值');
    });
  });

  group('增量查询', () {
    test('只返回 seq 大于给定值的', () {
      final got = store.append([op(id: 'a'), op(id: 'b'), op(id: 'c')]);

      final after = store.opsSince(got['a']!);
      expect(after.map((o) => o.opId), ['b', 'c']);
    });

    test('从 0 开始返回全部', () {
      store.append([op(id: 'a'), op(id: 'b')]);
      expect(store.opsSince(0).length, 2);
    });

    test('已经最新时返回空', () {
      store.append([op(id: 'a')]);
      expect(store.opsSince(store.maxSeq), isEmpty);
    });

    test('返回的 op 一定带 seq', () {
      store.append([op(id: 'a')]);
      expect(store.opsSince(0).single.seq, isNotNull);
      expect(store.opsSince(0).single.isSynced, isTrue);
    });

    test('值的类型往返正确', () {
      store.append([
        op(id: 'a', field: CardF.x, value: 12.5),
        op(id: 'b', field: CardF.collapsed, value: true),
        op(id: 'c', field: CardF.color, value: null),
      ]);
      final ops = store.opsSince(0);
      expect(ops[0].value, 12.5);
      expect(ops[1].value, true);
      expect(ops[2].value, isNull);
    });
  });

  group('按 ID 取 op（广播用）', () {
    test('返回带 seq 的完整 op', () {
      store.append([op(id: 'a'), op(id: 'b'), op(id: 'c')]);
      final ops = store.opsByIds(['a', 'c']);

      expect(ops.map((o) => o.opId), ['a', 'c']);
      expect(ops.every((o) => o.seq != null), isTrue);
    });

    test('空输入返回空', () {
      expect(store.opsByIds([]), isEmpty);
    });
  });

  group('压缩', () {
    test('每个字段只留最新的一条', () {
      store.append([
        op(id: 'a', field: CardF.title, value: '旧'),
        op(id: 'b', field: CardF.title, value: '新'),
        op(id: 'c', field: CardF.body, value: '正文'),
      ]);

      final removed = store.compact();

      expect(removed, 1);
      expect(store.opCount, 2);
      final titles = store.opsSince(0).where((o) => o.field == CardF.title);
      expect(titles.single.value, '新');
    });

    test('压缩后记下压缩点', () {
      store.append([op(id: 'a'), op(id: 'b')]);
      expect(store.compactionSeq, 0);

      store.compact();

      expect(store.compactionSeq, store.maxSeq);
      expect(store.compactionSeq, greaterThan(0));
    });

    test('空库压缩不出错', () {
      expect(store.compact(), 0);
    });
  });

  group('设备配对', () {
    test('配对签发令牌', () {
      final device = store.pair('dev-1', '我的 Mac');

      expect(device.id, 'dev-1');
      expect(device.name, '我的 Mac');
      expect(device.token, isNotEmpty);
      expect(store.devices.length, 1);
    });

    test('两台设备拿到不同的令牌', () {
      final a = store.pair('dev-1', 'A');
      final b = store.pair('dev-2', 'B');
      expect(a.token, isNot(b.token));
    });

    test('重新配对同一设备会换新令牌', () {
      final first = store.pair('dev-1', 'A');
      final again = store.pair('dev-1', 'A 改名了');

      expect(again.token, isNot(first.token));
      expect(again.name, 'A 改名了');
      expect(store.devices.length, 1, reason: '不该变成两台');
    });

    test('踢掉设备', () {
      store.pair('dev-1', 'A');
      store.unpair('dev-1');

      expect(store.devices, isEmpty);
      expect(store.deviceById('dev-1'), isNull);
    });

    test('未配对的设备查不到', () {
      expect(store.deviceById('查无此人'), isNull);
    });
  });

  group('配对码', () {
    test('6 位', () {
      expect(generatePairCode().length, 6);
    });

    test('不含容易看错的字符', () {
      // 用户要从屏幕上抄到另一台设备，认错一个就得重来。
      for (var i = 0; i < 200; i++) {
        final code = generatePairCode();
        expect(
          RegExp(r'[01OI]').hasMatch(code),
          isFalse,
          reason: '$code 里有容易看错的字符',
        );
      }
    });

    test('每次都不一样', () {
      final codes = {for (var i = 0; i < 100; i++) generatePairCode()};
      expect(codes.length, greaterThan(90), reason: '随机性太差');
    });
  });
}
