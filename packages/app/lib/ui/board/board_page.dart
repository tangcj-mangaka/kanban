import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database.dart';
import '../../providers.dart';
import '../canvas/canvas_view.dart';
import '../card/card_detail_dialog.dart';
import '../grouped/grouped_view.dart';
import '../haystack/haystack_view.dart';
import '../tags/tag_manager_panel.dart';
import '../responsive.dart';
import '../theme/app_theme.dart';
import '../theme/haystack_icon.dart';
import 'board_search.dart';

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

  /// 进来后立刻打开这张卡片的详情。
  ///
  /// 全局搜索点结果时用：用户搜的是卡片，落地就该看到那张卡片，
  /// 而不是被丢在一块板上自己找。归档的卡片也照样能这样打开。
  final String? openCardId;

  /// 进来时就展开搜索栏并填好这个词。
  ///
  /// 给截图验证用；正常打开是 null。
  final String? initialSearch;

  /// 进来后自动整理一次。给截图验证用。
  final bool autoTidy;

  /// 配合 [initialSearch]：进来就定位到第一个命中。
  ///
  /// 也是给截图验证用的——「定位」这个动作要点按钮才会发生。
  final bool focusFirstMatch;

  const BoardPage({
    super.key,
    required this.boardId,
    this.initialView,
    this.openCardId,
    this.initialSearch,
    this.focusFirstMatch = false,
    this.autoTidy = false,
  });

  @override
  ConsumerState<BoardPage> createState() => _BoardPageState();
}

class _BoardPageState extends ConsumerState<BoardPage> {
  BoardView? _view;
  BoardSearch _search = BoardSearch.none;
  bool _searchBarOpen = false;
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();

