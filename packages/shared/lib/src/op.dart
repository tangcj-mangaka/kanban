import 'package:meta/meta.dart';

/// 实体类型。一条 op 通过 `(entity, entityId, field)` 定位到要改的那一格。
abstract final class Entity {
  static const board = 'board';
  static const tag = 'tag';
  static const card = 'card';
  static const cardTag = 'card_tag';
  static const attachment = 'attachment';
  static const comment = 'comment';

  static const all = {board, tag, card, cardTag, attachment, comment};
}

/// 墓碑标记，所有实体共用。
///
/// 删除不做物理删除——否则会出现「A 设备删了卡片、B 设备同时改了它，
/// 同步后卡片复活」。删除记作一次普通的字段修改，与编辑竞争时按 seq 决胜。
const String kDeleted = 'deleted';

abstract final class BoardF {
  static const name = 'name';
  static const color = 'color';
  static const sortOrder = 'sort_order';
  static const createdAt = 'created_at';
  static const deleted = kDeleted;
}

abstract final class TagF {
  static const name = 'name';
  static const color = 'color';
  static const sortOrder = 'sort_order';
  static const deleted = kDeleted;
}

abstract final class CardF {
  static const title = 'title';
  static const body = 'body';
  static const color = 'color';
  static const x = 'x';
  static const y = 'y';
  static const width = 'width';
  static const z = 'z';
  static const collapsed = 'collapsed';

  /// 打勾表示做完了。**和归档无关**——完成的卡片留在原位，
  /// 什么时候收进干草仓库由用户自己决定。
  static const done = 'done';
  static const archived = 'archived';
  static const createdAt = 'created_at';
  static const updatedAt = 'updated_at';
  static const deleted = kDeleted;
}

/// 卡片与标签的关系只有「在」和「不在」两种状态，所以只用得上墓碑字段。
abstract final class CardTagF {
  static const cardId = 'card_id';
  static const tagId = 'tag_id';
  static const deleted = kDeleted;
}

abstract final class AttachmentF {
  static const cardId = 'card_id';
  static const hash = 'hash';
  static const thumbHash = 'thumb_hash';
  static const filename = 'filename';
  static const size = 'size';
  static const mime = 'mime';
  static const createdAt = 'created_at';
  static const deleted = kDeleted;
}

/// 评论只增不改：发表后不能编辑，想改就删了重发。
///
/// 因此评论天然没有冲突，不需要参与 LWW——每条评论是独立记录，
/// 只有「创建」和「删除」两种 op。
abstract final class CommentF {
  static const cardId = 'card_id';
  static const body = 'body';
  static const createdAt = 'created_at';
  static const deleted = kDeleted;
}

/// 一次原子的字段修改，是同步的最小单位。
///
/// op log 是整个系统的真相源，所有物化表都是它回放出来的读视图。
/// 这样做换来三件事：同步协议简化成「给我 seq 大于 N 的所有 op」；
/// 离线队列天然就是本地未同步的那批 op；字段级 LWW 不需要额外机制，
/// 同一个 `(entityId, field)` 上 seq 最大的 op 生效即可。
@immutable
class Op {
  /// 服务端分配的全局递增序号，是判断先后的**唯一**权威。
  ///
  /// 本地新产生、尚未同步的 op 此处为 null，按本地插入顺序排队，
  /// 服务端确认后回填真实序号。
  ///
  /// 不用时间戳排序——设备之间时钟能差好几秒，用本地时间判断先后
  /// 会出玄学 bug。既然只有一个服务端，谁的 op 先到谁的号就小，绝对可靠。
  final int? seq;

  /// 客户端生成的 UUID。重连补发时同一条 op 可能被发送两次，靠它去重。
  final String opId;

  /// 所属看板。用于按板做增量同步和清理，卡片、标签、评论都归到板下。
  final String boardId;

  final String entity;
  final String entityId;
  final String field;

  /// 字段的新值。必须是 JSON 基本类型（String / int / double / bool / null）。
  ///
  /// null 表示把该字段置空，不是「没有这个 op」。
  final Object? value;

