import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanban/data/database.dart';
import 'package:kanban/data/repository.dart';
import 'package:shared/shared.dart';

/// 卡片搬家改的是 `board_id`——这个字段在此之前是「建行时抄一份就再也
/// 不动」的种子列，第一次变成可改的字段，所以整条路都要走一遍。
void main() {
  late AppDatabase db;
  late Repository repo;
  late String from;
  late String to;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = Repository(db);
    from = await repo.createBoard(name: '旧板');
    to = await repo.createBoard(name: '新板');
  });
  tearDown(() => db.close());

  Future<CardRow> card(String id) =>
      (db.select(db.cards)..where((c) => c.id.equals(id))).getSingle();

  Future<List<CardTagRow>> liveTags(String cardId) =>
      (db.select(db.cardTags)
            ..where((r) => r.cardId.equals(cardId) & r.deleted.equals(false)))
          .get();

  test('卡片换到新看板', () async {
    final id = await repo.createCard(boardId: from, x: 10, y: 20);
    await repo.moveCardToBoard(cardId: id, fromBoardId: from, toBoardId: to);

    expect((await card(id)).boardId, to);
  });

  test('标签全被清空', () async {
    final id = await repo.createCard(boardId: from, x: 0, y: 0);
    final a = await repo.createTag(boardId: from, name: '甲');
    final b = await repo.createTag(boardId: from, name: '乙');
    await repo.setCardTag(from, id, a, on: true);
    await repo.setCardTag(from, id, b, on: true);
    expect(await liveTags(id), hasLength(2));

    final cleared = await repo.moveCardToBoard(
      cardId: id,
      fromBoardId: from,
      toBoardId: to,
    );

    expect(cleared, 2, reason: '要如实报清掉了几个，界面得说给用户听');
    expect(await liveTags(id), isEmpty);
  });

  test('别的卡片的标签不受连累', () async {
    final moving = await repo.createCard(boardId: from, x: 0, y: 0);
    final staying = await repo.createCard(boardId: from, x: 0, y: 0);
    final tag = await repo.createTag(boardId: from, name: '甲');
    await repo.setCardTag(from, moving, tag, on: true);
    await repo.setCardTag(from, staying, tag, on: true);

    await repo.moveCardToBoard(cardId: moving, fromBoardId: from, toBoardId: to);

    expect(await liveTags(moving), isEmpty);
    expect(await liveTags(staying), hasLength(1));
  });

  test('落在新看板所有卡片的下面', () async {
    // 保留原坐标的话会压在别人身上，或者落在很远的空白处。
    await repo.createCard(boardId: to, x: 0, y: 500);
    await repo.createCard(boardId: to, x: 0, y: 900);
    final id = await repo.createCard(boardId: from, x: 777, y: 777);

    await repo.moveCardToBoard(cardId: id, fromBoardId: from, toBoardId: to);

    final moved = await card(id);
    expect(moved.y, 900 + 170);
    expect(moved.x, 40);
  });

  test('搬到空看板落在左上角，不是屏幕外', () async {
    final id = await repo.createCard(boardId: from, x: 999, y: 999);
    await repo.moveCardToBoard(cardId: id, fromBoardId: from, toBoardId: to);

    final moved = await card(id);
    expect(moved.x, 40);
    expect(moved.y, 40);
  });

  test('摆在新看板的最上层', () async {
    final under = await repo.createCard(boardId: to, x: 0, y: 0);
    final id = await repo.createCard(boardId: from, x: 0, y: 0);

    await repo.moveCardToBoard(cardId: id, fromBoardId: from, toBoardId: to);

    expect((await card(id)).z, greaterThan((await card(under)).z));
  });

  test('附件和评论跟着卡片走', () async {
    // 它们挂的是 cardId，不是 boardId，所以本来就该自动跟过去。
    // 这条测试钉住的是「将来别把它们改成按看板存」。
    final id = await repo.createCard(boardId: from, x: 0, y: 0);
    await repo.addAttachment(
      boardId: from,
      cardId: id,
      hash: 'h',
      filename: 'a.png',
      size: 1,
      mime: 'image/png',
      thumbHash: null,
    );
    await repo.addComment(from, id, '一条评论');

    await repo.moveCardToBoard(cardId: id, fromBoardId: from, toBoardId: to);

    final attachments = await repo.watchAttachments(id).first;
    final comments = await repo.watchComments(id).first;
    expect(attachments, hasLength(1));
    expect(comments, hasLength(1));
  });

  test('搬家是一条普通 op，改动记录里看得见', () async {
    final id = await repo.createCard(boardId: from, x: 0, y: 0);
    await repo.moveCardToBoard(cardId: id, fromBoardId: from, toBoardId: to);

    final changes = await repo.watchCardChanges(id).first;
    final move = changes.where((c) => c.field == CardF.boardId).toList();
    expect(move, hasLength(1));
    expect(move.single.value, to);
  });

  test('搬家 op 盖的是新看板的戳', () async {
    // op 上的 boardId 决定了一台还没见过这张卡的设备把它建到哪块板上，
    // 写旧板的话，那台设备会把卡片放回旧板再被后续 op 拉走。
    final id = await repo.createCard(boardId: from, x: 0, y: 0);
    await repo.moveCardToBoard(cardId: id, fromBoardId: from, toBoardId: to);

    final row = await (db.select(db.ops)
          ..where((o) => o.entityId.equals(id) & o.field.equals(CardF.boardId)))
        .getSingle();
    expect(row.boardId, to);
  });

  test('搬到自己所在的板：什么都不做', () async {
    final id = await repo.createCard(boardId: from, x: 123, y: 456);
    final tag = await repo.createTag(boardId: from, name: '甲');
    await repo.setCardTag(from, id, tag, on: true);

    final cleared = await repo.moveCardToBoard(
      cardId: id,
      fromBoardId: from,
      toBoardId: from,
    );

    expect(cleared, 0);
    expect(await liveTags(id), hasLength(1), reason: '没搬家就不该清标签');
    final row = await card(id);
    expect(row.x, 123, reason: '没搬家就不该挪位置');
    expect(row.y, 456);
  });

  test('远端搬家的 op 也能正确落地', () async {
    // 别的设备搬的家，同步过来走的是 applyOp 这条路，不是 repo 的方法。
    final id = await repo.createCard(boardId: from, x: 0, y: 0);

    await db.applyOp(Op(
      opId: 'remote-move',
      seq: 500,
      boardId: to,
      entity: Entity.card,
      entityId: id,
      field: CardF.boardId,
      value: to,
      deviceId: 'other',
      wallTs: 1,
      baseSeq: 0,
    ));

    expect((await card(id)).boardId, to);
  });

  test('先收到搬家 op、后收到建卡 op，卡片仍然落在新板', () async {
    // 同步是会乱序的。搬家 op 先到时，卡片这一行是被它自己建出来的，
    // 之后那些盖着旧板戳的 op 不能把 board_id 拽回去。
    const id = 'card-x';

    await db.applyOp(Op(
      opId: 'move-first',
      seq: 500,
      boardId: to,
      entity: Entity.card,
      entityId: id,
      field: CardF.boardId,
      value: to,
      deviceId: 'other',
      wallTs: 2,
      baseSeq: 0,
    ));
    await db.applyOp(Op(
      opId: 'title-later',
      seq: 100,
      boardId: from,
      entity: Entity.card,
      entityId: id,
      field: CardF.title,
      value: '标题',
      deviceId: 'other',
      wallTs: 1,
      baseSeq: 0,
    ));

    final row = await card(id);
    expect(row.title, '标题');
    expect(row.boardId, to, reason: '旧板的戳不该把搬过去的卡片拽回来');
  });
}
