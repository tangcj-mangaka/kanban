import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared/shared.dart';

import '../../data/database.dart';
import '../../providers.dart';
import '../boards/board_dialogs.dart';
import '../format.dart';
import '../responsive.dart';
import '../tags/card_tag_picker.dart';
import '../theme/app_theme.dart';
import 'attachment_section.dart';
import 'card_history_sheet.dart';
import 'markdown_editor.dart';

/// 打开卡片详情。
///
/// 画布上的卡片只显示标题和正文前两行；要写内容、管标签、看评论都在这里。
Future<void> showCardDetail(
  BuildContext context,
  String boardId,
  String cardId,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => _CardDetailDialog(boardId: boardId, cardId: cardId),
  );
}

class _CardDetailDialog extends ConsumerStatefulWidget {
  final String boardId;
  final String cardId;

  const _CardDetailDialog({required this.boardId, required this.cardId});

  @override
  ConsumerState<_CardDetailDialog> createState() => _CardDetailDialogState();
}

class _CardDetailDialogState extends ConsumerState<_CardDetailDialog> {
  final _titleController = TextEditingController();
  final _commentController = TextEditingController();
  bool _titleInitialized = false;

  @override
  void dispose() {
    _titleController.dispose();
    _commentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final k = theme.kanban;
    final card = ref.watch(cardProvider(widget.cardId)).value;

    if (card == null) {
      return const Dialog(
        child: SizedBox(
          width: 300,
          height: 120,
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    // 只在第一次填入标题：之后由输入框自己持有，否则每次别处改动
    // 触发重建都会把光标弹回开头。
    if (!_titleInitialized) {
      _titleController.text = card.title;
      _titleInitialized = true;
    }

    final compact = isCompact(context);

    return Dialog(
      backgroundColor: theme.colorScheme.surface,
      insetPadding: EdgeInsets.all(compact ? 12 : 40),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: SizedBox(
        width: dialogWidth(context, 760),
        height: dialogHeight(context),
        child: Padding(
          padding: EdgeInsets.fromLTRB(compact ? 14 : 22, 16, compact ? 8 : 14, 16),
          child: SingleChildScrollView(
            child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(theme, k, card),
              const SizedBox(height: 3),
              _meta(theme, k, card),
              const SizedBox(height: 14),
              _tagRow(theme, k, card),
              const SizedBox(height: 16),
              // 正文跟着内容长高，整体可滚动。
              //
              // 这里前后错过两次：一开始让正文 Expanded 吃掉剩余空间，加进
              // 附件区之后它被挤成一条；改成固定 240 又走到另一个极端——
              // 一行字的卡片也顶着一个空箱子，把评论输入框挤出了窗口。
              // 现在编辑器自己按内容定高（最少 5 行），谁也不抢谁的。
              Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: MarkdownEditor(
                    // key 绑到卡片上：换卡片时重建编辑器，不会串内容。
                    key: ValueKey(card.id),
                    initialValue: card.body,
                    onChanged: (body) {
                      if (body == card.body) return;
                      ref.read(repositoryProvider).setCardField(
                            widget.boardId,
                            card.id,
                            CardF.body,
                            body,
                          );
                    },
                  ),
                ),
              const SizedBox(height: 14),
              AttachmentSection(boardId: widget.boardId, cardId: card.id),
              const SizedBox(height: 14),
              _comments(theme, k),
            ],
          ),
          ),
        ),
      ),
    );
  }

