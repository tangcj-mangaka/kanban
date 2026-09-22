/// 截止时间的判定与格式化。**全是纯函数**，「现在几点」一律由调用方传进来。
///
/// 不在这里读 `DateTime.now()`：超时判定的边界（正好到期的那一毫秒、
/// 跨天、跨年）只有把时间当参数才测得了。
library;

/// 还差几个**自然日**到期算「临近」。
///
/// 定 3 天而不是 24 小时，是因为个人看板不是每天开：周五下班前看一眼，
/// 24 小时的窗口会让下周一到期的事还是灰的，等你周一开机它已经红了。
/// 3 天正好能在周末之前把下周初的事亮出来。
///
/// **必须按自然日算，不能拿 `Duration(days: 3)` 去比时间差。** 周五 17:00
/// 到周一 23:59 是 79 小时，按 72 小时的窗口根本框不进来——上面那个理由
/// 就落空了。而且徽章上写的「还剩 3 天」也是按自然日数的，两处口径不一致
/// 会出现「写着还剩 3 天，颜色却是不着急」的卡片。
const int kDueSoonDays = 3;

/// 一张卡片在「截止」这件事上的状态。
enum DeadlineStatus {
  /// 没设截止时间。
  none,

  /// 设了，但还早。
  later,

  /// 快到了（[kDueSoonDays] 个自然日以内），橙色。
  soon,

  /// 已经超时，红色。
  overdue,

  /// 做完了。**做完就不再报警**——否则看板上会长期挂着一片红色的
  /// 「迟到但已完成」，警告色就失效了。
  done,

  /// 已收进干草仓库。归档的卡片不参与催办。
  archived,
}

extension DeadlineStatusX on DeadlineStatus {
  /// 要不要用警告色（红/橙）画出来。
  bool get isAlarming =>
      this == DeadlineStatus.overdue || this == DeadlineStatus.soon;
}

/// 判断一张卡片的截止状态。
///
/// 判定顺序是有讲究的：归档 → 完成 → 超时 → 临近。前两个是「这件事不用
/// 再催了」，必须压过时间本身。
DeadlineStatus deadlineStatus({
  required int? due,
  required bool done,
  required bool archived,
  required DateTime now,
}) {
  if (due == null) return DeadlineStatus.none;
  if (archived) return DeadlineStatus.archived;
  if (done) return DeadlineStatus.done;

  final at = DateTime.fromMillisecondsSinceEpoch(due);
  // 「到期那一刻」算超时：设成 23:59 的意思是 23:59 之前做完。
  if (!at.isAfter(now)) return DeadlineStatus.overdue;
  if (_calendarDaysBetween(now, at) <= kDueSoonDays) return DeadlineStatus.soon;
  return DeadlineStatus.later;
}

/// 卡片上那枚小徽章的文字：超时 3 天 / 还剩 2 天 / 今天 18:00 / 9月25日。
///
/// 按**自然日**算天数，不是按 24 小时整除：今晚 23:00 和明早 8:00 之间
/// 只隔 9 小时，但人会说「明天」，说「还剩 0 天」没人看得懂。
String dueLabel(int due, DateTime now) {
  final at = DateTime.fromMillisecondsSinceEpoch(due);
  final days = _calendarDaysBetween(now, at);

  if (!at.isAfter(now)) {
    final over = -days;
    if (over == 0) return '今天到期';
    if (over == 1) return '超时 1 天';
    return '超时 $over 天';
  }

  if (days == 0) return '今天 ${_hhmm(at)}';
  if (days == 1) return '明天 ${_hhmm(at)}';
  if (days <= 7) return '还剩 $days 天';
  return formatDueDate(due, now);
}

/// 完整的日期显示：9月25日 23:59，跨年才带年份。
String formatDueDate(int due, DateTime now) {
  final at = DateTime.fromMillisecondsSinceEpoch(due);
  final ymd = at.year == now.year
      ? '${at.month}月${at.day}日'
      : '${at.year}年${at.month}月${at.day}日';
  return '$ymd ${_hhmm(at)}';
}

/// 只要日期那一截，时间轴的表头用。
String formatDayLabel(DateTime day, {bool withYear = false}) =>
    withYear ? '${day.year}年${day.month}月${day.day}日' : '${day.month}月${day.day}日';

