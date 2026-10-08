/// 解析 Trello 的「导出为 JSON」文件。**纯函数，不碰数据库。**
///
/// 单独一层是为了能拿真实导出文件做测试：这个格式里有好几个坑只有看过
/// 真文件才知道（见下面各处注释），凭想象写必错。
library;

import 'dart:convert';

import 'package:meta/meta.dart';

/// 一块 Trello 看板。
@immutable
class TrelloBoard {
  final String name;
  final List<TrelloList> lists;
  final List<TrelloLabel> labels;
  final List<TrelloCard> cards;

  const TrelloBoard({
    required this.name,
    required this.lists,
    required this.labels,
    required this.cards,
  });

  /// 真的装着卡片的列表，按 Trello 里的顺序。
  ///
  /// 导出文件里常年留着一堆空列表（归档过的、建了没用的）。照单全收会在
  /// 驴看板里凭空多出十几个永远空着的标签。
  List<TrelloList> get usedLists {
    final counts = <String, int>{};
    for (final c in cards) {
      counts[c.listId] = (counts[c.listId] ?? 0) + 1;
    }
    return [
      for (final l in lists)
        if ((counts[l.id] ?? 0) > 0) l,
    ];
  }

  /// 真的被用在卡片上的标签，按使用次数从多到少。
  List<TrelloLabel> get usedLabels {
    final counts = labelCounts;
    final used = [
      for (final l in labels)
        if ((counts[l.id] ?? 0) > 0) l,
    ];
    used.sort((a, b) => (counts[b.id] ?? 0).compareTo(counts[a.id] ?? 0));
    return used;
  }

  /// 每个标签用在了几张卡片上。
  Map<String, int> get labelCounts {
    final counts = <String, int>{};
    for (final c in cards) {
      for (final id in c.labelIds) {
        counts[id] = (counts[id] ?? 0) + 1;
      }
    }
    return counts;
  }
}

@immutable
class TrelloList {
  final String id;
  final String name;

  /// Trello 里被归档的列表。里面可能还有卡片。
  final bool closed;

  final double pos;

  const TrelloList({
    required this.id,
    required this.name,
    required this.closed,
    required this.pos,
  });
}

@immutable
class TrelloLabel {
  final String id;

  /// 可能是空字符串——Trello 允许只有颜色没有名字的标签。
  final String name;

  /// Trello 的色名：green、yellow、sky…… 新版导出可能带 `_dark` 之类的后缀。
  final String color;

  const TrelloLabel({
    required this.id,
    required this.name,
    required this.color,
  });

  String get displayName => name.isEmpty ? '（$color）' : name;
}

@immutable
class TrelloCard {
  final String id;
  final String name;
  final String desc;
  final String listId;
  final List<String> labelIds;

  /// 已归档的卡片。
  final bool closed;

  /// 截止时间和开始时间，毫秒时间戳。
  final int? due;
  final int? start;

  /// 截止日期被打了勾。
  ///
  /// **只在真有 [due] 时才有意义。** 真实导出里有大量 `dueComplete: true`
  /// 却 `due: null` 的卡片（这份文件里 418 张中有 99 张）——那是改来改去
  /// 留下的残渣。解析时已经把这种情况归零，别再拿它当完成标记用。
  final bool dueComplete;

  final double pos;

  /// 卡片上的评论，按时间从早到晚。
  final List<TrelloComment> comments;

  /// 清单里的勾选项，已经转成 Markdown 的 `- [x]` 行。
  final List<String> checklistLines;

  /// 附件的名字。**文件本身不在导出文件里**，只有指向 trello.com 的链接，
  /// 私有看板还要带令牌才下得动。
  final List<String> attachmentNames;

  const TrelloCard({
    required this.id,
    required this.name,
    required this.desc,
    required this.listId,
    required this.labelIds,
    required this.closed,
    required this.due,
    required this.start,
    required this.dueComplete,
    required this.pos,
    required this.comments,
    required this.checklistLines,
    required this.attachmentNames,
  });
}

@immutable
class TrelloComment {
  final String text;
  final int createdAt;
  final String author;

  const TrelloComment({
    required this.text,
    required this.createdAt,
    required this.author,
  });
}

/// 解析失败时抛这个，带一句人话。
class TrelloParseException implements Exception {
  final String message;
  const TrelloParseException(this.message);
  @override
  String toString() => message;
}

/// 解析一份 Trello 导出的 JSON 文本。
TrelloBoard parseTrelloExport(String jsonText) {
  final Object? decoded;
  try {
    decoded = jsonDecode(jsonText);
  } on FormatException catch (e) {
    throw TrelloParseException('这不是一个合法的 JSON 文件：${e.message}');
  }

  if (decoded is! Map<String, dynamic>) {
    throw TrelloParseException('文件最外层不是一块看板，确认导出的是「看板」而不是别的东西');
  }
  if (decoded['cards'] is! List || decoded['lists'] is! List) {
    throw TrelloParseException('文件里没有 cards 或 lists，这多半不是 Trello 的看板导出');
  }

  final lists = [
    for (final raw in decoded['lists'] as List)
      if (raw is Map<String, dynamic>)
        TrelloList(
          id: '${raw['id']}',
          name: '${raw['name'] ?? ''}',
          closed: raw['closed'] == true,
          pos: _toDouble(raw['pos']),
        ),
  ]..sort((a, b) => a.pos.compareTo(b.pos));

  final labels = [
    for (final raw in decoded['labels'] as List? ?? const [])
      if (raw is Map<String, dynamic>)
        TrelloLabel(
          id: '${raw['id']}',
          name: '${raw['name'] ?? ''}',
          color: '${raw['color'] ?? ''}',
        ),
  ];

  final comments = _commentsByCard(decoded['actions']);
  final checklists = _checklistLinesByCard(decoded['checklists']);

  final cards = [
    for (final raw in decoded['cards'] as List)
      if (raw is Map<String, dynamic>) _parseCard(raw, comments, checklists),
  ]..sort((a, b) => a.pos.compareTo(b.pos));

  return TrelloBoard(
    name: '${decoded['name'] ?? '从 Trello 导入'}',
    lists: lists,
    labels: labels,
    cards: cards,
  );
}