  Widget _header(ThemeData theme, KanbanColors k, CardRow card) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Tooltip(
          message: '改颜色',
          child: InkWell(
            onTap: () async {
              final choice = await pickSwatch(context, current: card.color);
              if (choice != null && mounted) {
                await ref.read(repositoryProvider).setCardField(
                      widget.boardId,
                      card.id,
                      CardF.color,
                      choice.key,
                    );
              }
            },
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Container(
                width: 15,
                height: 15,
                decoration: BoxDecoration(
                  color: k.cardSurface(card.color),
                  border: Border.all(color: k.accent(card.color), width: 2),
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: _titleController,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
            decoration: const InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: '卡片标题',
            ),
            onSubmitted: (_) => _saveTitle(card),
            onTapOutside: (_) => _saveTitle(card),
          ),
        ),
        PopupMenuButton<String>(
          tooltip: '更多',
          icon: Icon(Icons.more_horiz, color: k.cardBody),
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'collapse',
              child: Text(card.collapsed ? '在画布上展开' : '在画布上折叠'),
            ),
            const PopupMenuItem(value: 'history', child: Text('改动记录')),
            const PopupMenuDivider(),
            const PopupMenuItem(value: 'archive', child: Text('收进干草仓库')),
            const PopupMenuItem(value: 'delete', child: Text('删除卡片')),
          ],
          onSelected: (action) => _onMenu(card, action),
        ),
        IconButton(
          tooltip: '关闭',
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.close, size: 20),
        ),
      ],
    );
  }

  Widget _meta(ThemeData theme, KanbanColors k, CardRow card) {
    return Padding(
      padding: const EdgeInsets.only(left: 31),
      child: Text(
        '创建于 ${relativeTime(card.createdAt)} · 最后修改 ${relativeTime(card.updatedAt)}',
        style: theme.textTheme.labelSmall?.copyWith(
          color: k.cardBody.withValues(alpha: 0.8),
        ),
      ),
    );
  }

  Widget _tagRow(ThemeData theme, KanbanColors k, CardRow card) {
    final allTags = ref.watch(boardTagsProvider(widget.boardId)).value ?? const [];
    final onCard =
        (ref.watch(cardTagMapProvider(widget.boardId)).value ??
                const <String, List<String>>{})[card.id] ??
            const <String>[];
    final tags = allTags.where((t) => onCard.contains(t.id)).toList();

    return Padding(
      padding: const EdgeInsets.only(left: 31, right: 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final tag in tags)
            Container(
              padding: const EdgeInsets.only(left: 9, right: 3, top: 2, bottom: 2),
              decoration: BoxDecoration(
                color: k.accent(tag.color).withValues(alpha: k.isDark ? 0.24 : 0.18),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tag.name,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: k.accent(tag.color),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 2),
                  InkWell(
                    onTap: () => ref.read(repositoryProvider).setCardTag(
                          widget.boardId,
                          card.id,
                          tag.id,
                          on: false,
                        ),
                    borderRadius: BorderRadius.circular(10),
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: Icon(Icons.close, size: 12, color: k.accent(tag.color)),
                    ),
                  ),
                ],
              ),
            ),
          TextButton.icon(
            onPressed: () =>
                showCardTagPicker(context, ref, widget.boardId, card.id),
            icon: const Icon(Icons.add, size: 15),
            label: Text(tags.isEmpty ? '添加标签' : '标签'),
            style: TextButton.styleFrom(
              foregroundColor: k.cardBody,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
          ),
        ],
      ),
    );
  }

  Widget _comments(ThemeData theme, KanbanColors k) {
    final comments = ref.watch(commentsProvider(widget.cardId)).value ?? const [];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Row(
            children: [
              Text(
                comments.isEmpty ? '评论' : '评论 ${comments.length}',
                style: theme.textTheme.labelLarge?.copyWith(color: k.cardBody),
              ),
              const SizedBox(width: 10),
              Expanded(child: Divider(color: k.hairline)),
            ],
          ),
        ),
        const SizedBox(height: 8),
        if (comments.isEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '还没有评论',
              style: theme.textTheme.bodySmall?.copyWith(
                color: k.cardBody.withValues(alpha: 0.6),
              ),
            ),
          )
        else
          // 评论少时只占一点点，多了才滚动——空评论区不该白占半个弹窗。
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 210),
            child: ListView.separated(
              shrinkWrap: true,
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.only(right: 8),
              itemCount: comments.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (_, i) => _CommentTile(
                comment: comments[i],
                onDelete: () => ref
                    .read(repositoryProvider)
                    .deleteComment(widget.boardId, comments[i].id),
              ),
            ),
          ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _commentController,
                  decoration: const InputDecoration(
                    hintText: '写评论。发表后不能编辑，想改就删了重发',
                  ),
                  onSubmitted: (_) => _addComment(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: _addComment, child: const Text('发表')),
            ],
          ),
        ),
      ],
    );
  }

  void _saveTitle(CardRow card) {
    final text = _titleController.text.trim();
    if (text == card.title) return;
    ref.read(repositoryProvider).setCardField(
          widget.boardId,
          card.id,
          CardF.title,
          text,
        );
  }

  Future<void> _addComment() async {
    final text = _commentController.text.trim();
    if (text.isEmpty) return;
    _commentController.clear();
    await ref
        .read(repositoryProvider)
        .addComment(widget.boardId, widget.cardId, text);
  }

  Future<void> _onMenu(CardRow card, String action) async {
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
      case 'history':
        await showCardHistory(context, widget.boardId, card.id);
      case 'archive':
        await repo.archiveCard(widget.boardId, card.id);
        if (mounted) Navigator.pop(context);
      case 'delete':
        await repo.deleteCard(widget.boardId, card.id);
        if (mounted) Navigator.pop(context);
    }
  }
}

class _CommentTile extends StatelessWidget {
  final CommentRow comment;
  final VoidCallback onDelete;

  const _CommentTile({required this.comment, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final k = theme.kanban;

    return Container(
      padding: const EdgeInsets.fromLTRB(11, 8, 6, 9),
      decoration: BoxDecoration(
        color: k.hairline.withValues(alpha: 0.32),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                // P2 配对之后这里会是真实的设备名。
                comment.deviceId == 'local' ? '本机' : comment.deviceId,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: k.cardBody,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                relativeTime(comment.createdAt),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: k.cardBody.withValues(alpha: 0.7),
                ),
              ),
              const Spacer(),
              InkWell(
                onTap: onDelete,
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: Icon(
                    Icons.close,
                    size: 13,
                    color: k.cardBody.withValues(alpha: 0.65),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Text(
              comment.body,
              style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}
