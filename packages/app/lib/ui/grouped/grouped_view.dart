import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../board/board_search.dart';
import '../../data/database.dart';
import '../../providers.dart';
import '../card/card_detail_dialog.dart';
import '../tags/card_tag_picker.dart';
import '../responsive.dart';
import '../theme/app_theme.dart';

/// 列内排序方式。
///
/// 这里不能手动拖，所以必须有个自动规则。
enum GroupSort {
  updated('最近修改'),
  created('创建时间'),
  position('画布位置'),
  title('标题');

  final String label;

  const GroupSort(this.label);
}

/// 分组视图 —— 按标签自动分列的**透视图**。
///
/// 看板里有多少个标签就有多少列，不需要挑；末尾固定一列「未分类」。
///
/// **卡片在这里不能拖。** 这不是阉割，是分工：画布是唯一的编辑主场，
/// 这里是俯瞰的地方。少了拖拽，也就不需要「拖到别的列 = 改标签」那套
/// 语义，以及列内的手动排序字段。
///
/// 但不能拖 ≠ 只读——点开能编辑、能改标签、能在列顶新建卡片。
class GroupedView extends ConsumerStatefulWidget {
  final String boardId;

  /// 板内搜索。这里是**过滤**而不是像画布那样淡化：
  /// 列表里位置不承载信息，留一堆灰条只会让人多滑几屏。
  final BoardSearch search;

  const GroupedView({
    super.key,
    required this.boardId,
    this.search = BoardSearch.none,
  });

  @override
  ConsumerState<GroupedView> createState() => _GroupedViewState();
}

class _GroupedViewState extends ConsumerState<GroupedView> {
  GroupSort _sort = GroupSort.updated;
  bool _showEmpty = false;

  final _pageController = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final k = theme.kanban;

    final cards = ref.watch(canvasCardsProvider(widget.boardId)).value ?? const [];
    final tags = ref.watch(boardTagsProvider(widget.boardId)).value ?? const [];
    final cardTags =
        ref.watch(cardTagMapProvider(widget.boardId)).value ??
        const <String, List<String>>{};
    final commentCounts =
        ref.watch(commentCountsProvider(widget.boardId)).value ?? const {};

    final compact = isCompact(context);
    final matched = widget.search.active
        ? cards.where(widget.search.matches).toList()
        : cards;
    final columns = _buildColumns(matched, tags, cardTags);
    final visible = _showEmpty
        ? columns
        : columns.where((c) => c.cards.isNotEmpty).toList();