TrelloCard _parseCard(
  Map<String, dynamic> raw,
  Map<String, List<TrelloComment>> comments,
  Map<String, List<String>> checklists,
) {
  final id = '${raw['id']}';
  final due = _toMillis(raw['due']);

  return TrelloCard(
    id: id,
    name: '${raw['name'] ?? ''}',
    desc: '${raw['desc'] ?? ''}',
    listId: '${raw['idList']}',
    labelIds: [
      for (final l in raw['idLabels'] as List? ?? const []) '$l',
    ],
    closed: raw['closed'] == true,
    due: due,
    start: _toMillis(raw['start']),
    // 没有截止日期就没有「按时完成」可言，见 [TrelloCard.dueComplete]。
    dueComplete: due != null && raw['dueComplete'] == true,
    pos: _toDouble(raw['pos']),
    comments: comments[id] ?? const [],
    checklistLines: checklists[id] ?? const [],
    attachmentNames: [
      for (final a in raw['attachments'] as List? ?? const [])
        if (a is Map<String, dynamic>) '${a['name'] ?? ''}',
    ],
  );
}

/// 从 actions 里挑出评论，按卡片归组。
///
/// 评论不是独立的一段，而是埋在操作流水里的 `commentCard`。
/// **导出只给最近 1000 条操作**，所以年头久的评论根本不在文件里——
/// 这是 Trello 那头的限制，导入这边无能为力。
Map<String, List<TrelloComment>> _commentsByCard(Object? actions) {
  final out = <String, List<TrelloComment>>{};
  if (actions is! List) return out;

  for (final raw in actions) {
    if (raw is! Map<String, dynamic>) continue;
    if (raw['type'] != 'commentCard') continue;

    final data = raw['data'];
    if (data is! Map<String, dynamic>) continue;
    final card = data['card'];
    if (card is! Map<String, dynamic>) continue;

    final text = '${data['text'] ?? ''}';
    if (text.isEmpty) continue;

    final member = raw['memberCreator'];
    out.putIfAbsent('${card['id']}', () => []).add(
      TrelloComment(
        text: text,
        createdAt: _toMillis(raw['date']) ?? 0,
        author: member is Map<String, dynamic>
            ? '${member['fullName'] ?? member['username'] ?? ''}'
            : '',
      ),
    );
  }

  for (final list in out.values) {
    list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }
  return out;
}

/// 把清单转成 Markdown 的勾选行，附到卡片正文后面。
///
/// 驴看板没有「清单」这个结构，但正文就是 Markdown，`- [x]` 是现成的表达。
/// 空清单直接丢掉——真实文件里 42 个清单只有 1 个有内容，剩下全是空壳，
/// 照搬会在 41 张卡片的正文里加一行孤零零的标题。
Map<String, List<String>> _checklistLinesByCard(Object? checklists) {
  final out = <String, List<String>>{};
  if (checklists is! List) return out;

  for (final raw in checklists) {
    if (raw is! Map<String, dynamic>) continue;
    final items = raw['checkItems'];
    if (items is! List || items.isEmpty) continue;

    final lines = <String>[];
    final name = '${raw['name'] ?? ''}';
    if (name.isNotEmpty) lines.add('**$name**');

    final sorted = [
      for (final i in items)
        if (i is Map<String, dynamic>) i,
    ]..sort((a, b) => _toDouble(a['pos']).compareTo(_toDouble(b['pos'])));

    for (final item in sorted) {
      final mark = item['state'] == 'complete' ? 'x' : ' ';
      lines.add('- [$mark] ${item['name'] ?? ''}');
    }

    out.putIfAbsent('${raw['idCard']}', () => []).addAll(lines);
  }
  return out;
}

/// Trello 的时间是 ISO8601 的 UTC 串（`2025-02-27T16:00:00.000Z`）。
int? _toMillis(Object? value) {
  if (value == null) return null;
  final text = '$value';
  if (text.isEmpty) return null;
  return DateTime.tryParse(text)?.millisecondsSinceEpoch;
}

double _toDouble(Object? value) => switch (value) {
  final num n => n.toDouble(),
  // Trello 的 pos 偶尔是 "bottom" / "top" 这种字符串。
  'top' => 0,
  'bottom' => double.maxFinite,
  _ => double.tryParse('$value') ?? 0,
};

/// Trello 的色名 → 驴看板色板的 key。
///
/// 新版导出的色名可能带深浅后缀（`green_dark`、`yellow_light`），所以先切掉
/// 下划线后面那截。认不出来的一律给灰色，不报错——配色不对用户随手能改，
/// 为这个让整个导入失败不值得。
String trelloColorToSwatch(String trelloColor) {
  final base = trelloColor.split('_').first.toLowerCase();
  return switch (base) {
    'green' => 'green',
    'yellow' => 'yellow',
    'orange' => 'orange',
    'red' => 'red',
    'purple' => 'purple',
    'blue' => 'blue',
    // Trello 的 sky 是偏青的浅蓝，色板里 teal 最接近。
    'sky' => 'teal',
    'lime' => 'lime',
    'pink' => 'pink',
    'black' => 'gray',
    _ => 'gray',
  };
}
