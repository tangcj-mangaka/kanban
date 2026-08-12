import 'package:drift/drift.dart';

/// op log —— 整个系统的真相源，只增不改。
///
/// 下面所有的物化表都是这张表回放出来的读视图。
@DataClassName('OpRow')
class Ops extends Table {
  /// 客户端生成的 UUID。重连补发时同一条 op 可能被送达两次，靠它去重。
  TextColumn get opId => text()();

  /// 服务端分配的全局递增序号。本地新产生、尚未同步的 op 为 null。
  IntColumn get seq => integer().nullable()();

  /// 本地插入序号，永远有值。
  ///
  /// 用于在 [seq] 还没下来之前给本地 op 定序——本地优先架构下，
  /// 离线期间产生的 op 也必须能立刻生效并正确排序。
  IntColumn get localSeq => integer()();

  TextColumn get boardId => text()();
  TextColumn get entity => text()();
  TextColumn get entityId => text()();
  TextColumn get field => text()();

  /// JSON 编码后的字段值。
  ///
  /// 非空列：op 的 value 为 null 时存的是 JSON 字面量 `null`，
  /// 表示「把这个字段置空」，与「没有这条 op」是两回事。
  TextColumn get valueJson => text()();

  TextColumn get deviceId => text()();

  /// 客户端本地时间（毫秒），只用于显示，不参与排序。
  IntColumn get wallTs => integer()();

  @override
  Set<Column> get primaryKey => {opId};
}

/// 每个字段当前由哪条 op 说了算。
///
/// 应用一条新 op 前先查这里：只有当新 op 的定序键更大时才覆盖，
/// 这样乱序到达的 op 也能得到正确结果。
@DataClassName('FieldSeqRow')
class FieldSeqs extends Table {
  TextColumn get entityId => text()();
  TextColumn get field => text()();

  /// 当前生效的那条 op 的 seq（未确认则为 null）与 localSeq。
  IntColumn get seq => integer().nullable()();
  IntColumn get localSeq => integer()();

  @override
  Set<Column> get primaryKey => {entityId, field};
}

// ---------------------------------------------------------------------------
// 物化表：由 op 回放生成，供 UI 查询。
//
// 除主键外每一列都有默认值——op 是一条一条到的，某个字段的 op 还没来时，
// 这一行必须已经能以合法状态存在。
// ---------------------------------------------------------------------------

@DataClassName('BoardRow')
class Boards extends Table {
  TextColumn get id => text()();
  TextColumn get name => text().withDefault(const Constant(''))();

  /// 列表页的封面色，存色板 key（如 `"teal"`）而非十六进制值。
  TextColumn get color => text().nullable()();

  RealColumn get sortOrder => real().withDefault(const Constant(0))();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('TagRow')
class Tags extends Table {
  TextColumn get id => text()();
  TextColumn get boardId => text()();
  TextColumn get name => text().withDefault(const Constant(''))();
  TextColumn get color => text().withDefault(const Constant('gray'))();

  /// 决定分组视图里列的顺序。小数序。
  RealColumn get sortOrder => real().withDefault(const Constant(0))();

  BoolColumn get deleted => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('CardRow')
class Cards extends Table {
  TextColumn get id => text()();
  TextColumn get boardId => text()();
  TextColumn get title => text().withDefault(const Constant(''))();

  /// Markdown 源文。存的就是纯字符串，同步时不需要任何特殊处理。
  TextColumn get body => text().withDefault(const Constant(''))();

  /// 色板 key，null 表示无色卡片。
  TextColumn get color => text().nullable()();

  /// 画布坐标。无限画布，不设边界。
  RealColumn get x => real().withDefault(const Constant(0))();
  RealColumn get y => real().withDefault(const Constant(0))();

  /// 卡片宽度可拖调，高度按内容自适应。
  RealColumn get width => real().withDefault(const Constant(260))();

  /// 重叠时的层级，小数序。点击或拖动会把卡片提到最前。
  RealColumn get z => real().withDefault(const Constant(0))();

  /// 画布上是否折叠。折叠态只显示标题和正文前两行。
  BoolColumn get collapsed => boolean().withDefault(const Constant(true))();

  /// 是否已收进干草仓库。归档的卡片从画布和分组视图里彻底消失。
  BoolColumn get archived => boolean().withDefault(const Constant(false))();

  IntColumn get createdAt => integer().withDefault(const Constant(0))();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

/// 卡片与标签的关系。
///
/// 每条关系是一条**独立记录**，各自 LWW、各自墓碑。绝不能把整个标签集合
/// 当成卡片的一个字段来覆盖——那样「A 设备加标签 a、B 设备同时加标签 b」
/// 会因为后写覆盖而丢掉一个。
///
/// [id] 由 `cardId:tagId` 拼成，是确定性的：两台设备各自打同一个标签时
/// 产生的是同一条记录的两个 op，天然幂等。
@DataClassName('CardTagRow')
class CardTags extends Table {
  TextColumn get id => text()();
  TextColumn get cardId => text()();
  TextColumn get tagId => text()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('AttachmentRow')
class Attachments extends Table {
  TextColumn get id => text()();
  TextColumn get cardId => text().withDefault(const Constant(''))();

  /// 文件内容的 SHA-256，同时也是服务端的存储文件名。天然去重。
  TextColumn get hash => text().withDefault(const Constant(''))();

  /// 缩略图的 hash，仅图片有。上传时由客户端生成，服务端不装图像库。
  TextColumn get thumbHash => text().nullable()();

  TextColumn get filename => text().withDefault(const Constant(''))();
  IntColumn get size => integer().withDefault(const Constant(0))();
  TextColumn get mime => text().withDefault(const Constant(''))();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

/// 评论只增不改：发表后不能编辑，想改就删了重发。
///
/// 因此评论天然无冲突——只有「创建」和「删除」两种 op，不存在两端
/// 同时修改同一条评论的情况。
@DataClassName('CommentRow')
class Comments extends Table {
  TextColumn get id => text()();
  TextColumn get cardId => text().withDefault(const Constant(''))();
  TextColumn get body => text().withDefault(const Constant(''))();
  TextColumn get deviceId => text().withDefault(const Constant(''))();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}