    return Column(
      children: [
        _toolbar(theme, k, hiddenCount: columns.length - visible.length),
        if (compact && tags.isNotEmpty && visible.isNotEmpty)
          _ColumnTabs(
            columns: visible,
            current: _page.clamp(0, visible.length - 1),
            onTap: (i) => _pageController.animateToPage(
              i,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
            ),
          ),
        Expanded(
          child: tags.isEmpty
              ? _NoTagsHint(boardId: widget.boardId)
              : compact
              // 手机上整屏一列、左右滑动切换。横向滚一条窄柱在小屏上
              // 又难看又难点。
              ? PageView.builder(
                  controller: _pageController,
                  onPageChanged: (i) => setState(() => _page = i),
                  itemCount: visible.length,
                  itemBuilder: (context, i) => Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 18),
                    child: _Column(
                      boardId: widget.boardId,
                      column: visible[i],
                      cardTags: cardTags,
                      tagById: {for (final t in tags) t.id: t},
                      commentCounts: commentCounts,
                      showHeader: false,
                      fullWidth: true,
                    ),
                  ),
                )
              : ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 22),
                  itemCount: visible.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 14),
                  itemBuilder: (context, i) => _Column(
                    boardId: widget.boardId,
                    column: visible[i],
                    cardTags: cardTags,
                    tagById: {for (final t in tags) t.id: t},
                    commentCounts: commentCounts,
                  ),
                ),
        ),
      ],
    );
  }

  Widget _toolbar(ThemeData theme, KanbanColors k, {required int hiddenCount}) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: k.hairline)),
      ),
      child: Row(
        children: [
          if (!isCompact(context))
            Text(
              '卡片不能在这里拖动，摆位置去画布',
              style: theme.textTheme.labelSmall?.copyWith(
                color: k.cardBody.withValues(alpha: 0.75),
              ),
            ),
          const Spacer(),
          if (hiddenCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Text(
                '隐藏了 $hiddenCount 个空列',
                style: theme.textTheme.labelSmall?.copyWith(color: k.cardBody),
              ),
            ),
          TextButton.icon(
            onPressed: () => setState(() => _showEmpty = !_showEmpty),
            icon: Icon(
              _showEmpty ? Icons.visibility_off_outlined : Icons.visibility_outlined,
              size: 15,
            ),
            label: Text(_showEmpty ? '隐藏空列' : '显示空列'),
            style: TextButton.styleFrom(
              foregroundColor: k.cardBody,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
          ),
          const SizedBox(width: 8),
          PopupMenuButton<GroupSort>(
            tooltip: '列内排序方式',
            initialValue: _sort,
            onSelected: (s) => setState(() => _sort = s),
            itemBuilder: (_) => [
              for (final s in GroupSort.values)
                PopupMenuItem(value: s, child: Text(s.label)),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.sort, size: 15, color: k.cardBody),
                  const SizedBox(width: 5),
                  Text(
                    _sort.label,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: k.cardBody,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 把卡片分进各列。
  ///
  /// 一张卡片有多个标签时，会**在每个对应列里各出现一份**——是同一张卡，
  /// 改一处处处变。这样信息不丢，代价是同一张卡会看到多次，所以卡片上
  /// 会标出它还属于哪些列。
  List<_ColumnData> _buildColumns(
    List<CardRow> cards,
    List<TagRow> tags,
    Map<String, List<String>> cardTags,
  ) {
    final columns = [
      for (final tag in tags)
        _ColumnData(
          tag: tag,
          cards: _sorted(
            cards.where((c) => (cardTags[c.id] ?? const []).contains(tag.id)),
          ),
        ),
      _ColumnData(
        tag: null,
        cards: _sorted(
          cards.where((c) => (cardTags[c.id] ?? const []).isEmpty),
        ),
      ),
    ];
    return columns;
  }

  List<CardRow> _sorted(Iterable<CardRow> cards) {
    final list = cards.toList();
    list.sort(switch (_sort) {
      // 刚动过的排最上面，这是最常用的
      GroupSort.updated => (a, b) => b.updatedAt.compareTo(a.updatedAt),
      GroupSort.created => (a, b) => b.createdAt.compareTo(a.createdAt),
      // 保持和画布上的空间对应感：从上到下、从左到右
      GroupSort.position => (a, b) {
        final dy = a.y.compareTo(b.y);
        return dy != 0 ? dy : a.x.compareTo(b.x);
      },
      GroupSort.title => (a, b) => a.title.compareTo(b.title),
    });
    return list;
  }
}

class _ColumnData {
  /// null 表示「未分类」列。
  final TagRow? tag;
  final List<CardRow> cards;

  const _ColumnData({required this.tag, required this.cards});
}

class _Column extends ConsumerWidget {
  final String boardId;
  final _ColumnData column;
  final Map<String, List<String>> cardTags;
  final Map<String, TagRow> tagById;
  final Map<String, int> commentCounts;

  /// 手机上列名显示在顶部的标签条里，列自己就不用再画一遍标题。
  final bool showHeader;

  /// 整屏宽度（手机的翻页模式）而不是固定 286。
  final bool fullWidth;

  const _Column({
    required this.boardId,
    required this.column,
    required this.cardTags,
    required this.tagById,
    required this.commentCounts,
    this.showHeader = true,
    this.fullWidth = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final k = theme.kanban;
    final tag = column.tag;
    final accent = tag == null
        ? k.cardBody
        : k.accent(tag.color);

    return SizedBox(
      width: fullWidth ? double.infinity : 286,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showHeader) Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 0, 10),
            child: Row(
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: accent,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    tag?.name ?? '未分类',
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: tag == null ? k.cardBody : null,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${column.cards.length}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: k.cardBody,
                  ),
                ),
                const Spacer(),
                Tooltip(
                  message: tag == null
                      ? '新建一张不带标签的卡片'
                      : '新建卡片并打上「${tag.name}」',
                  child: InkWell(
                    onTap: () => _createCard(context, ref),
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(Icons.add, size: 17, color: k.cardBody),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: column.cards.isEmpty
                ? _EmptyColumn(accent: accent)
                : ListView.separated(
                    padding: EdgeInsets.zero,
                    itemCount: column.cards.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 9),
                    itemBuilder: (context, i) {
                      final card = column.cards[i];
                      // 这张卡还挂在哪些别的列上——同一张卡会在多列出现，
                      // 不标出来会让人以为是重复的卡片。
                      final others = [
                        for (final id in cardTags[card.id] ?? const <String>[])
                          if (id != tag?.id && tagById[id] != null)
                            tagById[id]!,
                      ];
                      return _GroupedCardTile(
                        boardId: boardId,
                        card: card,
                        otherTags: others,
                        commentCount: commentCounts[card.id] ?? 0,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _createCard(BuildContext context, WidgetRef ref) async {
    final repo = ref.read(repositoryProvider);
    final id = await repo.createCardBelowAll(
      boardId: boardId,
      tagId: column.tag?.id,
    );
    if (!context.mounted) return;
    // 新建后直接开详情：这里没有画布上那种"原地改标题"的位置感，
    // 弹窗才是自然的落点。
    await showCardDetail(context, boardId, id);
  }
}

class _EmptyColumn extends StatelessWidget {
  final Color accent;

  const _EmptyColumn({required this.accent});

  @override
  Widget build(BuildContext context) {
    final k = Theme.of(context).kanban;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: k.hairline),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Center(
        child: Text(
          '这一列还是空的',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: k.cardBody.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }
}

class _GroupedCardTile extends ConsumerWidget {
  final String boardId;
  final CardRow card;
  final List<TagRow> otherTags;
  final int commentCount;

  const _GroupedCardTile({
    required this.boardId,
    required this.card,
    required this.otherTags,
    required this.commentCount,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final k = theme.kanban;

    return Material(
      color: k.cardSurface(card.color),
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        onTap: () => showCardDetail(context, boardId, card.id),
        borderRadius: BorderRadius.circular(9),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: k.cardBorder),
          ),
          padding: const EdgeInsets.fromLTRB(11, 9, 7, 9),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      card.title.isEmpty ? '未命名' : card.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: card.title.isEmpty
                            ? k.cardBody.withValues(alpha: 0.6)
                            : k.cardTitle,
                        fontWeight: FontWeight.w600,
                        fontSize: 13.5,
                        height: 1.35,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 22,
                    height: 20,
                    child: PopupMenuButton<String>(
                      tooltip: '',
                      padding: EdgeInsets.zero,
                      iconSize: 15,
                      icon: Icon(
                        Icons.more_horiz,
                        color: k.cardBody.withValues(alpha: 0.7),
                      ),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'detail', child: Text('打开详情')),
                        PopupMenuItem(value: 'tags', child: Text('改标签')),
                        PopupMenuDivider(),
                        PopupMenuItem(value: 'archive', child: Text('收进干草仓库')),
                      ],
                      onSelected: (a) => _onMenu(context, ref, a),
                    ),
                  ),
                ],
              ),
              if (card.body.isNotEmpty) ...[
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Text(
                    card.body,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: k.cardBody,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
              if (otherTags.isNotEmpty || commentCount > 0) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          for (final t in otherTags)
                            Tooltip(
                              message: '这张卡片也在「${t.name}」列里',
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: k
                                      .accent(t.color)
                                      .withValues(alpha: k.isDark ? 0.22 : 0.16),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  t.name,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: k.accent(t.color),
                                    fontWeight: FontWeight.w600,
                                    fontSize: 10,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (commentCount > 0) ...[
                      Icon(
                        Icons.mode_comment_outlined,
                        size: 12,
                        color: k.cardBody.withValues(alpha: 0.75),
                      ),
                      const SizedBox(width: 3),
                      Text(
                        '$commentCount',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: k.cardBody.withValues(alpha: 0.75),
                          fontSize: 10.5,
                        ),
                      ),
                      const SizedBox(width: 4),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _onMenu(
    BuildContext context,
    WidgetRef ref,
    String action,
  ) async {
    switch (action) {
      case 'detail':
        await showCardDetail(context, boardId, card.id);
      case 'tags':
        await showCardTagPicker(context, ref, boardId, card.id);
      case 'archive':
        await ref.read(repositoryProvider).archiveCard(boardId, card.id);
    }
  }
}

class _NoTagsHint extends ConsumerWidget {
  final String boardId;

  const _NoTagsHint({required this.boardId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '这个看板还没有标签',
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.kanban.cardTitle,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '分组视图按标签分列。有多少标签就有多少列，不用挑。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.kanban.cardBody,
            ),
          ),
          const SizedBox(height: 18),
          Builder(
            builder: (context) => FilledButton.icon(
              onPressed: () => Scaffold.of(context).openEndDrawer(),
              icon: const Icon(Icons.label_outline, size: 17),
              label: const Text('管理标签'),
            ),
          ),
        ],
      ),
    );
  }
}

/// 手机上的列名标签条。
///
/// 翻页模式下每屏只看得见一列，没有这条就不知道自己在哪一列、
/// 也不知道总共有几列。
class _ColumnTabs extends StatelessWidget {
  final List<_ColumnData> columns;
  final int current;
  final ValueChanged<int> onTap;

  const _ColumnTabs({
    required this.columns,
    required this.current,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final k = theme.kanban;

    return Container(
      height: 42,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: k.hairline)),
      ),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        itemCount: columns.length,
        itemBuilder: (context, i) {
          final column = columns[i];
          final selected = i == current;
          final accent = column.tag == null
              ? k.cardBody
              : k.accent(column.tag!.color);

          return InkWell(
            onTap: () => onTap(i),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: selected ? accent : Colors.transparent,
                    width: 2,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    column.tag?.name ?? '未分类',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: selected ? null : k.cardBody,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${column.cards.length}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: k.cardBody,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
