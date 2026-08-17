import 'dart:convert';

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

/// 卡片上的一次改动。
@immutable
class CardChange {
  final String opId;

  /// 改的哪个字段（[CardF] 里的常量）。
  final String field;

  /// 改成了什么。类型随字段而定，可能是 null（表示置空）。
  final Object? value;

  final String deviceId;

  /// 产生这条改动的设备的本地时间。**只用于显示**——设备时钟不可靠，
  /// 定序一律靠 [seq]。
  final int wallTs;

  /// 服务端分配的序号。还没同步出去的改动为 null。
  final int? seq;

  /// 是不是这个字段当前生效的那一条。
  final bool current;

  const CardChange({
    required this.opId,
    required this.field,
    required this.value,
    required this.deviceId,
    required this.wallTs,
    required this.seq,
    required this.current,
  });
}


/// 一条搜索结果：命中的卡片，以及它所属看板的名字和颜色。
///
/// 只带名字和颜色而不是整行看板数据——搜索结果要显示的就这两样。
@immutable
class SearchHit {
  final CardRow card;
  final String boardName;
  final String? boardColor;

  const SearchHit({
    required this.card,
    required this.boardName,
    required this.boardColor,
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

  Stream<CardRow?> watchCard(String cardId) =>
      (db.select(db.cards)..where((c) => c.id.equals(cardId)))
          .watchSingleOrNull();

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

  /// 在画布现有卡片的下方新建一张，可选地直接打上一个标签。
  ///
  /// 供分组视图的列顶「+」用：那里没有画布上的位置感，但卡片终究要有个
  /// 坐标，所以放在所有卡片下面——不会盖住任何已有的卡。
  Future<String> createCardBelowAll({
    required String boardId,
    String? tagId,
    String title = '',
  }) async {
    final cards = await (db.select(db.cards)..where(
          (c) =>
              c.boardId.equals(boardId) &
              c.deleted.equals(false) &
              c.archived.equals(false),
        ))
        .get();

    final y = cards.isEmpty
        ? 40.0
        : cards.map((c) => c.y).reduce((a, b) => a > b ? a : b) + 170;

    final id = await createCard(boardId: boardId, x: 40, y: y, title: title);
    if (tagId != null) {
      await setCardTag(boardId, id, tagId, on: true);
    }
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
  /// 把散乱的卡片排成整齐的几列。
  ///
  /// [heights] 是每张卡片**实际渲染出来的高度**，由画布量好传进来；
  /// 量不到的卡片退回 [fallbackHeight]。
  ///
  /// 为什么要外面传高度：卡片高度是内容撑出来的（标题几行、正文多长、
  /// 有没有封面图），只有布局跑完才知道，数据层量不到。原来这里写死
  /// 150，加了封面图之后一张带图的卡片轻松超过 300，整理完直接盖住
  /// 下一行——这正是这个方法要修的问题。
  ///
  /// 排布用的是「哪列短就往哪列放」而不是严格的一行一行填。高度参差很大
  /// 时，按行填会因为要迁就本行最高的那张而留下大片空白；而「整理」这个
  /// 动作的意义就是把东西码整齐，紧凑比保持严格的左右顺序更重要。
  Future<void> tidyCards(
    String boardId, {
    int columns = 4,
    Map<String, double> heights = const {},
    double fallbackHeight = 150,
  }) async {
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
    final colWidth =
        sorted.map((c) => c.width).reduce((a, b) => a > b ? a : b) + gapX;

    // 每列当前堆到哪个 y。
    final columnBottom = List<double>.filled(columns, gapY);

    await db.transaction(() async {
      for (final card in sorted) {
        // 挑最短的一列。并列时取最左边那个，结果才是确定的——
        // 同样一批卡片整理两次必须得到同样的结果。
        var target = 0;
        for (var i = 1; i < columns; i++) {
          if (columnBottom[i] < columnBottom[target]) target = i;
        }

        final x = target * colWidth + gapX;
        final y = columnBottom[target];

        await db.emit(
          boardId: boardId,
          entity: Entity.card,
          entityId: card.id,
          field: CardF.x,
          value: x,
        );
        await db.emit(
          boardId: boardId,
          entity: Entity.card,
          entityId: card.id,
          field: CardF.y,
          value: y,
        );

        columnBottom[target] = y + (heights[card.id] ?? fallbackHeight) + gapY;
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
  /// 打勾／取消打勾。
  ///
  /// `touch: false`——打勾不算「内容改动」，不该让卡片在「最近修改」里
  /// 往上跳。和挪位置、折叠是一类操作。
  Future<void> toggleCardDone(String boardId, String cardId, bool done) =>
      setCardField(boardId, cardId, CardF.done, done, touch: false);

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

  // -------------------------------------------------------------------------
  // 搜索
  // -------------------------------------------------------------------------

  /// 跨看板搜索卡片。
  ///
  /// 用 `instr()` 而不是设计文档里写的 FTS5。理由是算过账：个人看板撑死
  /// 几千张卡片，扫两列文本是亚毫秒级；而 FTS5 要建虚拟表、要在 op 应用
  /// 路径上维护索引、要处理迁移。**为了测不出来的性能差异引入这些复杂度
  /// 不划算。** 真到几万张卡片时再换，届时这个方法的签名不用变。
  ///
  /// 用 instr 而不是 LIKE，是因为 **SQLite 的 LIKE 没有默认转义符**：
  /// 不加 ESCAPE 子句的话，用户搜 `%` 会匹配到所有卡片、搜 `_` 会匹配到
  /// 任意单字。instr 是纯粹的子串查找，没有通配符这回事。
  ///
  /// 子串匹配对中文也天然可用，不需要分词——FTS5 反而要专门配 trigram。
  Stream<List<SearchHit>> searchCards(String query, {String? boardId}) {
    final text = query.trim();
    if (text.isEmpty) return Stream.value(const []);

    return db
        .customSelect(
          'SELECT c.*, b.name AS b_name, b.color AS b_color '
          'FROM cards c JOIN boards b ON b.id = c.board_id '
          'WHERE c.deleted = 0 AND b.deleted = 0 '
          'AND (instr(c.title, ?) > 0 OR instr(c.body, ?) > 0) '
          'AND (? IS NULL OR c.board_id = ?) '
          'ORDER BY c.updated_at DESC LIMIT 200',
          variables: [
            Variable(text),
            Variable(text),
            Variable(boardId),
            Variable(boardId),
          ],
          readsFrom: {db.cards, db.boards},
        )
        .watch()
        .map(
          (rows) => [
            for (final r in rows)
              SearchHit(
                card: db.cards.map(r.data),
                boardName: r.read<String>('b_name'),
                boardColor: r.data['b_color'] as String?,
              ),
          ],
        );
  }


  /// 每张卡片的封面图：它的**第一张**图片附件。
  ///
  /// 「第一张」按添加时间算，和详情里附件的排列顺序一致——用户在详情里
  /// 看到排在最前的那张，就是画布上显示的那张，不会对不上。
  ///
  /// 只挑图片：文档类附件没有可看的缩略图，拿文件名当封面没有意义。
  Stream<Map<String, AttachmentRow>> watchCardCovers(String boardId) {
    final q = db.select(db.attachments).join([
      innerJoin(db.cards, db.cards.id.equalsExp(db.attachments.cardId)),
    ])
      ..where(
        db.cards.boardId.equals(boardId) &
            db.attachments.deleted.equals(false) &
            db.cards.deleted.equals(false) &
            db.attachments.mime.like('image/%'),
      )
      ..orderBy([OrderingTerm.asc(db.attachments.createdAt)]);

    return q.watch().map((rows) {
      final covers = <String, AttachmentRow>{};
      for (final r in rows) {
        final a = r.readTable(db.attachments);
        // 已经有了就不覆盖——排序是升序，先遇到的就是最早那张。
        covers.putIfAbsent(a.cardId, () => a);
      }
      return covers;
    });
  }


  /// 这张卡片的全部改动记录，最近的在前。
  ///
  /// **数据本来就存着**——底层是只增不删的操作日志，每条都记了哪台设备、
  /// 什么时候、把哪个字段改成了什么。这里只是把它读出来，没有任何新存储。
  ///
  /// 这是多设备离线各自修改后「到底谁的版本被留下了」唯一能查的地方：
  /// 字段级 LWW 只保留一个赢家，输掉的那份不会出现在卡片上，但它一直
  /// 在日志里。
  ///
  /// 只看内容类字段，不看坐标、层级、折叠这些——那些每拖一下就产生一条，
  /// 会把真正有意义的改动淹掉。
  Stream<List<CardChange>> watchCardChanges(String cardId) {
    const interesting = {
      CardF.title,
      CardF.body,
      CardF.color,
      CardF.done,
      CardF.archived,
      kDeleted,
    };

    final q = db.select(db.ops)
      ..where(
        (o) =>
            o.entity.equals(Entity.card) &
            o.entityId.equals(cardId) &
            o.field.isIn(interesting.toList()),
      );

    return q.watch().map((rows) {
      // 每个字段当前的赢家：定序键最大的那条。和 applyOp 用的是同一把尺子。
      final winners = <String, OpRow>{};
      for (final r in rows) {
        final cur = winners[r.field];
        if (cur == null ||
            compareOpOrder(cur.seq, cur.localSeq, r.seq, r.localSeq) < 0) {
          winners[r.field] = r;
        }
      }

      final list = [
        for (final r in rows)
          CardChange(
            opId: r.opId,
            field: r.field,
            value: jsonDecode(r.valueJson),
            deviceId: r.deviceId,
            wallTs: r.wallTs,
            seq: r.seq,
            current: winners[r.field]?.opId == r.opId,
          ),
      ];

      // 按**定序键**倒序，不按 wallTs。
      //
      // 两个原因：一是设备时钟不可靠，跨设备按 wallTs 排会得出错误的
      // 先后；二是同一毫秒内的多次修改 wallTs 相同，而 Dart 的 sort
      // 不保证稳定，顺序会变——列表每次刷新都可能重排。
      //
      // 定序键是全局唯一且严格递增的，和「谁最终赢了」用的是同一把尺子，
      // 所以列表顺序和卡片上的实际内容永远对得上。wallTs 只用来显示。
      list.sort((a, b) {
        final ra = rows.firstWhere((r) => r.opId == a.opId);
        final rb = rows.firstWhere((r) => r.opId == b.opId);
        return compareOpOrder(rb.seq, rb.localSeq, ra.seq, ra.localSeq);
      });
      return list;
    });
  }

  /// 把某个字段恢复成历史上的某个值。
  ///
  /// 不是「回滚」——它产生一条**新的** op，值等于旧值。这样恢复本身也是
  /// 一次可追溯的改动，会同步给别的设备，也能再被恢复回去。
  Future<void> restoreCardValue(
    String boardId,
    String cardId,
    String field,
    Object? value,
  ) => setCardField(boardId, cardId, field, value);

  // -------------------------------------------------------------------------
  // 附件
  // -------------------------------------------------------------------------

  /// 某张卡片的附件，按添加时间正序。
  Stream<List<AttachmentRow>> watchAttachments(String cardId) =>
      (db.select(db.attachments)
            ..where((a) => a.cardId.equals(cardId) & a.deleted.equals(false))
            ..orderBy([(a) => OrderingTerm.asc(a.createdAt)]))
          .watch();

  /// 把一个已经导入本地缓存的文件挂到卡片上。
  ///
  /// 只写 op，**不碰网络**——离线时加附件必须立刻可用，上传是后台的事。
  Future<String> addAttachment({
    required String boardId,
    required String cardId,
    required String hash,
    required String filename,
    required int size,
    required String mime,
    String? thumbHash,
  }) async {
    final id = _uuid.v4();
    await db.transaction(() async {
      for (final change in <(String, Object?)>[
        (AttachmentF.cardId, cardId),
        (AttachmentF.hash, hash),
        (AttachmentF.thumbHash, thumbHash),
        (AttachmentF.filename, filename),
        (AttachmentF.size, size),
        (AttachmentF.mime, mime),
        (AttachmentF.createdAt, DateTime.now().millisecondsSinceEpoch),
      ]) {
        await db.emit(
          boardId: boardId,
          entity: Entity.attachment,
          entityId: id,
          field: change.$1,
          value: change.$2,
        );
      }
    });
    return id;
  }

  /// 删除附件。走墓碑，**不删磁盘上的文件**——同一份内容可能还挂在别的
  /// 卡片上，而且服务端的回收是延迟 30 天的，这期间还能后悔。
  Future<void> deleteAttachment(String boardId, String attachmentId) => db.emit(
    boardId: boardId,
    entity: Entity.attachment,
    entityId: attachmentId,
    field: AttachmentF.deleted,
    value: true,
  );

  /// 每张卡片的附件数，用于画布上的角标。
  Stream<Map<String, int>> watchAttachmentCounts(String boardId) {
    final count = db.attachments.id.count();
    final query =
        db.selectOnly(db.attachments).join([
            innerJoin(db.cards, db.cards.id.equalsExp(db.attachments.cardId)),
          ])
          ..addColumns([db.attachments.cardId, count])
          ..where(
            db.cards.boardId.equals(boardId) &
                db.attachments.deleted.equals(false),
          )
          ..groupBy([db.attachments.cardId]);

    return query.watch().map(
      (rows) => {
        for (final r in rows) r.read(db.attachments.cardId)!: r.read(count) ?? 0,
      },
    );
  }

  // -------------------------------------------------------------------------
  // 评论
  // -------------------------------------------------------------------------

  /// 某张卡片的评论，按发表时间正序。
  Stream<List<CommentRow>> watchComments(String cardId) =>
      (db.select(db.comments)
            ..where((c) => c.cardId.equals(cardId) & c.deleted.equals(false))
            ..orderBy([(c) => OrderingTerm.asc(c.createdAt)]))
          .watch();

  /// 发表一条评论，返回它的 ID。
  ///
  /// 评论**只增不改**：发表后不能编辑，想改就删了重发。因此评论天然没有
  /// 冲突，不需要参与 LWW——不存在两端同时修改同一条评论的情况。
  Future<String> addComment(String boardId, String cardId, String body) async {
    final id = _uuid.v4();
    await db.transaction(() async {
      for (final change in <(String, Object?)>[
        (CommentF.cardId, cardId),
        (CommentF.body, body),
        (CommentF.createdAt, DateTime.now().millisecondsSinceEpoch),
      ]) {
        await db.emit(
          boardId: boardId,
          entity: Entity.comment,
          entityId: id,
          field: change.$1,
          value: change.$2,
        );
      }
    });
    return id;
  }

  Future<void> deleteComment(String boardId, String commentId) => db.emit(
    boardId: boardId,
    entity: Entity.comment,
    entityId: commentId,
    field: CommentF.deleted,
    value: true,
  );

  /// 每张卡片的评论数，用于画布上的角标。
  Stream<Map<String, int>> watchCommentCounts(String boardId) {
    final count = db.comments.id.count();
    final query =
        db.selectOnly(db.comments).join([
            innerJoin(db.cards, db.cards.id.equalsExp(db.comments.cardId)),
          ])
          ..addColumns([db.comments.cardId, count])
          ..where(
            db.cards.boardId.equals(boardId) & db.comments.deleted.equals(false),
          )
          ..groupBy([db.comments.cardId]);

    return query.watch().map(
      (rows) => {
        for (final r in rows) r.read(db.comments.cardId)!: r.read(count) ?? 0,
      },
    );
  }

  Future<double?> _maxTagOrder(String boardId) async {
    final maxOrder = db.tags.sortOrder.max();
    final row = await (db.selectOnly(db.tags)
          ..addColumns([maxOrder])
          ..where(db.tags.boardId.equals(boardId) & db.tags.deleted.equals(false)))
        .getSingle();
    return row.read(maxOrder);
  }
}