    final q = widget.initialSearch;
    if (q != null && q.isNotEmpty) {
      _searchBarOpen = true;
      _search = BoardSearch(query: q);
      _searchController.text = q;
      if (widget.focusFirstMatch) {
        // 卡片是异步流出来的，第一帧多半还是空的，要等流吐出来才能定位。
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          for (var i = 0; i < 20 && mounted; i++) {
            final cards =
                ref.read(canvasCardsProvider(widget.boardId)).value ?? const [];
            if (cards.any(_search.matches)) {
              _stepMatch(1);
              return;
            }
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        });
      }
    }

    final cardId = widget.openCardId;
    if (cardId == null) return;
    // 得等这一帧画完：此刻页面还没进 Navigator，直接弹对话框会挂在旧路由上。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) showCardDetail(context, widget.boardId, cardId);
    });
  }

  void _toggleSearchBar() {
    setState(() {
      _searchBarOpen = !_searchBarOpen;
      if (_searchBarOpen) {
        _searchFocus.requestFocus();
      } else {
        // 关掉搜索栏就得把高亮一起撤掉，否则画布会一直半暗着，
        // 而用户已经没有任何界面能看出为什么。
        _searchController.clear();
        _search = BoardSearch.none;
      }
    });
  }

  void _closeSearch() {
    if (_searchBarOpen) _toggleSearchBar();
  }

  /// 在命中的卡片之间循环走位。
  void _stepMatch(int delta) {
    final cards =
        ref.read(canvasCardsProvider(widget.boardId)).value ?? const [];
    final matches = cards.where(_search.matches).toList();
    if (matches.isEmpty) return;

    final next = nextMatchIndex(
      matches.indexWhere((c) => c.id == _search.focusCardId),
      matches.length,
      delta,
    );
    if (next < 0) return;
    setState(() => _search = _search.focusOn(matches[next].id));
  }

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
    // 命中列表按卡片在画布上的自然顺序算，「下一个」才有稳定的走法。
    final matches = _search.active
        ? cards.where(_search.matches).toList()
        : const <CardRow>[];

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
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: '在这块板里搜索',
                    onPressed: _toggleSearchBar,
                    isSelected: _searchBarOpen,
                    icon: const Icon(Icons.search, size: 19),
                  ),
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
            if (_searchBarOpen)
              _BoardSearchBar(
                controller: _searchController,
                focusNode: _searchFocus,
                matchCount: matches.length,
                currentIndex: _search.focusCardId == null
                    ? -1
                    : matches.indexWhere((c) => c.id == _search.focusCardId),
                // 干草仓库有自己的搜索框，板内搜索在那儿没有意义。
                hint: view == BoardView.haystack
                    ? '干草仓库请用下面那个搜索框'
                    : '搜索这块板上的卡片',
                enabled: view != BoardView.haystack,
                onChanged: (q) => setState(() => _search = _search.withQuery(q.trim())),
                onStep: _stepMatch,
                onClose: _closeSearch,
              ),
            Expanded(
              // 三个视图看的是同一批卡片，切换时交叉淡入比硬切更贴合
              // 「换个角度看同一堆东西」这个意思。
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                // 新旧两个视图都要 Positioned.fill。默认的 layoutBuilder 让
                // 当前视图以松约束自己定尺寸，结果画布和工具条会缩成内容
                // 宽度、缩在中间——视图必须占满整个区域。
                layoutBuilder: (current, previous) => Stack(
                  children: [
                    for (final w in previous) Positioned.fill(child: w),
                    if (current != null) Positioned.fill(child: current),
                  ],
                ),
                child: KeyedSubtree(
                  key: ValueKey(view),
                  child: switch (view) {
                    BoardView.canvas => CanvasView(
                      boardId: widget.boardId,
                      search: _search,
                      autoTidy: widget.autoTidy,
                    ),
                    BoardView.grouped => GroupedView(
                      boardId: widget.boardId,
                      search: _search,
                    ),
                    BoardView.haystack => HaystackView(boardId: widget.boardId),
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 板内搜索条，展开时挂在看板顶栏下面。
///
/// 不塞进顶栏是因为那一行已经有返回、板名、张数、视图切换、标签五样东西，
/// 再挤一个输入框，窄屏上谁都放不下。
class _BoardSearchBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final int matchCount;

  /// 当前定位到第几个命中（从 0 数）；还没定位过是 -1。
  final int currentIndex;

  final String hint;
  final bool enabled;
  final ValueChanged<String> onChanged;
  final ValueChanged<int> onStep;
  final VoidCallback onClose;

  const _BoardSearchBar({
    required this.controller,
    required this.focusNode,
    required this.matchCount,
    required this.currentIndex,
    required this.hint,
    required this.enabled,
    required this.onChanged,
    required this.onStep,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final k = theme.kanban;
    final hasQuery = controller.text.trim().isNotEmpty;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: k.hairline.withValues(alpha: 0.25),
        border: Border(bottom: BorderSide(color: k.hairline)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              enabled: enabled,
              onChanged: onChanged,
              // 回车走下一个，和浏览器里的页内查找一个手感。
              onSubmitted: (_) => onStep(1),
              textInputAction: TextInputAction.search,
              style: theme.textTheme.bodyMedium,
              decoration: InputDecoration(
                hintText: hint,
                prefixIcon: const Icon(Icons.search, size: 18),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 10),
          if (enabled && hasQuery) ...[
            Text(
              matchCount == 0
                  ? '无匹配'
                  : currentIndex < 0
                  ? '$matchCount 项'
                  : '${currentIndex + 1}/$matchCount',
              style: theme.textTheme.labelMedium?.copyWith(
                color: matchCount == 0 ? theme.colorScheme.error : k.cardBody,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: '上一个',
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              onPressed: matchCount == 0 ? null : () => onStep(-1),
              icon: const Icon(Icons.keyboard_arrow_up),
            ),
            IconButton(
              tooltip: '下一个',
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              onPressed: matchCount == 0 ? null : () => onStep(1),
              icon: const Icon(Icons.keyboard_arrow_down),
            ),
          ],
          IconButton(
            tooltip: '关闭搜索',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            onPressed: onClose,
            icon: const Icon(Icons.close),
          ),
        ],
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
              // 干草仓库用它自己的草垛脸，不用通用的方盒子图标——
              // 它是这个应用里唯一有名字、有性格的地方。
              if (view == BoardView.haystack)
                Opacity(
                  opacity: selected ? 1 : 0.72,
                  child: const HaystackIcon(size: 17),
                )
              else
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
