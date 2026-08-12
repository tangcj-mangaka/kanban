import 'dart:math';

import 'package:drift/drift.dart';
import 'package:meta/meta.dart';
import 'package:shared/shared.dart';
import 'package:uuid/uuid.dart';

import 'database.dart';

const _uuid = Uuid();
final _random = Random();

/// 看板列表页要显示的一行。
@immutable
class BoardSummary {
  final BoardRow board;
  final int cardCount;

  /// 板内卡片最近一次修改的时间，没有卡片时为 null。
  final int? lastUpdated;

  const BoardSummary({
    required this.board,
    required this.cardCount,
    required this.lastUpdated,
  });
}

/// 领域操作层。
///
/// UI 只跟这一层打交道，不直接碰 op。每个方法负责把一次用户动作翻译成
/// 一批 op，并保证它们在同一个事务里落地。
class Repository {
  final AppDatabase db;

  Repository(this.db);

  // -------------------------------------------------------------------------
  // 看板
  // -------------------------------------------------------------------------

  Stream<List<BoardSummary>> watchBoardSummaries() {
    // 卡片数只算画布上的：归档进干草仓库的和已删除的都不计入。
    final cardCount = db.cards.id.count(
      filter: db.cards.deleted.equals(false) & db.cards.archived.equals(false),
    );
    final lastUpdated = db.cards.updatedAt.max();

    final query =
        db.select(db.boards).join([
            leftOuterJoin(db.cards, db.cards.boardId.equalsExp(db.boards.id)),
          ])
          ..addColumns([cardCount, lastUpdated])
          ..where(db.boards.deleted.equals(false))
          ..groupBy([db.boards.id])
          ..orderBy([OrderingTerm.asc(db.boards.sortOrder)]);

    return query.watch().map(
      (rows) => rows
          .map(
            (r) => BoardSummary(
              board: r.readTable(db.boards),
              cardCount: r.read(cardCount) ?? 0,
              lastUpdated: r.read(lastUpdated),
            ),
          )
          .toList(),
    );
  }

  Stream<BoardRow?> watchBoard(String id) =>
      (db.select(db.boards)..where((b) => b.id.equals(id))).watchSingleOrNull();

  Future<String> createBoard({String name = '新看板'}) async {
    final id = _uuid.v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    final order = fractionalIndex(before: await _maxBoardOrder());
    // 随机给个封面色，省得新建出来一片全是灰的。
    final color = kSwatchKeys[_random.nextInt(kSwatchKeys.length)];

    await db.transaction(() async {
      for (final change in [
        (BoardF.name, name),
        (BoardF.color, color),
        (BoardF.sortOrder, order),
        (BoardF.createdAt, now),
      ]) {
        await db.emit(
          boardId: id,
          entity: Entity.board,
          entityId: id,
          field: change.$1,
          value: change.$2,
        );
      }
    });
    return id;
  }

  Future<void> renameBoard(String id, String name) => db.emit(
    boardId: id,
    entity: Entity.board,
    entityId: id,
    field: BoardF.name,
    value: name,
  );

  Future<void> setBoardColor(String id, String colorKey) => db.emit(
    boardId: id,
    entity: Entity.board,
    entityId: id,
    field: BoardF.color,
    value: colorKey,
  );

  /// 删除看板。走墓碑，不做物理删除。
  ///
  /// 板内的卡片和标签不单独打删除标记——它们随看板一起从所有视图里消失，
  /// 真正的清理交给服务端的墓碑回收（90 天）。这样万一误删，恢复看板
  /// 就能把整块内容原样带回来。
  Future<void> deleteBoard(String id) => db.emit(
    boardId: id,
    entity: Entity.board,
    entityId: id,
    field: BoardF.deleted,
    value: true,
  );

  /// 把 [id] 移动到 [before] 和 [after] 之间。
  ///
  /// 用小数序，一次拖动只改这一张卡自己的一个字段，不需要重排整列。
  Future<void> reorderBoard(String id, {double? before, double? after}) => db.emit(
    boardId: id,
    entity: Entity.board,
    entityId: id,
    field: BoardF.sortOrder,
    value: fractionalIndex(before: before, after: after),
  );

  Future<double?> _maxBoardOrder() async {
    final maxOrder = db.boards.sortOrder.max();
    final row = await (db.selectOnly(db.boards)
          ..addColumns([maxOrder])
          ..where(db.boards.deleted.equals(false)))
        .getSingle();
    return row.read(maxOrder);
  }

  // -------------------------------------------------------------------------
  // 卡片
  // -------------------------------------------------------------------------

  /// 画布上的卡片：没删、没归档。按 z 排，后面的画在上面。
  Stream<List<CardRow>> watchCanvasCards(String boardId) =>
      (db.select(db.cards)
            ..where(
              (c) =>
                  c.boardId.equals(boardId) &
                  c.deleted.equals(false) &
                  c.archived.equals(false),
            )
            ..orderBy([(c) => OrderingTerm.asc(c.z)]))
          .watch();

