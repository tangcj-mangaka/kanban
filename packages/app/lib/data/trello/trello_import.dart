/// 把解析好的 Trello 看板写进驴看板。
///
/// 走的全是 [Repository] 的正常方法，产生的 op 和用户手点出来的一模一样
/// ——导进来的卡片不是什么特殊品种，同步、冲突、改动记录一视同仁。
library;

import 'package:shared/shared.dart';

import '../repository.dart';
import 'trello_export.dart';

/// 导入时的几个选择。
///
/// 做成选项而不是写死，是因为**每块 Trello 板的用法都不一样**：有人拿
/// 列表当流程阶段（待办/进行中/完成），有人拿列表当功能模块、用标签表示
/// 状态。猜错了导进来就是一团乱麻，不如当场让用户指认。
class TrelloImportOptions {
  /// 哪个标签表示「做完了」。这些卡片会被打勾，而不是建成一个标签。
  final String? doneLabelId;

  /// 哪个标签表示「废弃」。这些卡片直接收进干草仓库。
  final String? archiveLabelId;

  /// 剩下的标签怎么处理：
  /// - true：变成**卡片颜色**。分组视图就只剩下列表变成的那些标签，
  ///   干干净净，状态靠颜色一眼扫，和 Trello 里看标签颜色是一个习惯。
  /// - false：也变成**标签**。文字留住了，但分组视图里会多出一批状态列，
  ///   同一张卡在模块列和状态列各出现一次。
  final bool labelsAsColor;

  final bool importComments;
  final bool importDates;

  const TrelloImportOptions({
    this.doneLabelId,
    this.archiveLabelId,
    this.labelsAsColor = true,
    this.importComments = true,
    this.importDates = true,
  });
}

/// 导完之后的账目，说给用户听。
class TrelloImportResult {
  final String boardId;
  final String boardName;
  final int cards;
  final int tags;
  final int comments;
  final int done;
  final int archived;
  final int dated;

  /// 有附件但没导进来的卡片数。附件文件不在导出文件里，只有链接。
  final int cardsWithAttachments;

  const TrelloImportResult({
    required this.boardId,
    required this.boardName,
    required this.cards,
    required this.tags,
    required this.comments,
    required this.done,
    required this.archived,
    required this.dated,
    required this.cardsWithAttachments,
  });
}

/// 卡片在画布上的摆法：一个列表一纵列。
const double _columnWidth = 300;
const double _rowHeight = 132;
const double _margin = 40;

