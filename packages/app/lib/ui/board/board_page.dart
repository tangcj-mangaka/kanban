import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../canvas/canvas_view.dart';
import '../grouped/grouped_view.dart';
import '../haystack/haystack_view.dart';
import '../tags/tag_manager_panel.dart';
import '../responsive.dart';
import '../theme/app_theme.dart';

enum BoardView {
  canvas('画布', Icons.dashboard_outlined),
  grouped('分组', Icons.view_column_outlined),
  haystack('干草仓库', Icons.inventory_2_outlined);

  final String label;
  final IconData icon;

  const BoardView(this.label, this.icon);
}

/// 一块看板的外壳：顶栏 + 三种视图之间切换。
///
/// 三个视图看的是**同一批卡片**，只是呈现方式不同：
/// - 画布：自由摆放，可拖，是唯一的编辑主场
/// - 分组：按标签自动分列的透视图，不可拖
/// - 干草仓库：归档区，从前两个视图里彻底消失的卡片
class BoardPage extends ConsumerStatefulWidget {
  final String boardId;

  /// 进来时停在哪个视图。
  ///
  /// 不给的话按屏幕宽度定：窄屏默认进分组视图。手机上自由画布很难用——
  /// 看不到全局、拖动精度差，而分组视图是竖着滑的列表，天然适合小屏。
  /// 摆位置是电脑上干的事。
  final BoardView? initialView;

  const BoardPage({super.key, required this.boardId, this.initialView});

  @override
  ConsumerState<BoardPage> createState() => _BoardPageState();
}

class _BoardPageState extends ConsumerState<BoardPage> {
  BoardView? _view;

  BoardView _defaultView(BuildContext context) =>
      widget.initialView ??
      (isCompact(context) ? BoardView.grouped : BoardView.canvas);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final k = theme.kanban;
    final view = _view ??= _defaultView(context);
    final compact = isCompact(context);
    final board = ref.watch(boardProvider(widget.boardId)).value;
    final cards = ref.watch(canvasCardsProvider(widget.boardId)).value ?? const [];
    final archived =
        ref.watch(archivedCardsProvider(widget.boardId)).value ?? const [];

    return Scaffold(
      backgroundColor: k.canvas,
      endDrawer: TagManagerPanel(boardId: widget.boardId),
      body: SafeArea(
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 16, 8),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: k.hairline)),
              ),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '返回看板列表',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back, size: 20),
                  ),
                  const SizedBox(width: 4),
                  if (board != null) ...[
                    Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: k.accent(board.color),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 9),
                    Flexible(
                      child: Text(
                        board.name.isEmpty ? '未命名看板' : board.name,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                  if (!compact) ...[
                    const SizedBox(width: 12),
                    Text(
                      cards.isEmpty ? '空看板' : '${cards.length} 张',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: k.cardBody,
                      ),
                    ),
                  ],
                  const Spacer(),
                  _ViewSwitcher(
                    current: view,
                    archivedCount: archived.length,
                    compact: compact,
                    onChanged: (v) => setState(() => _view = v),
                  ),
                  const SizedBox(width: 8),
                  Builder(
                    // 窄屏放不下文字标签，只留图标。
                    builder: (context) => compact
                        ? IconButton(
                            tooltip: '标签',
                            onPressed: () => Scaffold.of(context).openEndDrawer(),
                            icon: const Icon(Icons.label_outline, size: 19),
                          )
                        : TextButton.icon(
                            onPressed: () => Scaffold.of(context).openEndDrawer(),
                            icon: const Icon(Icons.label_outline, size: 16),
                            label: const Text('标签'),
                            style: TextButton.styleFrom(
                              foregroundColor: k.cardBody,
                              padding: const EdgeInsets.symmetric(horizontal: 10),
                            ),
                          ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: switch (view) {
                BoardView.canvas => CanvasView(boardId: widget.boardId),
                BoardView.grouped => GroupedView(boardId: widget.boardId),
                BoardView.haystack => HaystackView(boardId: widget.boardId),
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ViewSwitcher extends StatelessWidget {
  final BoardView current;
  final int archivedCount;

  /// 窄屏只显示图标——三个中文标签在手机上放不下。
  final bool compact;

  final ValueChanged<BoardView> onChanged;

  const _ViewSwitcher({
    required this.current,
    required this.archivedCount,
    required this.compact,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final k = theme.kanban;

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: k.hairline.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final view in BoardView.values)
            _SwitcherTab(
              view: view,
              selected: view == current,
              compact: compact,
              // 仓库里有东西时标出条数，省得每次都要点进去看有没有。
              badge: view == BoardView.haystack && archivedCount > 0
                  ? '$archivedCount'
                  : null,
              onTap: () => onChanged(view),
            ),
        ],
      ),
    );
  }
}

class _SwitcherTab extends StatelessWidget {
  final BoardView view;
  final bool selected;
  final bool compact;
  final String? badge;
  final VoidCallback onTap;

  const _SwitcherTab({
    required this.view,
    required this.selected,
    required this.compact,
    required this.badge,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final k = theme.kanban;

    return Tooltip(
      message: view.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 130),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          decoration: BoxDecoration(
            color: selected ? theme.colorScheme.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: k.isDark ? 0.3 : 0.07),
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                view.icon,
                size: 15,
                color: selected ? theme.colorScheme.primary : k.cardBody,
              ),
              if (!compact) ...[
                const SizedBox(width: 5),
                Text(
                  view.label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: selected ? theme.colorScheme.primary : k.cardBody,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ],
              if (badge != null) ...[
                const SizedBox(width: 5),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: k.cardBody.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    badge!,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: k.cardBody,
                      fontSize: 10,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
