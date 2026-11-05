import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanban/data/database.dart';
import 'package:kanban/data/repository.dart';
import 'package:shared/shared.dart';

/// 评论里的图走的是和卡片附件同一套机制（同步、按内容去重、超期回收
/// 全都现成），靠 `commentId` 区分归属。这组测试钉的就是那条分界线。
void main() {
  late AppDatabase db;
  late Repository repo;
  late String boardId;
  late String cardId;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = Repository(db);
    boardId = await repo.createBoard(name: 'B');
    cardId = await repo.createCard(boardId: boardId, x: 0, y: 0);
  });
  tearDown(() => db.close());

  ImportedFile image(String hash) => ImportedFile(
    hash: hash,
    filename: '$hash.png',
    size: 100,
    mime: 'image/png',
    thumbHash: '$hash-thumb',
  );

  test('评论带的图不进卡片的附件区', () async {
    // 混进来的话，每发一条带图评论附件区就多一个条目，很快就乱；
    // 而且封面取的是「第一张图片附件」，评论里的图不该抢封面。
    await repo.addComment(boardId, cardId, '看这个', images: [image('a')]);
    expect(await repo.watchAttachments(cardId).first, isEmpty);
  });

  test('卡片自己的附件照常出现在附件区', () async {
    await repo.addAttachment(
      boardId: boardId,
      cardId: cardId,
      hash: 'card-file',
      filename: 'a.png',
      size: 1,
      mime: 'image/png',
      thumbHash: null,
    );
    await repo.addComment(boardId, cardId, '评论', images: [image('a')]);

    final onCard = await repo.watchAttachments(cardId).first;
    expect(onCard, hasLength(1));
    expect(onCard.single.hash, 'card-file');
  });

  test('评论的图按评论归组，取得回来', () async {
    final first = await repo.addComment(
      boardId,
      cardId,
      '两张',
      images: [image('a'), image('b')],
    );
    final second = await repo.addComment(
      boardId,
      cardId,
      '一张',
      images: [image('c')],
    );
    await repo.addComment(boardId, cardId, '没图');

    final grouped = await repo.watchCommentAttachments(cardId).first;
    expect(grouped[first]!.map((a) => a.hash), ['a', 'b']);
    expect(grouped[second]!.map((a) => a.hash), ['c']);
    expect(grouped.keys, hasLength(2), reason: '没图的评论不该出现在这里');
  });

  test('只发图、不写字也算一条评论', () async {
    // 截个图扔进来本身就是一次发言。
    final id = await repo.addComment(boardId, cardId, '', images: [image('a')]);

    final comments = await repo.watchComments(cardId).first;
    expect(comments.single.id, id);
    expect(comments.single.body, isEmpty);
    expect(
      (await repo.watchCommentAttachments(cardId).first)[id],
      hasLength(1),
    );
  });

  test('删评论时，它带的图一起删掉', () async {
    final id = await repo.addComment(
      boardId,
      cardId,
      '带图的',
      images: [image('a'), image('b')],
    );

    await repo.deleteComment(boardId, id);

    expect(await repo.watchComments(cardId).first, isEmpty);
    expect(await repo.watchCommentAttachments(cardId).first, isEmpty);
  });

  test('删评论不碰卡片自己的附件，也不碰别条评论的图', () async {
    await repo.addAttachment(
      boardId: boardId,
      cardId: cardId,
      hash: 'card-file',
      filename: 'a.png',
      size: 1,
      mime: 'image/png',
      thumbHash: null,
    );
    final doomed = await repo.addComment(
      boardId,
      cardId,
      '要删的',
      images: [image('a')],
    );
    final kept = await repo.addComment(
      boardId,
      cardId,
      '留着的',
      images: [image('b')],
    );

    await repo.deleteComment(boardId, doomed);

    expect(await repo.watchAttachments(cardId).first, hasLength(1));
    final grouped = await repo.watchCommentAttachments(cardId).first;
    expect(grouped.keys, [kept]);
    expect(grouped[kept]!.single.hash, 'b');
  });

  test('评论和它的图是一个事务，时间戳也一致', () async {
    // 评论只增不改，图只能在发表那一刻带上。拆成两步的话，中间失败就会
    // 留下一条没有图的评论，而评论又改不了。
    final id = await repo.addComment(
      boardId,
      cardId,
      '同时落库',
      images: [image('a')],
    );

    final comment = (await repo.watchComments(cardId).first).single;
    final attachment =
        (await repo.watchCommentAttachments(cardId).first)[id]!.single;
    expect(attachment.createdAt, comment.createdAt);
    expect(attachment.cardId, cardId, reason: '仍然要挂在卡片下，回收才找得到');
  });

  test('远端同步过来的评论图，也能正确归组', () async {
    // 别的设备发的带图评论走的是 applyOp 这条路，不是 repo 的方法。
    const commentId = 'remote-comment';
    const attachmentId = 'remote-attachment';
    final now = DateTime.now().millisecondsSinceEpoch;

    Future<void> apply(
      String entity,
      String entityId,
      String field,
      Object? value,
      int seq,
    ) => db.applyOp(Op(
      opId: '$entityId-$field',
      seq: seq,
      boardId: boardId,
      entity: entity,
      entityId: entityId,
      field: field,
      value: value,
      deviceId: 'other',
      wallTs: now,
      baseSeq: 0,
    ));

    await apply(Entity.comment, commentId, CommentF.cardId, cardId, 1);
    await apply(Entity.comment, commentId, CommentF.body, '远端发的', 2);
    await apply(Entity.comment, commentId, CommentF.createdAt, now, 3);
    await apply(Entity.attachment, attachmentId, AttachmentF.cardId, cardId, 4);
    await apply(
      Entity.attachment,
      attachmentId,
      AttachmentF.commentId,
      commentId,
      5,
    );
    await apply(Entity.attachment, attachmentId, AttachmentF.hash, 'h', 6);

    final grouped = await repo.watchCommentAttachments(cardId).first;
    expect(grouped[commentId], hasLength(1));
    expect(await repo.watchAttachments(cardId).first, isEmpty);
  });
}
