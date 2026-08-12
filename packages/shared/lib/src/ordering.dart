/// 小数序（fractional index）。
///
/// 卡片的 z 层级、标签顺序、看板顺序都用小数序，而不是整数下标。
///
/// 用整数下标的话，往中间插一个元素要把后面所有元素的下标全改一遍——
/// 一次拖动产生几十条 op，两台设备同时拖就会互相覆盖，冲突面大到
/// 字段级 LWW 兜不住。小数序把「插到 A 和 B 中间」变成只改一条记录的
/// 一个字段：A=1.0、B=2.0，插进去就是 1.5。
library;

/// 在 [before] 和 [after] 之间取一个新序号。
///
/// 两端都为 null 表示列表为空；只有一端为 null 表示插在头部或尾部。
double fractionalIndex({double? before, double? after}) {
  if (before == null && after == null) return 0;
  if (before == null) return after! - 1;
  if (after == null) return before + 1;
  return before + (after - before) / 2;
}

/// 相邻两个序号靠得比这还近时，double 的精度已经不够再往中间插了。
///
/// 反复往同一个缝里插入会让间距指数级缩小，约 50 次之后就会触到这条线。
const double kOrderEpsilon = 1e-9;

/// 判断 [a] 和 [b] 之间是否还插得进新元素。
///
/// 返回 true 说明该组需要重新均匀分配一次序号（见 [rebalance]）。
/// 重排是本地静默进行的，不需要用户感知。
bool needsRebalance(double a, double b) => (b - a).abs() < kOrderEpsilon;

/// 把一组序号重新均匀分配成 0, 1, 2, …，保持原有先后顺序。
///
/// 只在 [needsRebalance] 报警时调用。这会改动整组元素，产生一批 op，
/// 所以要当成批量操作打包发送，不能一条一条发。
List<double> rebalance(int count) =>
    List<double>.generate(count, (i) => i.toDouble());

/// 卡片与标签的关系 ID，由两端 ID 直接拼出。
///
/// 必须是确定性的：两台设备各自给同一张卡片打上同一个标签时，产生的是
/// **同一条记录**的两个 op（天然幂等），而不是两条重复的关系记录。
///
/// 用拼接而不是哈希，是为了出问题时能直接从 ID 读出这条关系连的是谁和谁。
String cardTagId(String cardId, String tagId) => '$cardId:$tagId';