  /// 干草仓库里的卡片，按归档时间倒序（用 updatedAt 近似）。
  Stream<List<CardRow>> watchArchivedCards(String boardId) =>
      (db.select(db.cards)
            ..where(
              (c) =>
                  c.boardId.equals(boardId) &
                  c.deleted.equals(false) &
                  c.archived.equals(true),
            )
            ..orderBy([(c) => OrderingTerm.desc(c.updatedAt)]))
          .watch();

  Future<String> createCard({
    required String boardId,
    required double x,
    required double y,
    String title = '',
    String? colorKey,
  }) async {
    final id = _uuid.v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    final z = fractionalIndex(before: await _maxCardZ(boardId));

    await db.transaction(() async {
      for (final change in <(String, Object?)>[
        (CardF.title, title),
        (CardF.x, x),
        (CardF.y, y),
        (CardF.z, z),
        (CardF.color, colorKey),
        (CardF.createdAt, now),
        (CardF.updatedAt, now),
      ]) {
        await db.emit(
          boardId: boardId,
          entity: Entity.card,
          entityId: id,
          field: change.$1,
          value: change.$2,
        );
      }
    });
    return id;
  }

  /// 改卡片的一个字段，并顺手把 updatedAt 推到现在。
  ///
  /// [touch] 为 false 时不动 updatedAt——纯粹挪位置、调宽度、改层级这类
  /// 操作不该让卡片在「最近修改」里往上跳。
  Future<void> setCardField(
    String boardId,
    String cardId,
    String field,
    Object? value, {
    bool touch = true,
  }) {
    return db.transaction(() async {
      await db.emit(
        boardId: boardId,
        entity: Entity.card,
        entityId: cardId,
        field: field,
        value: value,
      );
      if (touch) {
        await db.emit(
          boardId: boardId,
          entity: Entity.card,
          entityId: cardId,
          field: CardF.updatedAt,
          value: DateTime.now().millisecondsSinceEpoch,
        );
      }
    });
  }

  /// 拖动落位。
  ///
  /// 只在**松手时**调用一次——拖动过程中每帧都写库的话，本地是几百次
  /// 无谓的事务，到 P2 更会把局域网刷爆。
  Future<void> moveCard(String boardId, String cardId, double x, double y) {
    return db.transaction(() async {
      await db.emit(
        boardId: boardId,
        entity: Entity.card,
        entityId: cardId,
        field: CardF.x,
        value: x,
      );
      await db.emit(
        boardId: boardId,
        entity: Entity.card,
        entityId: cardId,
        field: CardF.y,
        value: y,
      );
    });
  }

  /// 把卡片提到最前。改的是它自己的一个字段，不动其他卡片。
  Future<void> bringToFront(String boardId, String cardId) async {
    final z = fractionalIndex(before: await _maxCardZ(boardId));
    await db.emit(
      boardId: boardId,
      entity: Entity.card,
      entityId: cardId,
      field: CardF.z,
      value: z,
    );
  }

  Future<void> archiveCard(String boardId, String cardId, {bool archived = true}) =>
      setCardField(boardId, cardId, CardF.archived, archived);

  Future<void> deleteCard(String boardId, String cardId) =>
      setCardField(boardId, cardId, CardF.deleted, true, touch: false);

  /// 清空干草仓库。
  ///
  /// 可能涉及几百张卡片，所以整批放进一个事务；到 P2 也要打包成一条
  /// 同步消息，不能一张一张发。
  Future<int> emptyHaystack(String boardId) async {
    final archived = await (db.select(db.cards)..where(
          (c) =>
              c.boardId.equals(boardId) &
              c.deleted.equals(false) &
              c.archived.equals(true),
        ))
        .get();

    await db.transaction(() async {
      for (final card in archived) {
        await db.emit(
          boardId: boardId,
          entity: Entity.card,
          entityId: card.id,
          field: CardF.deleted,
          value: true,
        );
      }
    });
    return archived.length;
  }

