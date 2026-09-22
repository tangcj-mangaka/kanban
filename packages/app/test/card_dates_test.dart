import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanban/data/database.dart';
import 'package:kanban/data/repository.dart';
import 'package:shared/shared.dart';

/// 截止时间走的是和别的字段一样的 op log 那条路，但它是**可空的整数**
/// ——这个组合之前没有先例（颜色可空但是字符串，坐标是数但不可空）。
/// 「置空」和「没改过」在 op log 里是两回事，不测一遍不放心。
void main() {
  late AppDatabase db;
  late Repository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = Repository(db);
  });
  tearDown(() => db.close());

  Future<CardRow> card(String id) =>
      (db.select(db.cards)..where((c) => c.id.equals(id))).getSingle();

  test('新建的卡片没有排期', () async {
    final boardId = await repo.createBoard(name: 'B');
    final id = await repo.createCard(boardId: boardId, x: 0, y: 0);

    final row = await card(id);
    expect(row.due, isNull);
    expect(row.start, isNull);
  });

  test('设了截止时间能读回来，毫秒不丢', () async {
    final boardId = await repo.createBoard(name: 'B');
    final id = await repo.createCard(boardId: boardId, x: 0, y: 0);
    final at = DateTime(2026, 9, 25, 23, 59, 30);

    await repo.setCardDate(boardId, id, CardF.due, at);

    expect((await card(id)).due, at.millisecondsSinceEpoch);
  });

  test('清除截止时间写的是 null，不是 0', () async {
    // 0 是 1970 年，会被当成「超时 56 年」画成一根红条。
    final boardId = await repo.createBoard(name: 'B');
    final id = await repo.createCard(boardId: boardId, x: 0, y: 0);

    await repo.setCardDate(boardId, id, CardF.due, DateTime(2026, 9, 25));
    await repo.setCardDate(boardId, id, CardF.due, null);

    expect((await card(id)).due, isNull);
  });

  test('开始和截止是两个独立字段，改一个不动另一个', () async {
    // 合成一个「区间」对象的话，一端改开始、另一端同时改截止，
    // 后写的那次会把对方整个盖掉。
    final boardId = await repo.createBoard(name: 'B');
    final id = await repo.createCard(boardId: boardId, x: 0, y: 0);

    await repo.setCardDate(boardId, id, CardF.start, DateTime(2026, 9, 20));
    await repo.setCardDate(boardId, id, CardF.due, DateTime(2026, 9, 25));
    await repo.setCardDate(boardId, id, CardF.start, DateTime(2026, 9, 21));

    final row = await card(id);
    expect(row.start, DateTime(2026, 9, 21).millisecondsSinceEpoch);
    expect(row.due, DateTime(2026, 9, 25).millisecondsSinceEpoch);
  });

  test('改排期算内容改动，会让卡片在「最近修改」里往上跳', () async {
    final boardId = await repo.createBoard(name: 'B');
    final id = await repo.createCard(boardId: boardId, x: 0, y: 0);
    final before = (await card(id)).updatedAt;

    await Future<void>.delayed(const Duration(milliseconds: 5));
    await repo.setCardDate(boardId, id, CardF.due, DateTime(2026, 9, 25));

    expect((await card(id)).updatedAt, greaterThan(before));
  });

  test('乱序到达的 op 也能得到正确结果', () async {
    // 同步是会乱序的：后发的 op 可能先到。靠 seq 定序，不靠到达顺序。
    final boardId = await repo.createBoard(name: 'B');
    final id = await repo.createCard(boardId: boardId, x: 0, y: 0);

    final later = DateTime(2026, 10, 1).millisecondsSinceEpoch;
    final earlier = DateTime(2026, 9, 1).millisecondsSinceEpoch;

    await db.applyOp(Op(
      opId: 'op-late',
      seq: 200,
      boardId: boardId,
      entity: Entity.card,
      entityId: id,
      field: CardF.due,
      value: later,
      deviceId: 'other',
      wallTs: 1,
      baseSeq: 0,
    ));
    await db.applyOp(Op(
      opId: 'op-early',
      seq: 100,
      boardId: boardId,
      entity: Entity.card,
      entityId: id,
      field: CardF.due,
      value: earlier,
      deviceId: 'other',
      wallTs: 2,
      baseSeq: 0,
    ));

    expect(
      (await card(id)).due,
      later,
      reason: 'seq 大的那条说了算，和到达顺序无关',
    );
  });

  test('watchDueCards 只给排过期、没归档、没删的卡片', () async {
    final boardId = await repo.createBoard(name: 'B');
    final due = await repo.createCard(boardId: boardId, x: 0, y: 0);
    final plain = await repo.createCard(boardId: boardId, x: 0, y: 0);
    final archived = await repo.createCard(boardId: boardId, x: 0, y: 0);
    final deleted = await repo.createCard(boardId: boardId, x: 0, y: 0);

    final at = DateTime(2026, 9, 25, 23, 59);
    for (final id in [due, archived, deleted]) {
      await repo.setCardDate(boardId, id, CardF.due, at);
    }
    await repo.archiveCard(boardId, archived);
    await repo.deleteCard(boardId, deleted);

    final rows = await repo.watchDueCards().first;
    expect(rows.map((r) => r.cardId), [due]);
    expect(rows.single.due, at.millisecondsSinceEpoch);
    expect(rows.single.boardId, boardId);
    expect(plain, isNotNull);
  });
}
