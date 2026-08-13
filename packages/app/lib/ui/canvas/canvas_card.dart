import 'package:flutter/material.dart';

import '../../data/database.dart';
import '../theme/app_theme.dart';

/// 画布上的一张卡片。
///
/// 内部一律用**世界坐标下的尺寸**（不乘缩放）——缩放由外层的 Transform
/// 统一处理。这样卡片里所有的字号、间距都只写一遍，不用为每个缩放级别
/// 各调一套。
class CanvasCard extends StatelessWidget {
  final CardRow card;

  /// 这张卡片身上的标签，已按板内顺序排好。
  final List<TagRow> tags;

  /// 评论条数，为 0 时不显示角标。
  final int commentCount;

  /// 附件个数，为 0 时不显示角标。
  final int attachmentCount;

  /// 正在被拖动——加重阴影并轻微放大，给一点"拿起来了"的手感。
  final bool dragging;

  /// 正在原地改标题。
  final bool editing;

  final TextEditingController? titleController;
  final FocusNode? titleFocus;

  final VoidCallback onToggleCollapse;
  final VoidCallback onEditTitleDone;
  final ValueChanged<String> onMenuAction;

  const CanvasCard({
    super.key,
    required this.card,
    required this.tags,
    required this.commentCount,
    required this.attachmentCount,
    required this.dragging,
    required this.editing,
    required this.titleController,
    required this.titleFocus,
    required this.onToggleCollapse,
    required this.onEditTitleDone,
    required this.onMenuAction,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final k = theme.kanban;

    return AnimatedScale(
      scale: dragging ? 1.02 : 1,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: card.width,
        decoration: BoxDecoration(
          color: k.cardSurface(card.color),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: k.cardBorder),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(
                alpha: dragging ? (k.isDark ? 0.5 : 0.20) : (k.isDark ? 0.28 : 0.07),
              ),
              blurRadius: dragging ? 18 : 6,
              offset: Offset(0, dragging ? 7 : 2),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _title(theme, k),
            if (card.body.isNotEmpty) ...[
              const SizedBox(height: 5),
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(
                  card.body,
                  // 折叠态只给两行，画布上才看得清全局；展开看全文。
                  maxLines: card.collapsed ? 2 : null,
                  overflow: card.collapsed ? TextOverflow.ellipsis : null,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: k.cardBody,
                    height: 1.5,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            _footer(theme, k),
          ],
        ),
      ),
    );
  }

  Widget _title(ThemeData theme, KanbanColors k) {
    final style = theme.textTheme.titleSmall?.copyWith(
      color: k.cardTitle,
      fontWeight: FontWeight.w600,
      fontSize: 13.5,
      height: 1.35,
    );

    if (editing) {
      return TextField(
        controller: titleController,
        focusNode: titleFocus,
        style: style,
        maxLines: null,
        decoration: const InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: EdgeInsets.zero,
          hintText: '卡片标题',
        ),
        onSubmitted: (_) => onEditTitleDone(),
        onTapOutside: (_) => onEditTitleDone(),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            card.title.isEmpty ? '未命名' : card.title,
            style: card.title.isEmpty
                ? style?.copyWith(color: k.cardBody.withValues(alpha: 0.6))
                : style,
          ),
        ),
        _menu(k),
      ],
    );
  }

  Widget _menu(KanbanColors k) {
    return SizedBox(
      width: 22,
      height: 20,
      child: PopupMenuButton<String>(
        tooltip: '',
        padding: EdgeInsets.zero,
        iconSize: 15,
        splashRadius: 14,
        icon: Icon(Icons.more_horiz, color: k.cardBody.withValues(alpha: 0.7)),
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'detail', child: Text('打开详情')),
          const PopupMenuItem(value: 'rename', child: Text('改标题')),
          PopupMenuItem(
            value: 'collapse',
            child: Text(card.collapsed ? '展开' : '折叠'),
          ),
          const PopupMenuItem(value: 'color', child: Text('改颜色')),
          const PopupMenuItem(value: 'tags', child: Text('标签')),
          const PopupMenuDivider(),
          const PopupMenuItem(value: 'archive', child: Text('收进干草仓库')),
          const PopupMenuItem(value: 'delete', child: Text('删除')),
        ],
        onSelected: onMenuAction,
      ),
    );
  }

  Widget _footer(ThemeData theme, KanbanColors k) {
    return Row(
      children: [
        Expanded(
          child: Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final tag in tags)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: k
                        .accent(tag.color)
                        .withValues(alpha: k.isDark ? 0.24 : 0.18),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    tag.name,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: k.accent(tag.color),
                      fontWeight: FontWeight.w600,
                      fontSize: 10.5,
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (attachmentCount > 0) ...[
          Icon(
            Icons.attach_file,
            size: 12,
            color: k.cardBody.withValues(alpha: 0.75),
          ),
          const SizedBox(width: 2),
          Text(
            '$attachmentCount',
            style: theme.textTheme.labelSmall?.copyWith(
              color: k.cardBody.withValues(alpha: 0.75),
              fontSize: 10.5,
            ),
          ),
          const SizedBox(width: 6),
        ],
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
          const SizedBox(width: 6),
        ],
        if (card.body.isNotEmpty)
          InkWell(
            onTap: onToggleCollapse,
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(
                card.collapsed ? Icons.expand_more : Icons.expand_less,
                size: 15,
                color: k.cardBody.withValues(alpha: 0.7),
              ),
            ),
          ),
      ],
    );
  }
}