  /// 一键整理：把画布上散乱的卡片排成网格。
  ///
  /// 保持原有的相对顺序（先按 y 再按 x），这样整理完还认得出哪张是哪张。
  /// 整批放进一个事务——几十张卡片各改两个字段，不能拆成几十次提交。
  Future<void> tidyCards(String boardId, {int columns = 4}) async {
    final cards = await (db.select(db.cards)
          ..where(
            (c) =>
                c.boardId.equals(boardId) &
                c.deleted.equals(false) &
                c.archived.equals(false),
          ))
        .get();
    if (cards.isEmpty) return;

    final sorted = [...cards]..sort((a, b) {
      final dy = a.y.compareTo(b.y);
      return dy != 0 ? dy : a.x.compareTo(b.x);
    });

    const gapX = 24.0;
    const gapY = 24.0;
    const rowHeight = 150.0;
    final colWidth =
        sorted.map((c) => c.width).reduce((a, b) => a > b ? a : b) + gapX;

    await db.transaction(() async {
      for (var i = 0; i < sorted.length; i++) {
        final x = (i % columns) * colWidth + gapX;
        final y = (i ~/ columns) * (rowHeight + gapY) + gapY;
        await db.emit(
          boardId: boardId,
          entity: Entity.card,
          entityId: sorted[i].id,
          field: CardF.x,
          value: x,
        );
        await db.emit(
          boardId: boardId,
          entity: Entity.card,
          entityId: sorted[i].id,
          field: CardF.y,
          value: y,
        );
      }
    });
  }

  Future<double?> _maxCardZ(String boardId) async {
    final maxZ = db.cards.z.max();
    final row = await (db.selectOnly(db.cards)
          ..addColumns([maxZ])
          ..where(db.cards.boardId.equals(boardId) & db.cards.deleted.equals(false)))
        .getSingle();
    return row.read(maxZ);
  }

  // -------------------------------------------------------------------------
  // 标签
  // -------------------------------------------------------------------------

  /// 板内标签，按 sortOrder 排——这个顺序就是分组视图里列的顺序。
  Stream<List<TagRow>> watchTags(String boardId) =>
      (db.select(db.tags)
            ..where((t) => t.boardId.equals(boardId) & t.deleted.equals(false))
            ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
          .watch();

  /// 板内所有生效的卡片-标签关系。
  Stream<List<CardTagRow>> watchCardTags(String boardId) {
    final query = db.select(db.cardTags).join([
      innerJoin(db.cards, db.cards.id.equalsExp(db.cardTags.cardId)),
    ])..where(db.cards.boardId.equals(boardId) & db.cardTags.deleted.equals(false));

    return query.watch().map(
      (rows) => rows.map((r) => r.readTable(db.cardTags)).toList(),
    );
  }

  Future<String> createTag({
    required String boardId,
    required String name,
    String colorKey = kDefaultTagSwatch,
  }) async {
    final id = _uuid.v4();
    final order = fractionalIndex(before: await _maxTagOrder(boardId));

    await db.transaction(() async {
      for (final change in <(String, Object?)>[
        (TagF.name, name),
        (TagF.color, colorKey),
        (TagF.sortOrder, order),
      ]) {
        await db.emit(
          boardId: boardId,
          entity: Entity.tag,
          entityId: id,
          field: change.$1,
          value: change.$2,
        );
      }
    });
    return id;
  }

  Future<void> renameTag(String boardId, String tagId, String name) => db.emit(
    boardId: boardId,
    entity: Entity.tag,
    entityId: tagId,
    field: TagF.name,
    value: name,
  );

  Future<void> setTagColor(String boardId, String tagId, String colorKey) => db.emit(
    boardId: boardId,
    entity: Entity.tag,
    entityId: tagId,
    field: TagF.color,
    value: colorKey,
  );

  /// 删除标签。
  ///
  /// **只删标签本身，卡片一张不动**——失去这个标签的卡片变成「未分类」。
  /// 标签是分类手段，不是卡片的容器，删分类不该连内容一起带走。
  Future<void> deleteTag(String boardId, String tagId) => db.emit(
    boardId: boardId,
    entity: Entity.tag,
    entityId: tagId,
    field: TagF.deleted,
    value: true,
  );

  Future<void> reorderTag(String boardId, String tagId, {double? before, double? after}) =>
      db.emit(
        boardId: boardId,
        entity: Entity.tag,
        entityId: tagId,
        field: TagF.sortOrder,
        value: fractionalIndex(before: before, after: after),
      );

  /// 给卡片打上或摘掉一个标签。
  ///
  /// 关系 ID 由两端拼出，是确定性的：两台设备各自打同一个标签产生的是
  /// 同一条记录的两个 op，天然幂等，不会变成两条重复关系。
  Future<void> setCardTag(
    String boardId,
    String cardId,
    String tagId, {
    required bool on,
  }) => db.emit(
    boardId: boardId,
    entity: Entity.cardTag,
    entityId: cardTagId(cardId, tagId),
    field: CardTagF.deleted,
    value: !on,
  );

  Future<double?> _maxTagOrder(String boardId) async {
    final maxOrder = db.tags.sortOrder.max();
    final row = await (db.selectOnly(db.tags)
          ..addColumns([maxOrder])
          ..where(db.tags.boardId.equals(boardId) & db.tags.deleted.equals(false)))
        .getSingle();
    return row.read(maxOrder);
  }
}
