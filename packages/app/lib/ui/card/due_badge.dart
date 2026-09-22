import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database.dart';
import '../../providers.dart';
import '../deadline.dart';
import '../theme/app_theme.dart';

/// 卡片上那枚截止时间的小徽章。画布和分组视图共用。
///
/// 自己订阅 [nowProvider]：时间会往前走，一张卡片可能在你盯着它的时候
/// 到期。让每枚徽章各自跟着分钟跳，比让整个视图重建便宜。
class DueBadge extends ConsumerWidget {
  final CardRow card;

  /// 紧凑模式：只给日期，不给「超时 3 天」这种长说法。
  /// 卡片折叠得很窄时用。
  final bool dense;

  const DueBadge({super.key, required this.card, this.dense = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final due = card.due;
    if (due == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final k = theme.kanban;
    final now = ref.watch(nowProvider).value ?? DateTime.now();
    final status = deadlineStatus(
      due: due,
      done: card.done,
      archived: card.archived,
      now: now,
    );

    final fill = dueStripeColor(k, status);
    final text = dense ? formatDueDate(due, now) : dueLabel(due, now);

    // 不报警的状态（还早、已完成、已归档）只留一行灰字。日期还是要看得见，
    // 但不该和真正紧急的卡片抢同一份注意力。
    if (fill == null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.schedule,
            size: 12,
            color: k.cardBody.withValues(alpha: 0.75),
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              formatDueDate(due, now),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: k.cardBody.withValues(alpha: 0.85),
              ),
            ),
          ),
        ],
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall?.copyWith(
          color: k.alarmBadgeText,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 卡片左侧那道竖条该用什么颜色，null 表示不画。
///
/// 完成的绿条和超时的红条**占同一个位置**，所以这里一次定死优先级：
/// 做完了就不报警，归档了也不报警。
Color? dueStripeColor(KanbanColors k, DeadlineStatus status) =>
    switch (status) {
      DeadlineStatus.overdue => k.overdueStripe,
      DeadlineStatus.soon => k.dueSoonStripe,
      DeadlineStatus.none ||
      DeadlineStatus.later ||
      DeadlineStatus.done ||
      DeadlineStatus.archived => null,
    };

/// 一张卡片当前的截止状态。给要画竖条的地方用。
DeadlineStatus cardDeadlineStatus(CardRow card, DateTime now) =>
    deadlineStatus(
      due: card.due,
      done: card.done,
      archived: card.archived,
      now: now,
    );