  final String deviceId;

  /// 客户端本地时间（毫秒）。**只用于显示**「3 分钟前」这类信息，
  /// 绝不参与排序或冲突判定——那是 [seq] 的职责。
  final int wallTs;

  /// 产生这条 op 时，这台设备已经知道到服务端的哪一号。
  ///
  /// 用来判断两条改动是不是**真并发**。只靠 [seq] 判断不出来：seq 只说
  /// 谁先到服务器，说不出「做这个改动的人当时看没看见对方的改动」。
  ///
  /// 判据是：a 和 b 并发 ⟺ `a.baseSeq < b.seq` 且 `b.baseSeq < a.seq`
  /// ——双方都是在没见过对方的情况下做出的。
  ///
  /// 举个必须靠它才能判对的例子：笔记本兼做服务器、一直在线，它的改动
  /// 立刻拿到小号；手机离线改完后来才连上，拿到大号。等笔记本收到手机
  /// 那条时，自己那条**早就有号了**，光看「有没有同步过」会漏判。
  ///
  /// 远端 op 也带着它（发送方填的），所以两边都能算。旧版本发来的 op
  /// 没有这个字段，此时为 null，按「无法判定」处理——不报冲突，
  /// 宁可漏报也不错报。
  final int? baseSeq;

  const Op({
    this.seq,
    required this.opId,
    required this.boardId,
    required this.entity,
    required this.entityId,
    required this.field,
    required this.value,
    required this.deviceId,
    required this.wallTs,
    this.baseSeq,
  });

  /// 是否已被服务端确认。未确认的 op 留在本地待发队列里。
  bool get isSynced => seq != null;

  Op withSeq(int newSeq) => Op(
    seq: newSeq,
    opId: opId,
    boardId: boardId,
    entity: entity,
    entityId: entityId,
    field: field,
    value: value,
    deviceId: deviceId,
    wallTs: wallTs,
    baseSeq: baseSeq,
  );

  Map<String, Object?> toJson() => {
    if (seq != null) 'seq': seq,
    'op_id': opId,
    'board_id': boardId,
    'entity': entity,
    'entity_id': entityId,
    'field': field,
    'value': value,
    'device_id': deviceId,
    'wall_ts': wallTs,
    if (baseSeq != null) 'base_seq': baseSeq,
  };

  factory Op.fromJson(Map<String, Object?> json) => Op(
    seq: json['seq'] as int?,
    opId: json['op_id']! as String,
    boardId: json['board_id']! as String,
    entity: json['entity']! as String,
    entityId: json['entity_id']! as String,
    field: json['field']! as String,
    value: json['value'],
    deviceId: json['device_id']! as String,
    wallTs: json['wall_ts']! as int,
    baseSeq: json['base_seq'] as int?,
  );

  @override
  String toString() =>
      'Op(#${seq ?? '待发'} $entity/$entityId.$field = $value)';

  @override
  bool operator ==(Object other) => other is Op && other.opId == opId;

  @override
  int get hashCode => opId.hashCode;
}

/// 两条改动是不是**真并发**——双方都没见过对方就各自改了。
///
/// 光比 [Op.seq] 判断不出来：seq 只说谁的改动先到服务器，说不出做改动的
/// 人当时看没看见对方那条。所以要用 [Op.baseSeq]（产生时已知的最大序号）
/// 交叉比一次。
///
/// [aBaseSeq] 或 [bBaseSeq] 为 null 时返回 false——那是旧版本产生的 op，
/// 无从判断，此时**宁可漏报也不错报**：错报一次冲突会让用户白跑一趟去
/// 核对两份其实没冲突的内容，比漏报更烦人。
bool areConcurrent({
  required int? aSeq,
  required int? aBaseSeq,
  required int? bSeq,
  required int? bBaseSeq,
}) {
  if (aSeq == null || bSeq == null) return false;
  if (aBaseSeq == null || bBaseSeq == null) return false;
  return aBaseSeq < bSeq && bBaseSeq < aSeq;
}
