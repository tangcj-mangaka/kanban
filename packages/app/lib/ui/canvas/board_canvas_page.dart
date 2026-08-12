import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared/shared.dart';

import '../../data/database.dart';
import '../../providers.dart';
import '../boards/board_dialogs.dart';
import '../tags/card_tag_picker.dart';
import '../theme/app_theme.dart';
import 'canvas_card.dart';
import 'canvas_transform.dart';
import 'grid_painter.dart';

/// 画布视图 —— 唯一的编辑主场。
///
/// 卡片在这里自由摆放；分组视图只是同一批卡片的另一种呈现，不能拖。
class BoardCanvasPage extends ConsumerStatefulWidget {
  final String boardId;

  const BoardCanvasPage({super.key, required this.boardId});

  @override
  ConsumerState<BoardCanvasPage> createState() => _BoardCanvasPageState();
}

class _BoardCanvasPageState extends ConsumerState<BoardCanvasPage> {
  CanvasTransform _t = const CanvasTransform();

  // 平移画布
  bool _panning = false;
  Offset _lastPanPoint = Offset.zero;
  bool _spaceDown = false;

  // 拖动卡片。拖动过程中只改这里的临时值，**不落库**——每帧写一次
  // 本地是几百次无谓事务，到 P2 更会把局域网刷爆。松手才提交一次。
  String? _draggingId;
  Offset _dragStartGlobal = Offset.zero;
  Offset _dragStartWorld = Offset.zero;
  Offset _dragWorld = Offset.zero;

  // 拖调宽度，同样是松手才落库。
  String? _resizingId;
  double _resizeStartWidth = 0;
  double _resizeWidth = 0;
  double _resizeStartGlobalX = 0;

  String? _editingId;
  final _titleController = TextEditingController();
  final _titleFocus = FocusNode();

  final _viewportKey = GlobalKey();

