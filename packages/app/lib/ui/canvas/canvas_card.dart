import 'package:flutter/material.dart';

import '../../data/database.dart';
import '../attachment_image.dart';
import '../done_box.dart';
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

  /// 点左边那个勾。
  final VoidCallback onToggleDone;

  /// 封面图（第一张图片附件）。没有图就是 null。
  final AttachmentRow? cover;

  /// 这张卡片上检测到过多设备并发改动。
  final bool conflicted;

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
    required this.onToggleDone,
    required this.cover,
    required this.conflicted,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final k = theme.kanban;

    // 封面图**一直显示**，折叠与否都不影响。
    //
    // 折叠只管正文长短：图是这张卡片一眼就能认出来的东西，藏起来的话
    // 画布上一排卡片全靠读标题分辨，等于白加了封面。
    final coverHash = cover?.thumbHash ?? cover?.hash;

    return AnimatedScale(
      scale: dragging ? 1.02 : 1,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: card.width,
        decoration: BoxDecoration(
          // 完成的卡片一律淡红色，盖掉它本来的颜色。
          color: card.done ? k.doneSurface : k.cardSurface(card.color),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: card.done ? k.doneBorder : k.cardBorder),
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
        child: ClipRRect(
          borderRadius: BorderRadius.circular(9),
          child: Stack(
            children: [
              if (card.done)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: Container(width: 4, color: k.doneStripe),
                ),
              Padding(
                padding: EdgeInsets.fromLTRB(card.done ? 14 : 12, 10, 8, 10),
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
                  // 折叠态给三行。再多画布上就成了一堵字墙，
                  // 想看全文点展开。标题不截断——标题短，而且它是
                  // 在一堆卡片里认出这张的主要依据。
                  maxLines: card.collapsed ? 3 : null,
                  overflow: card.collapsed ? TextOverflow.ellipsis : null,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: k.cardBody,
                    height: 1.5,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
            if (coverHash != null) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: AttachmentImage(
                  hash: coverHash,
                  // 按原比例铺满卡片宽度，高度由图自己定——用户要的是
                  // 「先看看效果」，不裁切才看得出原图什么样。
                  fit: BoxFit.fitWidth,
                  placeholderHeight: 96,
                ),
              ),
            ],
            const SizedBox(height: 8),
            _footer(theme, k),
          ],
                ),
              ),
            ],
          ),
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
        DoneBox(done: card.done, onTap: onToggleDone),
        const SizedBox(width: 7),
        if (conflicted) ...[
          Padding(
            padding: const EdgeInsets.only(top: 1, right: 5),
            child: Tooltip(
              message: '这张卡片被多台设备同时改过，打开详情看改动记录',
              child: Icon(
                Icons.call_split,
                size: 14,
                color: theme.colorScheme.error,
              ),
            ),
          ),
        ],
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