/// 导入一块看板。
///
/// [onProgress] 每写完一张卡片回调一次，给进度条用——400 多张卡片要跑几秒，
/// 界面不能干愣着。
Future<TrelloImportResult> importTrelloBoard(
  Repository repo,
  TrelloBoard board, {
  TrelloImportOptions options = const TrelloImportOptions(),
  void Function(int done, int total)? onProgress,
}) async {
  final lists = board.usedLists;
  final cards = board.cards;

  // 状态标签：排除掉被指认为「完成」和「废弃」的那两个，剩下的才需要安置。
  final statusLabels = [
    for (final l in board.usedLabels)
      if (l.id != options.doneLabelId && l.id != options.archiveLabelId) l,
  ];

  final boardId = await repo.createBoard(name: board.name);

  // 列表 → 标签。这是整个导入最值钱的一步：驴看板的分组视图按标签自动
  // 分列，所以导完之后分组视图会长得跟原来的 Trello 板几乎一样。
  //
  // Trello 的列表没有颜色，这里按色板轮着给，好让各列一眼区分得开。
  final tagOfList = <String, String>{};
  for (var i = 0; i < lists.length; i++) {
    tagOfList[lists[i].id] = await repo.createTag(
      boardId: boardId,
      name: lists[i].name,
      colorKey: kSwatchKeys[i % kSwatchKeys.length],
    );
  }

  // 状态标签 → 标签（只在用户选了「保留文字」时）。
  final tagOfLabel = <String, String>{};
  if (!options.labelsAsColor) {
    for (final label in statusLabels) {
      tagOfLabel[label.id] = await repo.createTag(
        boardId: boardId,
        name: label.displayName,
        colorKey: trelloColorToSwatch(label.color),
      );
    }
  }

  final colorOfLabel = {
    for (final l in statusLabels) l.id: trelloColorToSwatch(l.color),
  };

  // 卡片按所属列表分组，好一列一列地摆。
  final byList = <String, List<TrelloCard>>{};
  for (final c in cards) {
    byList.putIfAbsent(c.listId, () => []).add(c);
  }

  var written = 0;
  var comments = 0;
  var done = 0;
  var archived = 0;
  var dated = 0;
  var withAttachments = 0;

  for (var col = 0; col < lists.length; col++) {
    final listCards = byList[lists[col].id] ?? const <TrelloCard>[];

    for (var row = 0; row < listCards.length; row++) {
      final card = listCards[row];

      final isDone =
          (options.doneLabelId != null &&
              card.labelIds.contains(options.doneLabelId)) ||
          (options.importDates && card.dueComplete);
      final isArchived =
          card.closed ||
          (options.archiveLabelId != null &&
              card.labelIds.contains(options.archiveLabelId));

      // 卡片颜色取第一个状态标签的颜色。一张卡片最多只有一种底色，
      // 两个标签的卡片只能认第一个——这是「标签变颜色」这条路的代价。
      String? colorKey;
      if (options.labelsAsColor) {
        for (final id in card.labelIds) {
          final swatch = colorOfLabel[id];
          if (swatch != null) {
            colorKey = swatch;
            break;
          }
        }
      }

      final cardId = await repo.createCard(
        boardId: boardId,
        x: _margin + col * _columnWidth,
        y: _margin + row * _rowHeight,
        title: card.name,
        colorKey: colorKey,
      );

      final body = _bodyOf(card);
      if (body.isNotEmpty) {
        await repo.setCardField(boardId, cardId, CardF.body, body, touch: false);
      }
      if (isDone) {
        await repo.toggleCardDone(boardId, cardId, true);
        done++;
      }
      if (isArchived) {
        await repo.archiveCard(boardId, cardId);
        archived++;
      }
      if (options.importDates) {
        if (card.due != null) {
          await repo.setCardField(boardId, cardId, CardF.due, card.due,
              touch: false);
          dated++;
        }
        if (card.start != null) {
          await repo.setCardField(boardId, cardId, CardF.start, card.start,
              touch: false);
        }
      }

      final listTag = tagOfList[card.listId];
      if (listTag != null) {
        await repo.setCardTag(boardId, cardId, listTag, on: true);
      }
      for (final labelId in card.labelIds) {
        final tagId = tagOfLabel[labelId];
        if (tagId != null) {
          await repo.setCardTag(boardId, cardId, tagId, on: true);
        }
      }

      if (options.importComments) {
        for (final c in card.comments) {
          await repo.addComment(
            boardId,
            cardId,
            c.text,
            // 保留原始时间，否则几年的讨论会全挤成「刚刚」。
            createdAt: c.createdAt == 0 ? null : c.createdAt,
          );
          comments++;
        }
      }

      if (card.attachmentNames.isNotEmpty) withAttachments++;

      written++;
      onProgress?.call(written, cards.length);
    }
  }

  return TrelloImportResult(
    boardId: boardId,
    boardName: board.name,
    cards: written,
    tags: tagOfList.length + tagOfLabel.length,
    comments: comments,
    done: done,
    archived: archived,
    dated: dated,
    cardsWithAttachments: withAttachments,
  );
}

/// 卡片正文：描述 + 清单 + 附件名单。
///
/// 附件只留个名单当线索。文件本身不在导出文件里（Trello 只给链接，私有看板
/// 还要令牌），默默丢掉的话，用户回头翻到这张卡只会觉得「我记得这儿有张图」。
String _bodyOf(TrelloCard card) {
  final parts = <String>[];
  if (card.desc.isNotEmpty) parts.add(card.desc);
  if (card.checklistLines.isNotEmpty) parts.add(card.checklistLines.join('\n'));
  if (card.attachmentNames.isNotEmpty) {
    parts.add(
      '> 这张卡片在 Trello 上有附件，导出文件里没有附件本身：\n'
      '${card.attachmentNames.map((n) => '> - $n').join('\n')}',
    );
  }
  return parts.join('\n\n');
}