  @override
  void dispose() {
    _titleController.dispose();
    _titleFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final board = ref.watch(boardProvider(widget.boardId)).value;
    final cards = ref.watch(canvasCardsProvider(widget.boardId)).value ?? const [];
    final tags = ref.watch(boardTagsProvider(widget.boardId)).value ?? const [];
    final cardTags = ref.watch(cardTagMapProvider(widget.boardId)).value ?? const {};
    final tagById = {for (final t in tags) t.id: t};

    return Scaffold(
      backgroundColor: theme.kanban.canvas,
      body: SafeArea(
        child: Column(
          children: [
            _header(context, board, cards.length),
            Expanded(
              child: Focus(
                autofocus: true,
                onKeyEvent: _onKey,
                child: MouseRegion(
                  cursor: _panning || _spaceDown
                      ? SystemMouseCursors.grabbing
                      : SystemMouseCursors.basic,
                  child: Listener(
                    onPointerSignal: _onPointerSignal,
                    onPointerDown: _onPointerDown,
                    onPointerMove: _onPointerMove,
                    onPointerUp: (_) => _panning = false,
                    onPointerCancel: (_) => _panning = false,
                    child: Stack(
                      key: _viewportKey,
                      children: [
                        Positioned.fill(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: _commitTitle,
                            onDoubleTapDown: _onCanvasDoubleTap,
                            child: CustomPaint(
                              painter: GridPainter(
                                transform: _t,
                                dotColor: theme.kanban.canvasDot,
                              ),
                            ),
                          ),
                        ),
                        for (final card in cards)
                          _positionedCard(
                            card,
                            [
                              for (final id in cardTags[card.id] ?? const <String>[])
                                if (tagById[id] != null) tagById[id]!,
                            ],
                          ),
                        if (cards.isEmpty) const _CanvasHint(),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // 顶栏
  // -------------------------------------------------------------------------

  Widget _header(BuildContext context, BoardRow? board, int cardCount) {
    final theme = Theme.of(context);
    final k = theme.kanban;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 20, 10),
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
            Text(
              board.name.isEmpty ? '未命名看板' : board.name,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          const SizedBox(width: 12),
          Text(
            cardCount == 0 ? '空画布' : '$cardCount 张',
            style: theme.textTheme.labelSmall?.copyWith(color: k.cardBody),
          ),
          const Spacer(),
          _ToolButton(
            icon: Icons.grid_view_rounded,
            label: '整理',
            tooltip: '把散乱的卡片排成网格',
            onTap: () =>
                ref.read(repositoryProvider).tidyCards(widget.boardId),
          ),
          const SizedBox(width: 6),
          _ToolButton(
            icon: Icons.fit_screen_outlined,
            label: '适应全部',
            tooltip: '缩放到能看见所有卡片',
            onTap: _fitAll,
          ),
          const SizedBox(width: 10),
          _ZoomIndicator(
            scale: _t.scale,
            onReset: () => setState(() => _t = const CanvasTransform()),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // 视口操作
  // -------------------------------------------------------------------------

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    // 正在打字时不抢空格键。
    if (_editingId != null) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.space) {
      final down = event is! KeyUpEvent;
      if (down != _spaceDown) setState(() => _spaceDown = down);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      final zoomKey = HardwareKeyboard.instance.isControlPressed ||
          HardwareKeyboard.instance.isMetaPressed;
      setState(() {
        if (zoomKey) {
          // 跟 Figma 一致：滚轮平移，加修饰键才缩放。触控板双指也走这条。
          final factor = event.scrollDelta.dy > 0 ? 0.92 : 1.08;
          _t = _t.zoomBy(factor, event.localPosition);
        } else {
          _t = _t.panBy(-event.scrollDelta);
        }
      });
    } else if (event is PointerScaleEvent) {
      // 触控板捏合。
      setState(() => _t = _t.zoomBy(event.scale, event.localPosition));
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    final middle = event.buttons & kMiddleMouseButton != 0;
    if (middle || _spaceDown) {
      _panning = true;
      _lastPanPoint = event.localPosition;
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_panning) return;
    setState(() {
      _t = _t.panBy(event.localPosition - _lastPanPoint);
      _lastPanPoint = event.localPosition;
    });
  }

  void _fitAll() {
    final cards = ref.read(canvasCardsProvider(widget.boardId)).value ?? const [];
    if (cards.isEmpty) return;

    // 卡片高度是内容撑出来的，这里取个够用的估值——"适应全部"只要求
    // 大致装得下，不需要像素级精确。
    const estimatedHeight = 150.0;
    var rect = Rect.fromLTWH(cards.first.x, cards.first.y, cards.first.width, estimatedHeight);
    for (final c in cards.skip(1)) {
      rect = rect.expandToInclude(
        Rect.fromLTWH(c.x, c.y, c.width, estimatedHeight),
      );
    }

    final box = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    setState(() => _t = CanvasTransform.fit(rect, box.size));
  }

  // -------------------------------------------------------------------------
  // 卡片
  // -------------------------------------------------------------------------

  Widget _positionedCard(CardRow card, List<TagRow> tags) {
    final world = card.id == _draggingId
        ? _dragWorld
        : Offset(card.x, card.y);
    final width = card.id == _resizingId ? _resizeWidth : card.width;
    final screen = _t.toScreen(world);

    return Positioned(
      left: screen.dx,
      top: screen.dy,
      child: Transform.scale(
        scale: _t.scale,
        alignment: Alignment.topLeft,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (_) => _bringToFront(card),
              onDoubleTap: () => _startEditTitle(card),
              onPanStart: (d) => _onCardDragStart(card, d),
              onPanUpdate: _onCardDragUpdate,
              onPanEnd: (_) => _onCardDragEnd(card),
              child: CanvasCard(
                card: card.copyWith(width: width),
                tags: tags,
                dragging: card.id == _draggingId,
                editing: card.id == _editingId,
                titleController: _titleController,
                titleFocus: _titleFocus,
                onToggleCollapse: () => ref
                    .read(repositoryProvider)
                    .setCardField(
                      widget.boardId,
                      card.id,
                      CardF.collapsed,
                      !card.collapsed,
                      touch: false,
                    ),
                onEditTitleDone: _commitTitle,
                onMenuAction: (action) => _onCardMenu(card, action),
              ),
            ),
            Positioned(
              right: -3,
              bottom: -3,
              child: _ResizeHandle(
                onStart: (globalX) {
                  setState(() {
                    _resizingId = card.id;
                    _resizeStartWidth = card.width;
                    _resizeWidth = card.width;
                    _resizeStartGlobalX = globalX;
                  });
                },
                onUpdate: (globalX) {
                  setState(() {
                    final delta = (globalX - _resizeStartGlobalX) / _t.scale;
                    _resizeWidth = (_resizeStartWidth + delta).clamp(150.0, 640.0);
                  });
                },
                onEnd: () {
                  final w = _resizeWidth;
                  setState(() => _resizingId = null);
                  ref.read(repositoryProvider).setCardField(
                        widget.boardId,
                        card.id,
                        CardF.width,
                        w,
                        touch: false,
                      );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _bringToFront(CardRow card) {
    if (_editingId != null && _editingId != card.id) _commitTitle();
    ref.read(repositoryProvider).bringToFront(widget.boardId, card.id);
  }

  void _onCardDragStart(CardRow card, DragStartDetails d) {
    if (_spaceDown) return;
    setState(() {
      _draggingId = card.id;
      _dragStartGlobal = d.globalPosition;
      _dragStartWorld = Offset(card.x, card.y);
      _dragWorld = _dragStartWorld;
    });
  }

  void _onCardDragUpdate(DragUpdateDetails d) {
    if (_draggingId == null) return;
    // 用全局坐标自己换算，不依赖 delta 在变换里的语义——缩放不是 1 时
    // 那个语义容易搞错，换算出来的手感会飘。
    final worldDelta = (d.globalPosition - _dragStartGlobal) / _t.scale;
    setState(() => _dragWorld = _dragStartWorld + worldDelta);
  }

  void _onCardDragEnd(CardRow card) {
    if (_draggingId == null) return;
    final pos = _dragWorld;
    setState(() => _draggingId = null);
    // 整段拖动只在这里落一次库。
    ref.read(repositoryProvider).moveCard(widget.boardId, card.id, pos.dx, pos.dy);
  }

  Future<void> _onCanvasDoubleTap(TapDownDetails d) async {
    _commitTitle();
    final world = _t.toWorld(d.localPosition);
    final repo = ref.read(repositoryProvider);
    final id = await repo.createCard(
      boardId: widget.boardId,
      // 双击点落在卡片左上角会让卡片偏右下，往回挪一点更贴手。
      x: world.dx - 40,
      y: world.dy - 20,
    );
    // 新建的卡片直接展开并进入改标题状态——随手戳一下就能开写。
    await repo.setCardField(widget.boardId, id, CardF.collapsed, false, touch: false);
    if (!mounted) return;
    setState(() {
      _editingId = id;
      _titleController.text = '';
    });
    _titleFocus.requestFocus();
  }

  void _startEditTitle(CardRow card) {
    setState(() {
      _editingId = card.id;
      _titleController.text = card.title;
      _titleController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: card.title.length,
      );
    });
    _titleFocus.requestFocus();
  }

  void _commitTitle() {
    final id = _editingId;
    if (id == null) return;
    final text = _titleController.text.trim();
    setState(() => _editingId = null);
    ref.read(repositoryProvider).setCardField(
          widget.boardId,
          id,
          CardF.title,
          text,
        );
  }

  Future<void> _onCardMenu(CardRow card, String action) async {
    final repo = ref.read(repositoryProvider);
    switch (action) {
      case 'collapse':
        await repo.setCardField(
          widget.boardId,
          card.id,
          CardF.collapsed,
          !card.collapsed,
          touch: false,
        );
      case 'color':
        final key = await pickSwatch(context, current: card.color);
        if (key != null) {
          await repo.setCardField(widget.boardId, card.id, CardF.color, key);
        }
      case 'tags':
        if (!mounted) return;
        await showCardTagPicker(context, ref, widget.boardId, card.id);
      case 'archive':
        await repo.archiveCard(widget.boardId, card.id);
      case 'delete':
        await repo.deleteCard(widget.boardId, card.id);
    }
  }
}

// ---------------------------------------------------------------------------

class _ResizeHandle extends StatelessWidget {
  final ValueChanged<double> onStart;
  final ValueChanged<double> onUpdate;
  final VoidCallback onEnd;

  const _ResizeHandle({
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (d) => onStart(d.globalPosition.dx),
        onHorizontalDragUpdate: (d) => onUpdate(d.globalPosition.dx),
        onHorizontalDragEnd: (_) => onEnd(),
        child: SizedBox(
          width: 16,
          height: 16,
          child: Center(
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: Theme.of(context).kanban.cardBody.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback onTap;

  const _ToolButton({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: TextButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 16),
        label: Text(label),
        style: TextButton.styleFrom(
          foregroundColor: Theme.of(context).kanban.cardBody,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        ),
      ),
    );
  }
}

class _ZoomIndicator extends StatelessWidget {
  final double scale;
  final VoidCallback onReset;

  const _ZoomIndicator({required this.scale, required this.onReset});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: '点击回到 100%',
      child: InkWell(
        onTap: onReset,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Text(
            '${(scale * 100).round()}%',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.kanban.cardBody,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }
}

/// 空画布上的引导。
class _CanvasHint extends StatelessWidget {
  const _CanvasHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return IgnorePointer(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '双击空白处新建卡片',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.kanban.cardBody,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '滚轮平移 · ⌘ + 滚轮缩放 · 空格拖拽也能平移',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.kanban.cardBody.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
