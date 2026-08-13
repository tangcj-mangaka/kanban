import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:shared/shared.dart';
import 'package:uuid/uuid.dart';

import 'tables.dart';

part 'database.g.dart';

const _uuid = Uuid();

/// 比较两条 op 的生效先后。正数表示 [a] 更新，应当覆盖 [b]。
///
/// 定序规则分三种情况：
/// - 两条都已被服务端确认 → 比 seq，这是唯一权威的全局顺序
/// - 两条都未确认 → 比 localSeq，即本机的产生顺序
/// - 一确认一未确认 → **未确认的赢**
///
/// 第三条是本地优先的直接体现：服务端还没表态之前，本机刚做的修改
/// 就是本地最新的认知，必须立刻生效，不能被一条旧的已确认 op 压住。
/// 等服务端回填 seq 之后，顺序会按第一条规则重新裁定。
int compareOpOrder(int? aSeq, int aLocal, int? bSeq, int bLocal) {
  if (aSeq != null && bSeq != null) return aSeq.compareTo(bSeq);
  if (aSeq == null && bSeq == null) return aLocal.compareTo(bLocal);
  return aSeq == null ? 1 : -1;
}

@DriftDatabase(
  tables: [
    Ops,
    FieldSeqs,
    Boards,
    Tags,
    Cards,
    CardTags,
    Attachments,
    Comments,
    Settings,
    FileCaches,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
    : super(executor ?? driftDatabase(name: 'kanban'));

  /// 本机标识，用于区分 op 的来源设备。
  ///
  /// P1 里只有一台设备，先用固定值；P2 配对时换成持久化的真实 device id。
  String deviceId = 'local';

  @override
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      // v2：加了本机设置表（服务器地址、令牌、同步进度）。
      if (from < 2) await m.createTable(settings);
      // v3：加了附件的本机缓存表。
      if (from < 3) await m.createTable(fileCaches);
      // v4：卡片加了「完成」勾。
      if (from < 4) {
        await m.addColumn(cards, cards.done);
        // 升级前收到过的 done op 当时被当成未知字段跳过了（那会儿还没这一列）。
        // 不补这一下，别的设备上勾好的卡片在这台上会永远是没勾的。
        await _replayField(Entity.card, CardF.done);
      }
    },
  );

  /// 本机产生了新 op。同步层据此触发一次推送。
  ///
  /// 用广播流而不是让同步层轮询待发队列——用户松手到局域网另一端动起来
  /// 之间的延迟，不该由轮询间隔决定。
  Stream<void> get localOpAdded => _localOps.stream;
  final _localOps = StreamController<void>.broadcast();

  @override
  Future<void> close() {
    _localOps.close();
    return super.close();
  }

  // -------------------------------------------------------------------------
  // 本机设置
  // -------------------------------------------------------------------------

  Future<String?> getSetting(String key) async {
    final row = await (select(settings)..where((s) => s.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> setSetting(String key, String? value) async {
    if (value == null) {
      await (delete(settings)..where((s) => s.key.equals(key))).go();
      return;
    }
    await into(settings).insertOnConflictUpdate(
      SettingsCompanion.insert(key: key, value: value),
    );
  }

  Future<int> getIntSetting(String key, {int fallback = 0}) async =>
      int.tryParse(await getSetting(key) ?? '') ?? fallback;

  // -------------------------------------------------------------------------
  // 字段名 → 列对象的映射
  //
  // op 里的字段名是字符串，落到 SQL 要变成列名。这里不硬编码列名字符串，
  // 而是直接引用 drift 生成的列对象——写错字段名是编译错误，不是运行时
  // 才炸出来的问题。列的真实 SQL 名和类型也都从对象上取，不会写歪。
  // -------------------------------------------------------------------------

  late final Map<String, TableInfo<Table, dynamic>> _tables = {
    Entity.board: boards,
    Entity.tag: tags,
    Entity.card: cards,
    Entity.cardTag: cardTags,
    Entity.attachment: attachments,
    Entity.comment: comments,
  };

  late final Map<String, Map<String, GeneratedColumn<Object>>> _columns = {
    Entity.board: {
      BoardF.name: boards.name,
      BoardF.color: boards.color,
      BoardF.sortOrder: boards.sortOrder,
      BoardF.createdAt: boards.createdAt,
      BoardF.deleted: boards.deleted,
    },
    Entity.tag: {
      TagF.name: tags.name,
      TagF.color: tags.color,
      TagF.sortOrder: tags.sortOrder,
      TagF.deleted: tags.deleted,
    },
    Entity.card: {
      CardF.title: cards.title,
      CardF.body: cards.body,
      CardF.color: cards.color,
      CardF.x: cards.x,
      CardF.y: cards.y,
      CardF.width: cards.width,
      CardF.z: cards.z,
      CardF.collapsed: cards.collapsed,
      CardF.done: cards.done,
      CardF.archived: cards.archived,
      CardF.createdAt: cards.createdAt,
      CardF.updatedAt: cards.updatedAt,
      CardF.deleted: cards.deleted,
    },
    Entity.cardTag: {CardTagF.deleted: cardTags.deleted},
    Entity.attachment: {
      AttachmentF.cardId: attachments.cardId,
      AttachmentF.hash: attachments.hash,
      AttachmentF.thumbHash: attachments.thumbHash,
      AttachmentF.filename: attachments.filename,
      AttachmentF.size: attachments.size,
      AttachmentF.mime: attachments.mime,
      AttachmentF.createdAt: attachments.createdAt,
      AttachmentF.deleted: attachments.deleted,
    },
    Entity.comment: {
      CommentF.cardId: comments.cardId,
      CommentF.body: comments.body,
      CommentF.createdAt: comments.createdAt,
      CommentF.deleted: comments.deleted,
    },
  };

  /// 一行刚被创建时必须填上的列。
  ///
  /// op 是一条一条到的，某个字段的 op 还没来时这一行也得能以合法状态存在，
  /// 所以物化表除主键外全都有默认值。这里只补那些没有默认值、又无法从
  /// 后续 op 推出来的列。
  Map<GeneratedColumn<Object>, Object?> _seedColumns(Op op) {
    switch (op.entity) {
      case Entity.board:
        return {boards.id: op.entityId};
      case Entity.tag:
        return {tags.id: op.entityId, tags.boardId: op.boardId};
      case Entity.card:
        return {cards.id: op.entityId, cards.boardId: op.boardId};
      case Entity.cardTag:
        // 关系 ID 是 `cardId:tagId` 拼出来的，两端直接拆出来即可，
        // 不必为 card_id / tag_id 各发一条 op。
        final sep = op.entityId.indexOf(':');
        return {
          cardTags.id: op.entityId,
          cardTags.cardId: op.entityId.substring(0, sep),
          cardTags.tagId: op.entityId.substring(sep + 1),
        };
      case Entity.attachment:
        return {attachments.id: op.entityId};
      case Entity.comment:
        return {comments.id: op.entityId};
      default:
        throw ArgumentError('未知实体类型：${op.entity}');
    }
  }

  /// 把 JSON 解出来的值转成该列能直接绑定的形式。
  ///
  /// JSON 里整数 0 和浮点 0.0 无法区分，所以 real 列要显式转 double；
  /// bool 在 SQLite 里存成 0/1。
  Object? _coerce(GeneratedColumn<Object> column, Object? value) {
    if (value == null) return null;
    return switch (column.type) {
      DriftSqlType.string => value as String,
      DriftSqlType.int => (value as num).toInt(),
      DriftSqlType.double => (value as num).toDouble(),
      DriftSqlType.bool => (value == true || value == 1) ? 1 : 0,
      _ => throw ArgumentError('列 ${column.name} 的类型暂不支持：${column.type}'),
    };
  }

  // -------------------------------------------------------------------------
  // 应用 op
  // -------------------------------------------------------------------------

  /// 应用一条 op，返回它是否真的生效。
  ///
  /// 返回 false 有两种情况：这条 op 之前已经处理过（按 opId 去重），
  /// 或者该字段上已经有一条定序更靠后的 op 说了算——乱序到达的 op
  /// 会在这里被正确地丢弃，而不是把新值覆盖回旧值。
  Future<bool> applyOp(Op op) {
    return transaction(() async {
      final dup =
          await (select(ops)..where((o) => o.opId.equals(op.opId))).getSingleOrNull();
      if (dup != null) return false;

      // 远程 op 也要拿一个本地序号：它自己的 seq 已经定了全局顺序，
      // localSeq 只是让本地待发队列和它排在同一个尺子上。
      final localSeq = await _nextLocalSeq();

      await into(ops).insert(
        OpsCompanion.insert(
          opId: op.opId,
          seq: Value(op.seq),
          localSeq: localSeq,
          boardId: op.boardId,
          entity: op.entity,
          entityId: op.entityId,
          field: op.field,
          valueJson: jsonEncode(op.value),
          deviceId: op.deviceId,
          wallTs: op.wallTs,
        ),
      );

      final current = await (select(fieldSeqs)
            ..where((f) => f.entityId.equals(op.entityId) & f.field.equals(op.field)))
          .getSingleOrNull();

      if (current != null &&
          compareOpOrder(op.seq, localSeq, current.seq, current.localSeq) <= 0) {
        return false;
      }

      // 不认识的字段：**照常记进 op 日志、照常算作已处理**，只是不往
      // 物化表里写，也不更新 fieldSeqs。
      //
      // 这是版本不一致而不是错误——新版设备加了字段，这台还不认识。
      // 以前这里是直接抛异常的，后果很重：旧设备收到这条 op 就失败、
      // lastSeq 推不动、重连后服务器再发一遍、再失败，同步**永久卡死**，
      // 而界面上只显示「连接中」，看不出任何原因。
      //
      // fieldSeqs 也不更新，是为了让这台设备升级之后还能把这条补上——
      // 见 [_replayField]，加列的迁移会重放日志。
      if (!_canMaterialize(op)) return true;

      await _writeField(op);

      await into(fieldSeqs).insertOnConflictUpdate(
        FieldSeqsCompanion.insert(
          entityId: op.entityId,
          field: op.field,
          seq: Value(op.seq),
          localSeq: localSeq,
        ),
      );

      return true;
    });
  }

  /// 这个 op 的字段能不能落到物化表上。
  bool _canMaterialize(Op op) =>
      _tables[op.entity] != null && _columns[op.entity]?[op.field] != null;

  /// 把日志里某个字段的 op 全部重放一遍。
  ///
  /// 加新列的迁移要调它：这台设备升级前收到过的该字段 op 都被跳过了
  /// （那时还没有这一列），升级后得把它们补上，否则别的设备上勾好的
  /// 卡片，在这台上永远是没勾的。
  Future<void> _replayField(String entity, String field) async {
    final rows =
        await (select(ops)
              ..where((o) => o.entity.equals(entity) & o.field.equals(field)))
            .get();

    final entityIds = {for (final r in rows) r.entityId};
    for (final id in entityIds) {
      await recomputeField(id, field);
    }
  }

  // -------------------------------------------------------------------------
  // 服务端确认
  // -------------------------------------------------------------------------

  /// 服务端确认了一批 op：回填 seq，并**重放受影响的字段**。
  ///
  /// 只回填 seq 是不够的，会丢更新。设想：
  ///
  /// 1. 本机待发 op P 改字段 F，已在本地生效
  /// 2. 另一台设备也改了 F，服务端给它分配 seq = 105
  /// 3. 本机先收到 105 的广播 → 按「未确认的赢」→ 105 没写进物化表
  /// 4. 本机随后收到自己的 ACK，P 拿到 seq = 101
  /// 5. 若只回填 seq，本机会一直认为 P 生效——但正确答案是对方的 105
  ///
  /// 之所以能救回来，是因为第 3 步被丢弃的 op **一直存在 op log 里**：
  /// op log 是真相源，物化表只是读视图。重放就是回到真相源重新求值。
  Future<void> ackOps(Map<String, int> seqByOpId) {
    return transaction(() async {
      final affected = <(String, String)>{};

      for (final entry in seqByOpId.entries) {
        final row = await (select(ops)..where((o) => o.opId.equals(entry.key)))
            .getSingleOrNull();
        if (row == null) continue;

        await (update(ops)..where((o) => o.opId.equals(entry.key))).write(
          OpsCompanion(seq: Value(entry.value)),
        );
        affected.add((row.entityId, row.field));
      }

      for (final (entityId, field) in affected) {
        await recomputeField(entityId, field);
      }
    });
  }

  /// 从 op log 重放某个字段，重新裁定赢家并写回物化表。
  ///
  /// 增量比较（[applyOp] 里那段）只是快路径；正确性靠「op log 永远完整」
  /// 加上这里的重放来保证。
  Future<void> recomputeField(String entityId, String field) async {
    final rows = await (select(ops)
          ..where((o) => o.entityId.equals(entityId) & o.field.equals(field)))
        .get();
    if (rows.isEmpty) return;

    rows.sort(
      (a, b) => compareOpOrder(a.seq, a.localSeq, b.seq, b.localSeq),
    );
    final winner = rows.last;

    await _writeField(
      Op(
        seq: winner.seq,
        opId: winner.opId,
        boardId: winner.boardId,
        entity: winner.entity,
        entityId: winner.entityId,
        field: winner.field,
        value: jsonDecode(winner.valueJson),
        deviceId: winner.deviceId,
        wallTs: winner.wallTs,
      ),
    );

    await into(fieldSeqs).insertOnConflictUpdate(
      FieldSeqsCompanion.insert(
        entityId: entityId,
        field: field,
        seq: Value(winner.seq),
        localSeq: winner.localSeq,
      ),
    );
  }

  Future<int> _nextLocalSeq() async {
    final row = await customSelect(
      'SELECT COALESCE(MAX(local_seq), 0) + 1 AS next FROM ${ops.actualTableName}',
      readsFrom: {ops},
    ).getSingle();
    return row.read<int>('next');
  }

  /// 把 op 的值写进物化表，行不存在就先建出来。
  Future<void> _writeField(Op op) async {
    final table = _tables[op.entity];
    final column = _columns[op.entity]?[op.field];
    if (table == null || column == null) {
      throw ArgumentError('未知字段：${op.entity}.${op.field}');
    }

    // 建行用的列 + 本次要写的列。两者可能重叠（比如 seed 里已经带了这一列），
    // 重叠时以 op 的值为准，不能在 INSERT 里把同一列写两遍。
    final values = <String, Object?>{
      for (final e in _seedColumns(op).entries) e.key.name: e.value,
      column.name: _coerce(column, op.value),
    };

    final cols = values.keys.join(', ');
    final placeholders = List.filled(values.length, '?').join(', ');
    final pk = table.$primaryKey.map((c) => c.name).join(', ');

    // **必须用 customUpdate 并声明 updates。**
    //
    // customStatement 执行的是裸 SQL，drift 无从知道它改了哪张表，
    // 于是不会通知任何查询流——结果是每一条 op 都正确落库，但界面
    // 一动不动，只显示启动那一刻的数据。本地编辑和同步过来的改动
    // 全都看不见。
    //
    // 这个 bug 藏了很久：之前的截图都是「先用脚本灌数据、再启动应用」，
    // 读的是启动快照；测试里用的是 .first，每次都新建查询。两种方式
    // 都照不出「流不发新值」。
    await customUpdate(
      'INSERT INTO ${table.actualTableName} ($cols) VALUES ($placeholders) '
      'ON CONFLICT($pk) DO UPDATE SET '
      '${column.name} = excluded.${column.name}',
      variables: [for (final v in values.values) Variable(v)],
      updates: {table},
      updateKind: UpdateKind.insert,
    );
  }

  // -------------------------------------------------------------------------
  // 产生本地 op
  // -------------------------------------------------------------------------

  /// 产生并应用一条本地修改。
  ///
  /// P1 里所有 op 都停在未确认状态（seq 为 null），排序退化成纯 localSeq；
  /// P2 接上服务端后，这些 op 会被推送上去并回填 seq，这里一行不用改。
  Future<void> emit({
    required String boardId,
    required String entity,
    required String entityId,
    required String field,
    required Object? value,
  }) async {
    // 本机自己写错字段名是 bug，得当场炸出来。
    //
    // [applyOp] 对未知字段是宽容的，但那条规则是给**远端**来的 op 用的
    // （版本不一致），不该顺带把本地的拼写错误也咽下去——那种错误
    // 悄悄丢一条 op，等发现时数据已经不对了。
    if (_columns[entity]?[field] == null) {
      throw ArgumentError('未知字段：$entity.$field');
    }

    await applyOp(
      Op(
        opId: _uuid.v4(),
        boardId: boardId,
        entity: entity,
        entityId: entityId,
        field: field,
        value: value,
        deviceId: deviceId,
        wallTs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    if (!_localOps.isClosed) _localOps.add(null);
  }

  /// 一次性提交一批修改。
  ///
  /// 「清空干草仓库」这类操作可能涉及几百张卡片，必须打包成一个事务，
  /// 到 P2 也要打包成一条同步消息，不能一条一条发。
  Future<void> emitBatch(List<({String field, Object? value})> changes, {
    required String boardId,
    required String entity,
    required String entityId,
  }) {
    return transaction(() async {
      for (final c in changes) {
        await emit(
          boardId: boardId,
          entity: entity,
          entityId: entityId,
          field: c.field,
          value: c.value,
        );
      }
    });
  }

  /// 尚未同步到服务端的 op，按本地顺序排列。
  ///
  /// P2 重连后按这个顺序补发。
  Future<List<OpRow>> pendingOps() =>
      (select(ops)
            ..where((o) => o.seq.isNull())
            ..orderBy([(o) => OrderingTerm.asc(o.localSeq)]))
          .get();
}
