import 'package:flutter/foundation.dart';

import '../../data/database.dart';

/// 板内搜索的状态。
///
/// 和列表页的全局搜索**故意不共用一套机制**：全局搜索要跨看板查数据库，
/// 板内搜索的候选集就是画布上那几十张卡片，已经在内存里了。为了几十条
/// 字符串比较再往数据库跑一趟，只会换来一次多余的异步和一帧闪烁。
///
/// 这也顺带解决了一处语义差异：全局搜索**包含**归档卡片（不然归档等于
/// 弄丢），而板内搜索只搜当前视图里看得见的卡片。
@immutable
class BoardSearch {
  final String query;

  /// 当前定位到的那张卡片。画布会把视角挪过去。
  final String? focusCardId;

  /// 每按一次「上一个/下一个」就 +1。
  ///
  /// 光看 [focusCardId] 不够：只有一张命中卡片时反复按，id 一直没变，
  /// 画布就不知道该重新定位——用户会以为按钮坏了。
  final int focusToken;

  const BoardSearch({this.query = '', this.focusCardId, this.focusToken = 0});

  static const none = BoardSearch();

  bool get active => query.isNotEmpty;

  /// 大小写不敏感的子串匹配，和全局搜索的口径保持一致。
  bool matches(CardRow card) {
    if (!active) return true;
    final q = query.toLowerCase();
    return card.title.toLowerCase().contains(q) ||
        card.body.toLowerCase().contains(q);
  }

  BoardSearch withQuery(String q) =>
      BoardSearch(query: q, focusCardId: null, focusToken: focusToken);

  BoardSearch focusOn(String cardId) => BoardSearch(
    query: query,
    focusCardId: cardId,
    focusToken: focusToken + 1,
  );

  @override
  bool operator ==(Object other) =>
      other is BoardSearch &&
      other.query == query &&
      other.focusCardId == focusCardId &&
      other.focusToken == focusToken;

  @override
  int get hashCode => Object.hash(query, focusCardId, focusToken);
}

/// 「上一个 / 下一个」落在第几项。
///
/// 抽成纯函数是因为这段索引算术有三个容易写错的角：还没定位过
/// （[current] 为 -1）、从头往回按、从末尾往后按。放在 State 里就只能靠
/// 点界面来验，而这三种情况恰好都不好点。
///
/// [current] 是当前项的下标，-1 表示还没定位过；[delta] 只用 +1 / -1。
/// 返回 -1 表示无处可去（一项都没有）。
int nextMatchIndex(int current, int count, int delta) {
  if (count <= 0) return -1;
  // 还没定位过时，往后按从第一项开始，往回按从最后一项开始——
  // 而不是都从第一项开始，那样「上一个」的第一下会很反直觉。
  if (current < 0) return delta > 0 ? 0 : count - 1;
  return (current + delta) % count;
}
