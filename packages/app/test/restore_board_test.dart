import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanban/data/database.dart';
import 'package:kanban/data/repository.dart';
import 'package:shared/shared.dart';

/// 删除看板走的是墓碑：板上只多一条「已删除」，板里的东西一个都没动。
/// 这组测试钉住的就是这一点——没有它，「恢复」只是句空话。
void main() {
  late AppDatabase db;
  late Repository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = Repository(db);
  });
  tearDown(() => db.close());

  Future<List<String>> liveBoardNames() async => [
        for (final s in await repo.watchBoardSummaries().first) s.board.name,
      ];

  Future<List<String>> deletedBoardNames() async => [
        for (final s in await repo.watchDeletedBoards().first) s.board.name,
      ];

  test('删掉的板从列表里消失，出现在「删掉的看板」里', () async {
    final a = await repo.createBoard(name: 'A');
    await repo.createBoard(name: 'B');

    await repo.deleteBoard(a);

    expect(await liveBoardNames(), ['B']);
    expect(await deletedBoardNames(), ['A']);
  });

  test('捞回来之后回到列表，不再出现在删除列表里', () async {
    final a = await repo.createBoard(name: 'A');
    await repo.deleteBoard(a);
    await repo.restoreBoard(a);

    expect(await liveBoardNames(), ['A']);
    expect(await deletedBoardNames(), isEmpty);
  });

  test('板里的卡片、标签、评论、附件原样回来', () async {
    // 这是整个设计的立足点：删板时这些东西压根没被标记删除，
    // 所以「恢复」只需要改板上那一个字段。
    final boardId = await repo.createBoard(name: 'A');
    final tagId = await repo.createTag(boardId: boardId, name: '标签');
    final cardId = await repo.createCard(
      boardId: boardId,
      x: 1,
      y: 2,
      title: '一张卡',
    );
    await repo.setCardTag(boardId, cardId, tagId, on: true);
    await repo.addComment(boardId, cardId, '一条评论');
    await repo.addAttachment(
      boardId: boardId,
      cardId: cardId,
      hash: 'h',
      filename: 'a.png',
      size: 1,
      mime: 'image/png',
      thumbHash: null,
    );

    await repo.deleteBoard(boardId);
    await repo.restoreBoard(boardId);

    expect((await repo.watchCanvasCards(boardId).first).single.title, '一张卡');
    expect((await repo.watchTags(boardId).first).single.name, '标签');
    expect((await repo.watchComments(cardId).first).single.body, '一条评论');
    expect((await repo.watchAttachments(cardId).first), hasLength(1));
  });

  test('删板不碰板里任何一条记录的墓碑字段', () async {
    // 如果哪天有人「优化」成级联删除，恢复就会变成一件做不到的事。
    final boardId = await repo.createBoard(name: 'A');
    final cardId = await repo.createCard(boardId: boardId, x: 0, y: 0);
    final tagId = await repo.createTag(boardId: boardId, name: 'T');

    await repo.deleteBoard(boardId);

    final card = await (db.select(db.cards)
          ..where((c) => c.id.equals(cardId)))
        .getSingle();
    final tag =
        await (db.select(db.tags)..where((t) => t.id.equals(tagId))).getSingle();
    expect(card.deleted, isFalse, reason: '卡片不该被连带标记删除');
    expect(tag.deleted, isFalse, reason: '标签不该被连带标记删除');
  });

  test('删别的板不影响这块板', () async {
    final a = await repo.createBoard(name: 'A');
    final b = await repo.createBoard(name: 'B');
    final cardInB = await repo.createCard(boardId: b, x: 0, y: 0, title: 'B 的卡');

    await repo.deleteBoard(a);

    expect(await liveBoardNames(), ['B']);
    expect((await repo.watchCanvasCards(b).first).single.id, cardInB);
  });

  test('删除是一条会同步出去的普通改动', () async {
    // 不是本机操作——离线删掉的板，一联网就在所有设备上消失。
    final boardId = await repo.createBoard(name: 'A');
    await repo.deleteBoard(boardId);

    final rows = await (db.select(db.ops)
          ..where((o) =>
              o.entityId.equals(boardId) & o.field.equals(BoardF.deleted)))
        .get();
    expect(rows, hasLength(1));
    expect(rows.single.seq, isNull, reason: '还没同步出去，应该在待发队列里');
  });

  test('远端的删除和本地的恢复，按序号定胜负', () async {
    // 两台设备都动 `deleted` 这同一个字段，才谈得上谁赢。
    final boardId = await repo.createBoard(name: 'A');
    await db.ackOps({
      for (final r in await db.pendingOps()) r.opId: r.localSeq + 100,
    });

    // 远端把它删了，序号 500。
    await db.applyOp(Op(
      opId: 'remote-delete',
      seq: 500,
      boardId: boardId,
      entity: Entity.board,
      entityId: boardId,
      field: BoardF.deleted,
      value: true,
      deviceId: 'other',
      wallTs: 1,
      baseSeq: 0,
    ));
    expect(await liveBoardNames(), isEmpty);

    // 本地捞回来——本地未确认的改动在本机优先，立刻生效。
    await repo.restoreBoard(boardId);
    expect(await liveBoardNames(), ['A']);

    // 远端又删，而且序号更大：同步过来之后以它为准。
    await db.ackOps({
      for (final r in await db.pendingOps()) r.opId: 600,
    });
    await db.applyOp(Op(
      opId: 'remote-delete-2',
      seq: 700,
      boardId: boardId,
      entity: Entity.board,
      entityId: boardId,
      field: BoardF.deleted,
      value: true,
      deviceId: 'other',
      wallTs: 2,
      baseSeq: 0,
    ));
    expect(await liveBoardNames(), isEmpty, reason: '序号大的那条说了算');
  });

  test('删除和改名是两个字段，各自生效', () async {
    // 反直觉但重要：不存在「谁赢」。最终是一块改了名字的、已删除的板，
    // 那次改名并没有丢。
    final boardId = await repo.createBoard(name: '原名');
    await repo.deleteBoard(boardId);
    await repo.renameBoard(boardId, '新名');

    expect(await liveBoardNames(), isEmpty);
    expect(await deletedBoardNames(), ['新名']);

    // 所以捞回来之后，看到的是新名字。
    await repo.restoreBoard(boardId);
    expect(await liveBoardNames(), ['新名']);
  });
}
