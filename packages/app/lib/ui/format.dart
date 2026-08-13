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

/// 把字节数说成人话。
String humanBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// 从 [text] 里截一段含 [query] 的片段，供搜索结果预览用。
///
/// 命中点常在正文中间，直接从头截会显示一段跟搜索词毫无关系的文字。
/// 所以往前留 [lead] 个字当上下文，前面截断了就加省略号。
String snippetAround(String text, String query, {int lead = 12, int span = 90}) {
  final flat = text.replaceAll('\n', ' ').trim();
  if (query.isEmpty || flat.length <= span) return flat;

  final at = flat.toLowerCase().indexOf(query.toLowerCase());
  // 命中在标题而不在正文时 at 是 -1，退回从头截。
  if (at < 0) return flat;

  final start = (at - lead).clamp(0, flat.length);
  final end = (start + span).clamp(0, flat.length);
  final cut = flat.substring(start, end);
  return start > 0 ? '…$cut' : cut;
}
