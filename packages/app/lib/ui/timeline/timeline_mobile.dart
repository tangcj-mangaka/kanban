import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database.dart';
import '../board/done_filter.dart';
import '../board/done_filter_button.dart';
import '../card/card_detail_dialog.dart';
import '../card/due_badge.dart';
import '../done_box.dart';
import '../empty_state.dart';
import '../../providers.dart';
import '../theme/app_theme.dart';
import 'timeline_layout.dart';

/// 手机上的时间轴：按时间远近分组的列表。
///
/// **不是甘特图。** 横向甘特在 375 像素宽的屏幕上一次只能看两三格，
/// 拖来拖去还是看不到全貌。手机上真正有用的问题是「今天该干什么」，
/// 一个「已过期／今天／这几天／以后」的列表答得更直接。
class TimelineMobile extends ConsumerWidget {
  final String boardId;

  /// 设了截止时间的卡片，已按计划开始排好序。
  final List<CardRow> scheduled;

  /// 没设截止时间的卡片。
  final List<CardRow> unscheduled;

  final DateTime now;
  final DoneFilter doneFilter;
  final VoidCallback onCycleDoneFilter;

  const TimelineMobile({
    super.key,
    required this.boardId,
    required this.scheduled,
    required this.unscheduled,
    required this.now,
    required this.doneFilter,
    required this.onCycleDoneFilter,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final k = theme.kanban;
    final groups = groupByDueBucket(scheduled, now);

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: k.hairline)),
          ),
          child: Row(
            children: [
              Text(
                '${scheduled.length} 张排了期',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: k.cardBody.withValues(alpha: 0.75),
                ),
              ),
              const Spacer(),
              DoneFilterButton(value: doneFilter, onTap: onCycleDoneFilter),
            ],
          ),
        ),
        if (scheduled.isEmpty && unscheduled.isEmpty)
          const Expanded(
            child: EmptyState(
              title: '还没有排期的卡片',
              body: '在卡片详情里设个截止日期，它就会出现在这里。',
            ),
          )
        else
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 24),
              children: [
                for (final bucket in DueBucket.values)
                  if ((groups[bucket] ?? const []).isNotEmpty) ...[
                    _header(theme, k, bucket.label, groups[bucket]!.length),
                    for (final card in groups[bucket]!)
                      _tile(context, ref, theme, k, card),
                    const SizedBox(height: 14),
                  ],
                if (unscheduled.isNotEmpty) ...[
                  _header(theme, k, '未排期', unscheduled.length),
                  for (final card in unscheduled)
                    _tile(context, ref, theme, k, card),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _header(ThemeData theme, KanbanColors k, String label, int count) {
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 7, top: 4),
      child: Row(
        children: [
          Text(
            label,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: k.cardTitle,
            ),
          ),
          const SizedBox(width: 7),
          Text(
            '$count',
            style: theme.textTheme.labelSmall?.copyWith(color: k.cardBody),
          ),
        ],
      ),
    );
  }

  Widget _tile(
    BuildContext context,
    WidgetRef ref,
    ThemeData theme,
    KanbanColors k,
    CardRow card,
  ) {
    final stripe = card.done
        ? k.doneStripe
        : dueStripeColor(k, cardDeadlineStatus(card, now));

    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Material(
        color: card.done ? k.doneSurface : k.cardSurface(card.color),
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          onTap: () => showCardDetail(context, boardId, card.id),
          borderRadius: BorderRadius.circular(9),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              border: Border.all(
                color: card.done ? k.doneBorder : k.cardBorder,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                children: [
                  if (stripe != null)
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      child: Container(width: 4, color: stripe),
                    ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      stripe != null ? 13 : 11,
                      10,
                      11,
                      10,
                    ),
                    child: Row(
                      children: [
                        DoneBox(
                          done: card.done,
                          onTap: () => ref
                              .read(repositoryProvider)
                              .toggleCardDone(boardId, card.id, !card.done),
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Text(
                            card.title.isEmpty ? '未命名' : card.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: card.title.isEmpty
                                  ? k.cardBody.withValues(alpha: 0.6)
                                  : k.cardTitle,
                              height: 1.35,
                            ),
                          ),
                        ),
                        if (card.due != null) ...[
                          const SizedBox(width: 8),
                          DueBadge(card: card),
                        ],
                      ],
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
}

/// 手机上按时间远近分的几档。
enum DueBucket {
  overdue('已过期'),
  today('今天'),
  soon('这几天'),
  later('以后');

  final String label;

  const DueBucket(this.label);
}

/// 把排过期的卡片分到各档里。
///
/// **一律按日期分档，不看有没有做完。** 「完成了就不再报警」管的是颜色：
/// 做完的卡片是绿条、没有红徽章，摆在「已过期」里也一眼看得出不用再管。
/// 反过来把它挪到别的档才是撒谎——它的截止日期确实在上周。想干净点就用
/// 工具条上的三态开关把已完成的滤掉。
///
/// 纯函数，时间从外面传——分档的边界（今天的最后一毫秒、第 3 天和第 4 天
/// 之间）只有这样才测得了。
Map<DueBucket, List<CardRow>> groupByDueBucket(
  List<CardRow> cards,
  DateTime now, {
  int soonDays = 3,
}) {
  final today = dateOnly(now);
  final groups = {for (final b in DueBucket.values) b: <CardRow>[]};

  for (final card in cards) {
    final due = card.due;
    if (due == null) continue;
    final days = daysBetween(today, DateTime.fromMillisecondsSinceEpoch(due));

    final bucket = switch (days) {
      // 今天到期的留在「今天」，哪怕钟点已经过了——它仍然是今天的事。
      0 => DueBucket.today,
      < 0 => DueBucket.overdue,
      _ when days <= soonDays => DueBucket.soon,
      _ => DueBucket.later,
    };
    groups[bucket]!.add(card);
  }

  for (final list in groups.values) {
    list.sort((a, b) => a.due!.compareTo(b.due!));
  }
  return groups;
}
