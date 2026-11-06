import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanban/data/database.dart';
import 'package:kanban/data/repository.dart';
import 'package:shared/shared.dart';

/// 看板方块的背景图。
///
/// 图本身走附件那套通道（内容寻址、HTTP 传输），但它**不是**一条附件
/// 记录——它挂在看板上，是六个字段。这组测试钉的是那六个字段的写入规则。
void main() {
  late AppDatabase db;
  late Repository repo;
  late String boardId;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = Repository(db);
    boardId = await repo.createBoard(name: 'B');
  });
  tearDown(() => db.close());

  Future<BoardRow> board() => repo.watchBoard(boardId).first.then((b) => b!);

  test('新建的看板没有背景图', () async {
    final b = await board();
    expect(b.coverHash, isNull);
    expect(b.coverOpacity, kCoverOpacityDefault);
    expect(b.coverScale, 1);
  });

  test('贴一张图，六个字段都落库', () async {
    await repo.setBoardCover(
      boardId,
      hash: 'h',
      thumbHash: 't',
      opacity: 0.4,
      focalX: -0.5,
      focalY: 0.25,
      scale: 1.8,
    );

    final b = await board();
    expect(b.coverHash, 'h');
    expect(b.coverThumbHash, 't');
    expect(b.coverOpacity, 0.4);
    expect(b.coverFocalX, -0.5);
    expect(b.coverFocalY, 0.25);
    expect(b.coverScale, 1.8);
  });

  test('去掉图时，位置参数一并恢复默认', () async {
    // 不恢复的话，下次贴新图会继承上一张调好的焦点和倍数——新图在那个
    // 位置基本是乱的，用户会以为是功能坏了。
    await repo.setBoardCover(
      boardId,
      hash: 'h',
      thumbHash: 't',
      opacity: 0.6,
      focalX: 1,
      focalY: -1,
      scale: 3,
    );
    await repo.setBoardCover(boardId, hash: null);

    final b = await board();
    expect(b.coverHash, isNull);
    expect(b.coverThumbHash, isNull);
    expect(b.coverOpacity, kCoverOpacityDefault);
    expect(b.coverFocalX, 0);
    expect(b.coverFocalY, 0);
    expect(b.coverScale, 1);
  });

  test('越界的数值在写入前就夹紧', () async {
    // 这些值会同步到别的设备。一个越界的倍数能把那台机器上的方块
    // 撑成一片糊，而那台机器没有任何办法知道这个数不对。
    await repo.setBoardCover(
      boardId,
      hash: 'h',
      opacity: 9,
      focalX: -4,
      focalY: 4,
      scale: 100,
    );

    final b = await board();
    expect(b.coverOpacity, kCoverOpacityMax);
    expect(b.coverFocalX, -1);
    expect(b.coverFocalY, 1);
    expect(b.coverScale, kCoverScaleMax);
  });

  test('封面图不冒充卡片附件', () async {
    // 它挂在看板上，不属于任何卡片，所以附件区、封面、回形针角标
    // 一概不该出现它。
    final cardId = await repo.createCard(boardId: boardId, x: 0, y: 0);
    await repo.setBoardCover(boardId, hash: 'h', thumbHash: 't');

    expect(await repo.watchAttachments(cardId).first, isEmpty);
    expect(await repo.watchCardCovers(boardId).first, isEmpty);
    expect(await repo.watchAttachmentCounts(boardId).first, isEmpty);
  });

  test('别的设备改封面，同步过来照样生效', () async {
    // 远端来的 op 走 applyOp，不经过 repo 的方法。字段没登记在物化映射
    // 里的话，这些 op 会被当成未知字段跳过，图在这台机器上永远不出现。
    final now = DateTime.now().millisecondsSinceEpoch;
    var seq = 0;

    Future<void> apply(String field, Object? value) => db.applyOp(Op(
      opId: 'remote-$field',
      seq: ++seq,
      boardId: boardId,
      entity: Entity.board,
      entityId: boardId,
      field: field,
      value: value,
      deviceId: 'other',
      wallTs: now,
      baseSeq: 0,
    ));

    await apply(BoardF.coverHash, 'remote-hash');
    await apply(BoardF.coverThumbHash, 'remote-thumb');
    await apply(BoardF.coverOpacity, 0.45);
    await apply(BoardF.coverFocalX, 0.75);
    await apply(BoardF.coverFocalY, -0.25);
    await apply(BoardF.coverScale, 2.5);

    final b = await board();
    expect(b.coverHash, 'remote-hash');
    expect(b.coverThumbHash, 'remote-thumb');
    expect(b.coverOpacity, 0.45);
    expect(b.coverFocalX, 0.75);
    expect(b.coverFocalY, -0.25);
    expect(b.coverScale, 2.5);
  });

  test('删了看板又捞回来，封面图还在', () async {
    await repo.setBoardCover(boardId, hash: 'h', thumbHash: 't', scale: 2);
    await repo.deleteBoard(boardId);
    await repo.restoreBoard(boardId);

    final b = await board();
    expect(b.coverHash, 'h');
    expect(b.coverScale, 2);
  });
}
