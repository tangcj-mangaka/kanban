import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanban/data/database.dart';
import 'package:shared/shared.dart';

void main() {
  late AppDatabase db;
  var opCounter = 0;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    opCounter = 0;
  });
  tearDown(() => db.close());

  /// 造一条 op。[seq] 为 null 表示这是一条本地未同步的 op。
  Op mk(
    String entity,
    String entityId,
    String field,
    Object? value, {
    int? seq,
    String board = 'b1',
  }) => Op(
    opId: 'op${opCounter++}',
    seq: seq,
    boardId: board,
    entity: entity,
    entityId: entityId,
    field: field,
    value: value,
    deviceId: 'test',
    wallTs: 0,
  );

  Future<CardRow?> card(String id) =>
      (db.select(db.cards)..where((c) => c.id.equals(id))).getSingleOrNull();

  group('字段级 LWW', () {
    test('改不同字段互不覆盖', () async {
      // 这正是不用「整卡覆盖」的理由：手机改标题、电脑同时改正文，
      // 两个改动都必须留下。
      await db.applyOp(mk(Entity.card, 'c1', CardF.title, '标题', seq: 1));
      await db.applyOp(mk(Entity.card, 'c1', CardF.body, '正文', seq: 2));

      final c = await card('c1');
      expect(c!.title, '标题');
      expect(c.body, '正文');
    });

    test('同字段后写覆盖先写', () async {
      await db.applyOp(mk(Entity.card, 'c1', CardF.title, '旧', seq: 1));
      await db.applyOp(mk(Entity.card, 'c1', CardF.title, '新', seq: 2));

      expect((await card('c1'))!.title, '新');
    });

    test('乱序到达时，seq 小的不会把新值盖回去', () async {
      // 网络乱序或补发时，旧 op 可能后到。它必须被丢弃，
      // 而不是把已经生效的新值覆盖成旧值。
      await db.applyOp(mk(Entity.card, 'c1', CardF.title, '新', seq: 9));
      final applied =
          await db.applyOp(mk(Entity.card, 'c1', CardF.title, '旧', seq: 3));

      expect(applied, isFalse);
      expect((await card('c1'))!.title, '新');
    });

    test('同一条 op 重复送达只生效一次', () async {
      final op = mk(Entity.card, 'c1', CardF.title, 'X', seq: 1);
      expect(await db.applyOp(op), isTrue);
      expect(await db.applyOp(op), isFalse);

      final rows = await db.select(db.ops).get();
      expect(rows.length, 1);
    });
  });

  group('本地优先的定序', () {
    test('未确认的本地 op 压过已确认的远程 op', () async {
      // 服务端还没表态之前，本机刚做的修改就是本地最新认知，
      // 不能被一条更早的已确认 op 压住。
      await db.applyOp(mk(Entity.card, 'c1', CardF.title, '远程', seq: 5));
      await db.emit(
        boardId: 'b1',
        entity: Entity.card,
        entityId: 'c1',
        field: CardF.title,
        value: '本地',
      );

      expect((await card('c1'))!.title, '本地');
    });

    test('未同步的 op 进待发队列，按本地顺序排列', () async {
      await db.applyOp(mk(Entity.card, 'c1', CardF.title, '已同步', seq: 1));
      await db.emit(
        boardId: 'b1',
        entity: Entity.card,
        entityId: 'c1',
        field: CardF.body,
        value: '待发一',
      );
      await db.emit(
        boardId: 'b1',
        entity: Entity.card,
        entityId: 'c1',
        field: CardF.color,
        value: 'teal',
      );

      final pending = await db.pendingOps();
      expect(pending.map((o) => o.field), [CardF.body, CardF.color]);
    });
  });

  group('集合字段拆成独立记录', () {
    test('并发加两个不同标签，一个都不丢', () async {
      // 若把整个标签集合当成卡片的一个字段做 LWW，这里会丢掉一个。
      final a = cardTagId('c1', 't1');
      final b = cardTagId('c1', 't2');

      await db.applyOp(mk(Entity.cardTag, a, CardTagF.deleted, false, seq: 1));
      await db.applyOp(mk(Entity.cardTag, b, CardTagF.deleted, false, seq: 2));

      final rows = await (db.select(
        db.cardTags,
      )..where((r) => r.deleted.equals(false))).get();
      expect(rows.map((r) => r.tagId).toSet(), {'t1', 't2'});
    });

    test('关系 ID 确定性，两台设备打同一标签只产生一条记录', () async {
      final id = cardTagId('c1', 't1');
      expect(id, 'c1:t1');

      await db.applyOp(mk(Entity.cardTag, id, CardTagF.deleted, false, seq: 1));
      await db.applyOp(mk(Entity.cardTag, id, CardTagF.deleted, false, seq: 2));

      final rows = await db.select(db.cardTags).get();
      expect(rows.length, 1);
      expect(rows.single.cardId, 'c1');
      expect(rows.single.tagId, 't1');
    });

    test('移除标签走墓碑，记录还在但已标删', () async {
      final id = cardTagId('c1', 't1');
      await db.applyOp(mk(Entity.cardTag, id, CardTagF.deleted, false, seq: 1));
      await db.applyOp(mk(Entity.cardTag, id, CardTagF.deleted, true, seq: 2));

      final row = await db.select(db.cardTags).getSingle();
      expect(row.deleted, isTrue);
    });
  });

  group('墓碑删除', () {
    test('删除之后再编辑别的字段，不会让卡片复活', () async {
      // deleted 和 title 是两个独立字段，后到的编辑不参与 deleted 的竞争。
      // 想恢复必须显式发一条 deleted=false。
      await db.applyOp(mk(Entity.card, 'c1', CardF.deleted, true, seq: 1));
      await db.applyOp(mk(Entity.card, 'c1', CardF.title, '还在改', seq: 2));

      final c = await card('c1');
      expect(c!.deleted, isTrue);
      expect(c.title, '还在改');
    });

    test('显式恢复', () async {
      await db.applyOp(mk(Entity.card, 'c1', CardF.deleted, true, seq: 1));
      await db.applyOp(mk(Entity.card, 'c1', CardF.deleted, false, seq: 2));

      expect((await card('c1'))!.deleted, isFalse);
    });
  });

  group('值的类型', () {
    test('浮点、布尔、null 都能正确往返', () async {
      await db.applyOp(mk(Entity.card, 'c1', CardF.x, 12.5, seq: 1));
      // JSON 里整数和浮点无法区分，real 列必须显式转 double。
      await db.applyOp(mk(Entity.card, 'c1', CardF.y, 0, seq: 2));
      await db.applyOp(mk(Entity.card, 'c1', CardF.collapsed, false, seq: 3));
      await db.applyOp(mk(Entity.card, 'c1', CardF.color, 'teal', seq: 4));
      await db.applyOp(mk(Entity.card, 'c1', CardF.color, null, seq: 5));

      final c = await card('c1');
      expect(c!.x, 12.5);
      expect(c.y, 0.0);
      expect(c.collapsed, isFalse);
      expect(c.color, isNull);
    });

    test('首条 op 就能把行建出来，其余列取默认值', () async {
      await db.applyOp(mk(Entity.card, 'c1', CardF.title, '只发了标题', seq: 1));

      final c = await card('c1');
      expect(c!.boardId, 'b1');
      expect(c.width, 260);
      expect(c.collapsed, isTrue);
      expect(c.deleted, isFalse);
    });
  });

  group('小数序', () {
    test('往中间插只改一条记录的一个字段', () {
      expect(fractionalIndex(before: 1, after: 2), 1.5);
      expect(fractionalIndex(before: null, after: 1), 0);
      expect(fractionalIndex(before: 1, after: null), 2);
      expect(fractionalIndex(), 0);
    });

    test('反复往同一条缝里插，最终会触到需要重排的阈值', () {
      var lo = 0.0;
      const hi = 1.0;
      var steps = 0;
      while (!needsRebalance(lo, hi) && steps < 200) {
        lo = fractionalIndex(before: lo, after: hi);
        steps++;
      }
      expect(needsRebalance(lo, hi), isTrue);
      expect(steps, lessThan(200), reason: '应当在有限步内触发重排');
    });
  });
}