String _hhmm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// 跨了几个自然日。今天到明天是 1，哪怕中间只隔一小时。
///
/// 先搬到 UTC 再相减：UTC 的一天永远是 24 小时，本地时间的一天不是
/// ——拿两个本地零点相减，跨夏令时那天只有 23 小时，`inDays` 会截断成 0。
int _calendarDaysBetween(DateTime from, DateTime to) {
  final a = DateTime.utc(from.year, from.month, from.day);
  final b = DateTime.utc(to.year, to.month, to.day);
  return b.difference(a).inDays;
}

/// 把时间输入框里的字解析成「当天的第几秒」，解析不了返回 null。
///
/// 认 `23:59`、`23:59:30`、`9:5`，中文冒号也认——中文输入法下打出
/// `23：59` 是常事，为这个报一次错纯属添堵。
int? parseDayTime(String raw) {
  final text = raw.trim().replaceAll('：', ':');
  if (text.isEmpty) return null;

  final parts = text.split(':');
  if (parts.length < 2 || parts.length > 3) return null;

  final nums = <int>[];
  for (final p in parts) {
    final n = int.tryParse(p.trim());
    if (n == null || n < 0) return null;
    nums.add(n);
  }

  final [h, m, ...rest] = nums;
  final s = rest.isEmpty ? 0 : rest.first;
  if (h > 23 || m > 59 || s > 59) return null;
  return h * 3600 + m * 60 + s;
}

/// 把「当天的第几秒」显示成 `23:59` 或 `23:59:30`。
///
/// 秒是 0 就不显示——日常的截止时间都是整分钟，多挂一个 `:00` 只是噪音。
String formatDayTime(int secondsOfDay) {
  final h = secondsOfDay ~/ 3600;
  final m = (secondsOfDay % 3600) ~/ 60;
  final s = secondsOfDay % 60;
  final hm =
      '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  return s == 0 ? hm : '$hm:${s.toString().padLeft(2, '0')}';
}

/// 从一个时间戳里取出「当天的第几秒」，回填进时间输入框用。
int dayTimeOf(int millis) {
  final t = DateTime.fromMillisecondsSinceEpoch(millis);
  return t.hour * 3600 + t.minute * 60 + t.second;
}

/// 日期 + 当天的第几秒 → 时间戳。
DateTime combineDayTime(DateTime day, int secondsOfDay) => DateTime(
  day.year,
  day.month,
  day.day,
  secondsOfDay ~/ 3600,
  (secondsOfDay % 3600) ~/ 60,
  secondsOfDay % 60,
);

/// 截止时间的默认钟点：当天 23:59。
const int kDefaultDueSeconds = 23 * 3600 + 59 * 60;

/// 开始时间的默认钟点：当天 00:00。
const int kDefaultStartSeconds = 0;

/// 快捷按钮：今天 / 明天 / 本周五 / 下周一。
///
/// 九成的截止日期就是这四个之一，点一下比翻日历快得多。
/// 「本周五」如果已经过了（今天是周六），就顺延到下周五——按字面给一个
/// 过去的日期，用户还得自己发现并改掉。
List<({String label, DateTime day})> quickDays(DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  return [
    (label: '今天', day: today),
    (label: '明天', day: _addDays(today, 1)),
    (label: '本周五', day: _nextWeekday(today, DateTime.friday)),
    (label: '下周一', day: _nextWeekday(today, DateTime.monday, skipToday: true)),
  ];
}

/// 下一个星期 [weekday]。
///
/// Dart 的 `%` 对正除数永远返回非负数，所以今天已经过了那一天时，
/// delta 会自动绕到下一周——「本周五」在周六点出来就是下周五，正是想要的。
DateTime _nextWeekday(DateTime from, int weekday, {bool skipToday = false}) {
  var delta = (weekday - from.weekday) % 7;
  if (delta == 0 && skipToday) delta = 7;
  return _addDays(from, delta);
}

/// 日历意义上的加天数。
///
/// 不用 `add(Duration(days: n))`——Duration 是死的 24 小时，夏令时地区
/// 会把结果甩到前一天的 23:00。给 day 传超范围的数让 Dart 自己进位，
/// 才是真正的日期加法。
DateTime _addDays(DateTime day, int days) =>
    DateTime(day.year, day.month, day.day + days);
