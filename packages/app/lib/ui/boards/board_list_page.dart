import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database.dart';
import '../../data/repository.dart';
import '../../providers.dart';
import '../format.dart';
import '../theme/app_theme.dart';
import '../board/board_page.dart';
import 'board_dialogs.dart';

/// 看板列表页 —— 应用入口。
class BoardListPage extends ConsumerStatefulWidget {
  const BoardListPage({super.key});

  @override
  ConsumerState<BoardListPage> createState() => _BoardListPageState();
}

class _BoardListPageState extends ConsumerState<BoardListPage> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(boardSummariesProvider);

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(
              onSearch: (q) => setState(() => _query = q.trim()),
              onCreate: _createBoard,
            ),
            Expanded(
              child: async.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => _ErrorState(error: e),
                data: (boards) {
                  final visible = _query.isEmpty
                      ? boards
                      : boards
                            .where((b) => b.board.name.contains(_query))
                            .toList();

                  if (boards.isEmpty) return _EmptyState(onCreate: _createBoard);
                  if (visible.isEmpty) return _NoMatchState(query: _query);
                  return _BoardGrid(boards: visible);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createBoard() async {
    final name = await promptName(context, title: '新建看板');
    if (name == null) return;
    await ref.read(repositoryProvider).createBoard(name: name);
  }
}

// ---------------------------------------------------------------------------

class _Header extends ConsumerWidget {
  final ValueChanged<String> onSearch;
  final VoidCallback onCreate;

  const _Header({required this.onSearch, required this.onCreate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final mode = ref.watch(themeModeProvider);

    return Container(
      padding: const EdgeInsets.fromLTRB(28, 22, 28, 18),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.kanban.hairline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '驴看板',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(width: 14),
              const _ConnectionChip(),
              const Spacer(),
              IconButton(
                tooltip: switch (mode) {
                  ThemeMode.system => '跟随系统',
                  ThemeMode.light => '浅色',
                  ThemeMode.dark => '深色',
                },
                onPressed: () =>
                    ref.read(themeModeProvider.notifier).cycle(),
                icon: Icon(switch (mode) {
                  ThemeMode.system => Icons.brightness_auto_outlined,
                  ThemeMode.light => Icons.light_mode_outlined,
                  ThemeMode.dark => Icons.dark_mode_outlined,
                }),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: onCreate,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('新建看板'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: 340,
            child: TextField(
              onChanged: onSearch,
              decoration: const InputDecoration(
                hintText: '搜索看板',
                prefixIcon: Icon(Icons.search, size: 20),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 服务端连接状态。
///
/// P1 没有同步，这里恒为「本地模式」。位置先占住——用户任何时候都该
/// 一眼看出自己现在是不是离线在用。
class _ConnectionChip extends StatelessWidget {
  const _ConnectionChip();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: theme.kanban.hairline.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: theme.kanban.cardBody,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '本地模式',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.kanban.cardBody,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _BoardGrid extends StatelessWidget {
  final List<BoardSummary> boards;

  const _BoardGrid({required this.boards});

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(28),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 260,
        childAspectRatio: 1.75,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: boards.length,
      itemBuilder: (context, i) => _BoardTile(summary: boards[i]),
    );
  }
}

/// 看板方块。
///
/// 底色直接用该看板的封面色，画的就是卡片在画布上的样子——列表页顺带
/// 成了配色预览，不用另做一套视觉。
class _BoardTile extends ConsumerStatefulWidget {
  final BoardSummary summary;

  const _BoardTile({required this.summary});

  @override
  ConsumerState<_BoardTile> createState() => _BoardTileState();
}

class _BoardTileState extends ConsumerState<_BoardTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final k = theme.kanban;
    final board = widget.summary.board;
    final surface = k.cardSurface(board.color);
    final accent = k.accent(board.color);

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: k.cardBorder),
          boxShadow: _hover
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: k.isDark ? 0.4 : 0.12),
                    blurRadius: 14,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _openBoard(context),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(15, 14, 9, 13),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        margin: const EdgeInsets.only(top: 6, right: 8),
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: accent,
                          shape: BoxShape.circle,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          board.name.isEmpty ? '未命名看板' : board.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: k.cardTitle,
                            fontWeight: FontWeight.w600,
                            height: 1.35,
                          ),
                        ),
                      ),
                      AnimatedOpacity(
                        duration: const Duration(milliseconds: 120),
                        opacity: _hover ? 1 : 0,
                        child: _BoardMenu(board: board),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: _TagPreview(boardId: board.id),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Text(
                      widget.summary.cardCount == 0
                          ? '空看板'
                          : '${widget.summary.cardCount} 张卡片',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: k.cardBody,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Text(
                      relativeTime(widget.summary.lastUpdated),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: k.cardBody.withValues(alpha: 0.75),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _openBoard(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BoardPage(boardId: widget.summary.board.id),
      ),
    );
  }
}

/// 看板方块中间的标签预览。
///
/// 标签是这块看板的分类骨架，一眼扫过去就知道里面装的是什么。
/// 比留一片空白有用得多。
class _TagPreview extends ConsumerWidget {
  final String boardId;

  const _TagPreview({required this.boardId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final k = theme.kanban;
    final tags = ref.watch(boardTagsProvider(boardId)).value ?? const [];

    if (tags.isEmpty) {
      return Align(
        alignment: Alignment.topLeft,
        child: Text(
          '没有标签',
          style: theme.textTheme.labelSmall?.copyWith(
            color: k.cardBody.withValues(alpha: 0.55),
          ),
        ),
      );
    }

    // 空间有限，最多摆 4 个，剩下的用「+N」交代。
    const maxShown = 4;
    final shown = tags.take(maxShown).toList();
    final rest = tags.length - shown.length;

    return Align(
      alignment: Alignment.topLeft,
      child: Wrap(
        spacing: 5,
        runSpacing: 5,
        children: [
          for (final tag in shown)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: k.accent(tag.color).withValues(alpha: k.isDark ? 0.22 : 0.16),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                tag.name,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: k.accent(tag.color),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          if (rest > 0)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '+$rest',
                style: theme.textTheme.labelSmall?.copyWith(color: k.cardBody),
              ),
            ),
        ],
      ),
    );
  }
}

class _BoardMenu extends ConsumerWidget {
  final BoardRow board;

  const _BoardMenu({required this.board});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      width: 30,
      height: 30,
      child: PopupMenuButton<String>(
        tooltip: '更多',
        padding: EdgeInsets.zero,
        iconSize: 18,
        icon: Icon(
          Icons.more_horiz,
          color: Theme.of(context).kanban.cardBody,
        ),
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'rename', child: Text('重命名')),
          PopupMenuItem(value: 'color', child: Text('改封面色')),
          PopupMenuDivider(),
          PopupMenuItem(value: 'delete', child: Text('删除看板')),
        ],
        onSelected: (action) => _handle(context, ref, action),
      ),
    );
  }

  Future<void> _handle(BuildContext context, WidgetRef ref, String action) async {
    final repo = ref.read(repositoryProvider);
    switch (action) {
      case 'rename':
        final name = await promptName(
          context,
          title: '重命名看板',
          initial: board.name,
        );
        if (name != null) await repo.renameBoard(board.id, name);
      case 'color':
        final key = await pickSwatch(context, current: board.color);
        if (key != null) await repo.setBoardColor(board.id, key);
      case 'delete':
        final ok = await confirmDeleteBoard(context, board.name);
        if (ok) await repo.deleteBoard(board.id);
    }
  }
}

// ---------------------------------------------------------------------------

class _EmptyState extends StatelessWidget {
  final VoidCallback onCreate;

  const _EmptyState({required this.onCreate});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '还没有看板',
            style: theme.textTheme.titleMedium?.copyWith(color: theme.kanban.cardTitle),
          ),
          const SizedBox(height: 6),
          Text(
            '每个看板是一块自由画布，卡片随便摆',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.kanban.cardBody),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: onCreate,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('建第一个看板'),
          ),
        ],
      ),
    );
  }
}

class _NoMatchState extends StatelessWidget {
  final String query;

  const _NoMatchState({required this.query});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Text(
        '没有名字含「$query」的看板',
        style: theme.textTheme.bodyMedium?.copyWith(color: theme.kanban.cardBody),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final Object error;

  const _ErrorState({required this.error});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('读取数据失败', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '$error',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.kanban.cardBody,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
