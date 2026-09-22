import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../responsive.dart';
import '../theme/app_theme.dart';

/// 把卡片搬到另一块看板。
///
/// 只问一件事：搬去哪。**标签会被清空**，这一点在弹窗里明说——它是搬家
/// 的一部分（标签属于看板，搬过去那些标签在新板上根本不存在），但用户
/// 不该是搬完了才发现。
///
/// 返回搬去的看板 id，取消则返回 null。
Future<String?> pickTargetBoard(
  BuildContext context, {
  required String currentBoardId,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _MoveCardDialog(currentBoardId: currentBoardId),
  );
}

class _MoveCardDialog extends ConsumerWidget {
  final String currentBoardId;

  const _MoveCardDialog({required this.currentBoardId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final k = theme.kanban;
    final boards = ref.watch(boardSummariesProvider).value ?? const [];
    final targets = [
      for (final b in boards)
        if (b.board.id != currentBoardId) b,
    ];

    if (targets.isEmpty) {
      return AlertDialog(
        title: const Text('没有别的看板'),
        content: const Text('先建一块看板，才有地方可搬。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      );
    }

    return AlertDialog(
      title: Text('搬到哪块看板', style: theme.textTheme.titleMedium),
      content: SizedBox(
        width: dialogWidth(context, 380),
        height: dialogHeight(context, fraction: 0.5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                '搬过去之后这张卡片的标签会全部清空，到了新看板自己重新打。'
                '附件和评论跟着走，不受影响。',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: k.cardBody,
                  height: 1.5,
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: targets.length,
                itemBuilder: (context, i) {
                  final summary = targets[i];
                  final board = summary.board;
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: k.accent(board.color),
                        shape: BoxShape.circle,
                      ),
                    ),
                    title: Text(
                      board.name.isEmpty ? '未命名看板' : board.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      summary.cardCount == 0
                          ? '空看板'
                          : '${summary.cardCount} 张卡片',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: k.cardBody,
                      ),
                    ),
                    onTap: () => Navigator.pop(context, board.id),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    );
  }
}

/// 走完一整趟搬家：问搬去哪 → 搬 → 告诉用户结果。
///
/// 画布、分组、详情三处菜单都走这一条路，行为才不会各长各的。
///
/// 返回是否真的搬了，调用方据此决定要不要顺手把详情弹窗关掉。
Future<bool> moveCardFrom(
  BuildContext context,
  WidgetRef ref, {
  required String cardId,
  required String boardId,
}) async {
  final target = await pickTargetBoard(context, currentBoardId: boardId);
  if (target == null || !context.mounted) return false;

  final name = (ref.read(boardSummariesProvider).value ?? const [])
      .where((b) => b.board.id == target)
      .map((b) => b.board.name)
      .firstOrNull;

  final cleared = await ref.read(repositoryProvider).moveCardToBoard(
    cardId: cardId,
    fromBoardId: boardId,
    toBoardId: target,
  );

  if (!context.mounted) return true;

  // 清掉了几个标签要讲出来——那是这趟操作里唯一**丢东西**的部分，
  // 默默做掉的话，用户回头会以为是 bug。
  final label = (name == null || name.isEmpty) ? '未命名看板' : name;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        cleared == 0 ? '已搬到「$label」' : '已搬到「$label」，清掉了 $cleared 个标签',
      ),
      behavior: SnackBarBehavior.floating,
      width: 420,
    ),
  );
  return true;
}
