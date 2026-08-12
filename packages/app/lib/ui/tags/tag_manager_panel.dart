import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared/shared.dart';

import '../../data/database.dart';
import '../../providers.dart';
import '../boards/board_dialogs.dart';
import '../theme/app_theme.dart';

/// 标签管理面板。
///
/// 这里的**顺序就是分组视图里列的顺序**，所以拖动排序是个实际功能，
/// 不是装饰。
class TagManagerPanel extends ConsumerWidget {
  final String boardId;

  const TagManagerPanel({super.key, required this.boardId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final k = theme.kanban;
    final tags = ref.watch(boardTagsProvider(boardId)).value ?? const [];
    final cardTags =
        ref.watch(cardTagMapProvider(boardId)).value ??
        const <String, List<String>>{};

    // 每个标签身上挂着多少张卡片——删除时要如实告诉用户影响面。
    final counts = <String, int>{};
    for (final tagIds in cardTags.values) {
      for (final id in tagIds) {
        counts[id] = (counts[id] ?? 0) + 1;
      }
    }

    return Drawer(
      width: 320,
      backgroundColor: theme.colorScheme.surface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 10),
              child: Row(
                children: [
                  Text(
                    '标签',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, size: 19),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                '标签只属于这个看板，不跨板共用。这里的顺序就是分组视图里列的顺序。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: k.cardBody,
                  height: 1.5,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: tags.isEmpty
                  ? Center(
                      child: Text(
                        '还没有标签',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: k.cardBody,
                        ),
                      ),
                    )
                  : ReorderableListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemCount: tags.length,
                      onReorderItem: (from, to) =>
                          _reorder(ref, tags, from, to),
                      itemBuilder: (context, i) => _TagTile(
                        key: ValueKey(tags[i].id),
                        boardId: boardId,
                        tag: tags[i],
                        cardCount: counts[tags[i].id] ?? 0,
                      ),
                    ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: _NewTagField(boardId: boardId, existingCount: tags.length),
            ),
          ],
        ),
      ),
    );
  }

  /// 拖动落位。
  ///
  /// 只改被拖那一个标签的 sortOrder，取前后邻居的中点。其他标签一个都不动，
  /// 所以两台设备同时拖不同的标签也不会互相覆盖。
  void _reorder(WidgetRef ref, List<TagRow> tags, int from, int to) {
    // onReorderItem 给的 to 已经是「把该项移走之后」的下标，不用再自己补偿。
    if (to == from) return;

    final rest = [...tags]..removeAt(from);
    final before = to > 0 ? rest[to - 1].sortOrder : null;
    final after = to < rest.length ? rest[to].sortOrder : null;

    ref.read(repositoryProvider).reorderTag(
          boardId,
          tags[from].id,
          before: before,
          after: after,
        );
  }
}

class _TagTile extends ConsumerWidget {
  final String boardId;
  final TagRow tag;
  final int cardCount;

  const _TagTile({
    super.key,
    required this.boardId,
    required this.tag,
    required this.cardCount,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final k = theme.kanban;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: Colors.transparent,
        child: ListTile(
          dense: true,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          leading: Tooltip(
            message: '改颜色',
            child: InkWell(
              onTap: () async {
                final key = await pickSwatch(context, current: tag.color);
                if (key != null) {
                  await ref
                      .read(repositoryProvider)
                      .setTagColor(boardId, tag.id, key);
                }
              },
              borderRadius: BorderRadius.circular(20),
              child: Padding(
                padding: const EdgeInsets.all(5),
                child: Container(
                  width: 13,
                  height: 13,
                  decoration: BoxDecoration(
                    color: k.accent(tag.color),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          ),
          title: Text(
            tag.name,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
          subtitle: Text(
            cardCount == 0 ? '没有卡片' : '$cardCount 张卡片',
            style: theme.textTheme.labelSmall?.copyWith(color: k.cardBody),
          ),
          trailing: PopupMenuButton<String>(
            tooltip: '更多',
            iconSize: 17,
            icon: Icon(Icons.more_horiz, color: k.cardBody),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rename', child: Text('重命名')),
              PopupMenuItem(value: 'color', child: Text('改颜色')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'delete', child: Text('删除标签')),
            ],
            onSelected: (action) => _onMenu(context, ref, action),
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
    final repo = ref.read(repositoryProvider);
    switch (action) {
      case 'rename':
        final name = await promptName(
          context,
          title: '重命名标签',
          initial: tag.name,
        );
        if (name != null) await repo.renameTag(boardId, tag.id, name);
      case 'color':
        final key = await pickSwatch(context, current: tag.color);
        if (key != null) await repo.setTagColor(boardId, tag.id, key);
      case 'delete':
        if (!context.mounted) return;
        final ok = await _confirmDelete(context, tag.name, cardCount);
        if (ok) await repo.deleteTag(boardId, tag.id);
    }
  }
}

/// 删除标签的确认。
///
/// 必须说清楚「卡片会保留」——标签是分类手段，不是卡片的容器，
/// 用户看到"删除"两个字时最怕的就是内容一起没了。
Future<bool> _confirmDelete(
  BuildContext context,
  String name,
  int cardCount,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('删除标签'),
      content: Text(
        cardCount == 0
            ? '删除标签「$name」。'
            : '删除标签「$name」。$cardCount 张卡片将失去这个标签，'
                  '变成「未分类」——卡片本身一张都不会删。',
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
  return ok ?? false;
}

class _NewTagField extends ConsumerStatefulWidget {
  final String boardId;
  final int existingCount;

  const _NewTagField({required this.boardId, required this.existingCount});

  @override
  ConsumerState<_NewTagField> createState() => _NewTagFieldState();
}

class _NewTagFieldState extends ConsumerState<_NewTagField> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _controller,
            decoration: const InputDecoration(hintText: '新标签名称'),
            onSubmitted: (_) => _create(),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filled(
          tooltip: '新建标签',
          onPressed: _create,
          icon: const Icon(Icons.add, size: 19),
        ),
      ],
    );
  }

  Future<void> _create() async {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    _controller.clear();
    // 颜色按现有数量往下轮，省得每建一个都要挑色，也避免一板子全同色。
    await ref.read(repositoryProvider).createTag(
          boardId: widget.boardId,
          name: name,
          colorKey: kSwatchKeys[widget.existingCount % kSwatchKeys.length],
        );
  }
}
