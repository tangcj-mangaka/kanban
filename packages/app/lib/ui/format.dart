/// 把时间戳说成人话：刚刚、23 分钟前、昨天、8月3日。
///
/// 超过一周就直接给日期——「9 天前」这种说法读者还得在脑子里换算一次。
String relativeTime(int? millis) {
  if (millis == null || millis == 0) return '还没有内容';

  final then = DateTime.fromMillisecondsSinceEpoch(millis);
  final now = DateTime.now();
  final diff = now.difference(then);

  if (diff.inSeconds < 60) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';

  final today = DateTime(now.year, now.month, now.day);
  final thatDay = DateTime(then.year, then.month, then.day);
  final days = today.difference(thatDay).inDays;

  if (days == 1) return '昨天';
  if (days < 7) return '$days 天前';
  if (then.year == now.year) return '${then.month}月${then.day}日';
  return '${then.year}年${then.month}月${then.day}日';
}
