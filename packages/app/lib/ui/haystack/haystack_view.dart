import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database.dart';
import '../../providers.dart';
import '../card/card_detail_dialog.dart';
import '../format.dart';
import '../responsive.dart';
import '../theme/app_theme.dart';

/// 干草仓库 —— 每块看板自己的归档区。
///
/// 归档的卡片从画布和分组视图里**彻底消失**，只在这里能看到。身上的标签
/// 和画布位置都原样保留着，捞回去还是原来那张卡、原来那个位置。
class HaystackView extends ConsumerStatefulWidget {
  final String boardId;

  const HaystackView({super.key, required this.boardId});

  @override
  ConsumerState<HaystackView> createState() => _HaystackViewState();
}

class _HaystackViewState extends ConsumerState<HaystackView> {
  String _query = '';
  String? _filterTagId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final k = theme.kanban;

    final all = ref.watch(archivedCardsProvider(widget.boardId)).value ?? const [];
    final tags = ref.watch(boardTagsProvider(widget.boardId)).value ?? const [];
    final cardTags =
        ref.watch(cardTagMapProvider(widget.boardId)).value ??
        const <String, List<String>>{};
    final tagById = {for (final t in tags) t.id: t};

    final visible = all.where((c) {
      if (_filterTagId != null &&
          !(cardTags[c.id] ?? const []).contains(_filterTagId)) {
        return false;
      }
      if (_query.isEmpty) return true;
      return c.title.contains(_query) || c.body.contains(_query);
    }).toList();

    return Column(
      children: [
        _toolbar(theme, k, tags, all.length),
        Expanded(
          child: all.isEmpty
              ? const _EmptyHaystack()
              : visible.isEmpty
              ? Center(
                  child: Text(
                    '没有符合条件的卡片',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: k.cardBody,
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
                  itemCount: visible.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, i) => _ArchivedTile(
                    boardId: widget.boardId,
                    card: visible[i],
                    tags: [
                      for (final id in cardTags[visible[i].id] ?? const <String>[])
                        if (tagById[id] != null) tagById[id]!,
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _toolbar(
    ThemeData theme,
    KanbanColors k,
    List<TagRow> tags,
    int total,
  ) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: k.hairline)),
      ),
      // 窄屏一行放不下搜索框 + 筛选 + 清空，换行排。
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: isCompact(context)
                ? MediaQuery.sizeOf(context).width - 56
                : 240,
            child: TextField(
              onChanged: (v) => setState(() => _query = v.trim()),
              style: theme.textTheme.bodySmall,
              decoration: const InputDecoration(
                hintText: '在仓库里搜索',
                prefixIcon: Icon(Icons.search, size: 17),
                isDense: true,
              ),
            ),
          ),
          if (tags.isNotEmpty)
            PopupMenuButton<String?>(
              tooltip: '按标签筛选',
              onSelected: (v) => setState(() => _filterTagId = v),
              itemBuilder: (_) => [
                const PopupMenuItem(value: null, child: Text('全部标签')),
                const PopupMenuDivider(),
                for (final t in tags)
                  PopupMenuItem(value: t.id, child: Text(t.name)),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.filter_list, size: 15, color: k.cardBody),
                    const SizedBox(width: 5),
                    Text(
                      _filterTagId == null
                          ? '全部标签'
                          : tags
                                .firstWhere((t) => t.id == _filterTagId)
                                .name,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: k.cardBody,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (total > 0)
            TextButton.icon(
              onPressed: () => _confirmEmpty(total),
              icon: const Icon(Icons.delete_sweep_outlined, size: 17),
              label: const Text('清空全部卡片'),
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
            ),
        ],
      ),
    );
  }

  /// 清空仓库的强确认。
  ///
  /// 这是不可恢复的操作，所以要把数量说清楚，并且**不做点一下就没的按钮**。
  Future<void> _confirmEmpty(int count) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空干草仓库'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('将永久删除仓库里的 $count 张卡片，此操作不可恢复。'),
            const SizedBox(height: 10),
            Text(
              '画布上的卡片不受影响。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).kanban.cardBody,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text('删除这 $count 张'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    // 几百张卡片打包成一个事务；到 P2 也要打包成一条同步消息。
    final removed = await ref
        .read(repositoryProvider)
        .emptyHaystack(widget.boardId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已清空 $removed 张卡片'),
        behavior: SnackBarBehavior.floating,
        width: 300,
      ),
    );
  }
}

class _ArchivedTile extends ConsumerWidget {
  final String boardId;
  final CardRow card;
  final List<TagRow> tags;

  const _ArchivedTile({
    required this.boardId,
    required this.card,
    required this.tags,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final k = theme.kanban;

    return Material(
      color: k.cardSurface(card.color),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: () => showCardDetail(context, boardId, card.id),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: k.cardBorder),
          ),
          padding: const EdgeInsets.fromLTRB(15, 12, 10, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      card.title.isEmpty ? '未命名' : card.title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: card.title.isEmpty
                            ? k.cardBody.withValues(alpha: 0.6)
                            : k.cardTitle,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (card.body.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        card.body,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: k.cardBody,
                          height: 1.5,
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 5,
                      runSpacing: 5,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        for (final t in tags)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
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
                                fontSize: 10.5,
                              ),
                            ),
                          ),
                        Text(
                          '归档于 ${relativeTime(card.updatedAt)}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: k.cardBody.withValues(alpha: 0.75),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              TextButton.icon(
                onPressed: () => ref
                    .read(repositoryProvider)
                    .archiveCard(boardId, card.id, archived: false),
                icon: const Icon(Icons.unarchive_outlined, size: 16),
                label: const Text('捞回看板'),
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.primary,
                  visualDensity: VisualDensity.compact,
                ),
              ),
              IconButton(
                tooltip: '彻底删除这张卡片',
                iconSize: 17,
                onPressed: () => _confirmDelete(context, ref),
                icon: Icon(
                  Icons.delete_outline,
                  color: k.cardBody.withValues(alpha: 0.8),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('彻底删除'),
        content: Text(
          '「${card.title.isEmpty ? '未命名' : card.title}」将被永久删除，无法恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(repositoryProvider).deleteCard(boardId, card.id);
    }
  }
}

class _EmptyHaystack extends StatelessWidget {
  const _EmptyHaystack();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '仓库是空的',
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.kanban.cardTitle,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '卡片做完了又不想删，就收进这里。位置和标签都会留着，随时捞回去。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.kanban.cardBody,
            ),
          ),
        ],
      ),
    );
  }
}
