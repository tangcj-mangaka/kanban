import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../format.dart';
import '../responsive.dart';
import '../theme/app_theme.dart';

/// 把删掉的看板捞回来。
///
/// 删除走的是墓碑：板上只多了一条「已删除」，板里的卡片、标签、评论、
/// 附件一个都没动。没有这个入口的话，那套设计的好处就用不上——数据
/// 留着，却没有门能进去拿。
///
/// 尤其是**离线删除会同步**：在没联网的机器上删掉一块板，一联网它就在
/// 所有设备上消失，而删除那一刻你看不到别人正往这块板里放东西。
/// 误删在这个架构下不是小概率事件，得有条回头路。
Future<void> showDeletedBoards(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _DeletedBoardsDialog(),
  );
}

class _DeletedBoardsDialog extends ConsumerWidget {
  const _DeletedBoardsDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final k = theme.kanban;
    final boards = ref.watch(deletedBoardsProvider).value;

    return AlertDialog(
      title: Text('删掉的看板', style: theme.textTheme.titleMedium),
      content: SizedBox(
        width: dialogWidth(context, 420),
        height: dialogHeight(context, fraction: 0.5),
        child: switch (boards) {
          null => const Center(child: CircularProgressIndicator()),
          [] => Center(
            child: Text(
              '没有删掉的看板',
              style: theme.textTheme.bodyMedium?.copyWith(color: k.cardBody),
            ),
          ),
          final list => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  '捞回来之后，板里的卡片、标签、评论和附件都会原样回来——'
                  '它们从来没被真删过。',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: k.cardBody,
                    height: 1.5,
                  ),
                ),
              ),
              Expanded(
                child: ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, _) =>
                      Divider(height: 14, color: k.hairline),
                  itemBuilder: (context, i) {
                    final summary = list[i];
                    final board = summary.board;
                    return Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: k.accent(board.color),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                board.name.isEmpty ? '未命名看板' : board.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelLarge,
                              ),
                              Text(
                                summary.cardCount == 0
                                    ? '空看板'
                                    : '${summary.cardCount} 张卡片 · '
                                        '最后改于 ${relativeTime(summary.lastUpdated)}',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: k.cardBody,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: () => ref
                              .read(repositoryProvider)
                              .restoreBoard(board.id),
                          child: const Text('捞回来'),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
