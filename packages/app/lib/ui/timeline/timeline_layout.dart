/// 时间轴的几何计算。**全是纯函数**，「现在几点」由调用方传进来。
///
/// 单独一个文件是为了能测：日期到格子的映射错一格，界面上看不出来，
/// 但条会整体偏一天。
library;

import 'package:meta/meta.dart';

/// 一格多宽（逻辑像素）。
///
/// 36 是权衡出来的：一个月 30 格约 1080 像素，宽屏上一屏看得完，不用滚。
/// 按你 Excel 里那种一列 100 像素的排法，一个月就是 3000 像素，非滚不可。
const double kDayWidth = 36;

/// 一行多高，以及条本身多高。
const double kRowHeight = 34;
const double kBarHeight = 18;

/// 左边那列标题的宽度。
const double kTitleWidth = 180;
const double kTitleWidthCompact = 132;

/// 时间轴横跨的日期范围。
@immutable
class TimelineRange {
  /// 第一格是哪天（零点）。
  final DateTime firstDay;

  /// 一共多少格。
  final int dayCount;

  const TimelineRange({required this.firstDay, required this.dayCount});

  double get totalWidth => dayCount * kDayWidth;

  DateTime dayAt(int index) => addDays(firstDay, index);

  /// [day] 落在第几格。范围外会给出负数或越界的数，调用方自己判断。
  int indexOf(DateTime day) => daysBetween(firstDay, day);
}

/// 算出时间轴该从哪天画到哪天。
///
/// 一定包含「今天」：哪怕所有卡片都排在下个月，进来也得先看见今天在哪，
/// 否则没有参照点。
TimelineRange timelineRange({
  required Iterable<({int? start, int due})> cards,
  required DateTime now,
  int minDays = 21,
  int pad = 2,
}) {
  final today = dateOnly(now);
  var first = today;
  var last = today;

  for (final c in cards) {
    final due = dateOnly(DateTime.fromMillisecondsSinceEpoch(c.due));
    if (due.isBefore(first)) first = due;
    if (due.isAfter(last)) last = due;

    final start = c.start;
    if (start == null) continue;
    final s = dateOnly(DateTime.fromMillisecondsSinceEpoch(start));
    if (s.isBefore(first)) first = s;
    // 开始晚于截止的卡片按「只有截止」画，所以它的开始日不该把范围撑开。
    if (s.isAfter(last) && start <= c.due) last = s;
  }

  first = addDays(first, -pad);
  last = addDays(last, pad);

  var count = daysBetween(first, last) + 1;
  // 卡片挤在几天里时也别画成一小截——空荡荡的表头比滚动条更难看懂。
  if (count < minDays) count = minDays;

  return TimelineRange(firstDay: first, dayCount: count);
}

/// 一根条在时间轴上的位置，单位是「格」。
@immutable
class TimelineBar {
  /// 从第几格开始。
  final int fromIndex;

  /// 占几格，至少 1。
  final int spanDays;

  /// 开始时间是推算的，不是用户填的。画成浅一号／虚线边，
  /// 表示「这根条的左端不作准」。
  final bool inferredStart;

  const TimelineBar({
    required this.fromIndex,
    required this.spanDays,
    required this.inferredStart,
  });

  double get left => fromIndex * kDayWidth;
  double get width => spanDays * kDayWidth;
}

/// 算出一张卡片的条画在哪。
///
/// 没填开始时间时，条从**今天**画到截止——长度就是「还剩多少时间」，
/// 每天打开都会短一点。已经超时的卡片今天在截止日之后，那就退化成
/// 截止日上的一格，「超时几天」由卡片上的徽章去说。
///
/// 开始晚于截止时按「没填开始」处理：那是个明显填错的状态，
/// 硬画会得到一根倒着长的条。
TimelineBar barFor({
  required int? start,
  required int due,
  required TimelineRange range,
  required DateTime now,
}) {
  final today = dateOnly(now);
  final dueDay = dateOnly(DateTime.fromMillisecondsSinceEpoch(due));

  final usable = start != null && start <= due;
  final startDay = usable
      ? dateOnly(DateTime.fromMillisecondsSinceEpoch(start))
      : (today.isBefore(dueDay) ? today : dueDay);

  final from = range.indexOf(startDay);
  final span = daysBetween(startDay, dueDay) + 1;

  return TimelineBar(
    fromIndex: from,
    // 同一天开始同一天结束的条不能是 0 宽，否则整根看不见。
    spanDays: span < 1 ? 1 : span,
    inferredStart: !usable,
  );
}

/// 进来时横向滚到哪儿，好让「今天」落在靠左但不贴边的位置。
///
/// 不定位的话，某张卡片截止在两年后会把范围拉得很长，一进来看到的是
/// 一片空白。留出 [leadDays] 格的过去，能看见刚过期的东西。
double initialScrollOffset(TimelineRange range, DateTime now, {int leadDays = 3}) {
  final offset = (range.indexOf(dateOnly(now)) - leadDays) * kDayWidth;
  return offset < 0 ? 0 : offset;
}

/// 抹掉时分秒，只留年月日。
DateTime dateOnly(DateTime t) => DateTime(t.year, t.month, t.day);

/// 往后数 [days] 天。
///
/// **不能用 `add(Duration(days: days))`**：Duration 是死的 24 小时，而
/// 实行夏令时的地方有 23 小时和 25 小时的日子，加出来会落到前一天的
/// 23:00，整条时间轴从那天起全偏一格。
/// 给 `DateTime` 的 day 传超范围的数，Dart 会自己进位到下个月，这才是
/// 真正的「日历加法」。
DateTime addDays(DateTime day, int days) =>
    DateTime(day.year, day.month, day.day + days);

/// 两个日子之间隔了几个自然日。
///
/// 先搬到 UTC 再相减：UTC 的一天永远是 24 小时，本地时间的一天不是。
/// 拿两个本地零点相减，跨夏令时那天会得到 23 小时，`inDays` 截断成 0。
int daysBetween(DateTime from, DateTime to) {
  final a = DateTime.utc(from.year, from.month, from.day);
  final b = DateTime.utc(to.year, to.month, to.day);
  return b.difference(a).inDays;
}
