import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared/shared.dart';

import '../../data/database.dart';
import '../../providers.dart';
import '../board/done_filter.dart';
import '../board/done_filter_button.dart';
import '../card/card_detail_dialog.dart';
import '../card/due_badge.dart';
import '../deadline.dart';
import '../empty_state.dart';
import '../responsive.dart';
import '../theme/app_theme.dart';
import 'timeline_layout.dart';
import 'timeline_mobile.dart';

/// 时间轴 —— 按截止日期排出来的甘特图。
///
/// **只收有截止时间的卡片。** 没截止就谈不上「进度」，那些卡片收在底部
/// 一个折叠区里，点一下能直接给它们排期。
///
/// 手机上换成按时间分组的列表（见 [TimelineMobile]）：横向甘特在窄屏上
/// 一次只能看两三格，不如「已过期／今天／本周」的列表实用。
class TimelineView extends ConsumerStatefulWidget {
  final String boardId;
  final DoneFilter doneFilter;
  final VoidCallback onCycleDoneFilter;

  const TimelineView({
    super.key,
    required this.boardId,
    required this.doneFilter,
    required this.onCycleDoneFilter,
  });

  @override
  ConsumerState<TimelineView> createState() => _TimelineViewState();
}

class _TimelineViewState extends ConsumerState<TimelineView> {
  /// 表头和条区各有一个横向滚动条，必须同步——否则日期和条会对不上。
  final _headerScroll = ScrollController();
  final _bodyScroll = ScrollController();

  /// 已经定位到「今天」了。只做一次：之后用户自己滚到哪儿就是哪儿，
  /// 每次重建都跳回今天会把人气疯。
  bool _centered = false;

  /// 等滚动区量好尺寸重试了几次。见 [_centerOnToday]。
  int _centerAttempts = 0;
  static const int _maxCenterAttempts = 20;

  bool _showUnscheduled = false;

  @override
  void initState() {
    super.initState();
    _headerScroll.addListener(() => _mirror(_headerScroll, _bodyScroll));
    _bodyScroll.addListener(() => _mirror(_bodyScroll, _headerScroll));
  }

  /// 把 [from] 的位置抄给 [to]。
  ///
  /// 要判相等再写，否则两个监听器会互相触发，滚动永远停不下来。
  void _mirror(ScrollController from, ScrollController to) {
    if (!to.hasClients || !from.hasClients) return;
    if ((to.offset - from.offset).abs() < 0.5) return;
    to.jumpTo(from.offset.clamp(
      to.position.minScrollExtent,
      to.position.maxScrollExtent,
    ));
  }

  @override
  void dispose() {
    _headerScroll.dispose();
    _bodyScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final k = theme.kanban;
    final now = ref.watch(nowProvider).value ?? DateTime.now();

    final all = ref.watch(canvasCardsProvider(widget.boardId)).value ?? const [];
    final visible = all
        .where((c) => widget.doneFilter.accepts(cardIsDone: c.done))
        .toList();

    final scheduled = [for (final c in visible) if (c.due != null) c]
      ..sort(_byPlannedStart);
    final unscheduled = [for (final c in visible) if (c.due == null) c];

    if (isCompact(context)) {
      return TimelineMobile(
        boardId: widget.boardId,
        scheduled: scheduled,
        unscheduled: unscheduled,
        now: now,
        doneFilter: widget.doneFilter,
        onCycleDoneFilter: widget.onCycleDoneFilter,
      );
    }

    return Column(
      children: [
        _toolbar(theme, k, scheduled.length, unscheduled.length),
        if (scheduled.isEmpty)
          Expanded(
            child: const EmptyState(
              title: '还没有排期的卡片',
              body: '在卡片详情里设个截止日期，它就会出现在这条时间轴上。',
            ),
          )
        else
          Expanded(child: _chart(theme, k, scheduled, now)),
        if (unscheduled.isNotEmpty)
          _unscheduledSection(theme, k, unscheduled),
      ],
    );
  }

  /// 把「今天」滚到靠左的位置，只做一次。
  ///
  /// 时间范围可能横跨好几年（有张卡片截止在两年后就会这样），不定位的话
  /// 一进来看到的是一片空白。
  ///
  /// **必须等滚动区真的量好了才算数。** 窗口刚打开的那一两帧，视口还在
  /// 定尺寸，`maxScrollExtent` 是个不作准的数；拿它去 clamp 会把位置钉在
  /// 一个莫名其妙的地方——而一次性的 postFrame 回调只跑这一次，钉歪了
  /// 之后再也不会纠正。所以量不到就不置位，自己排下一帧重试，
  /// 而不是等下一次重建（那可能是一分钟后计时器跳动的时候）。
  ///
  /// [_centerAttempts] 是保险丝：万一这个滚动区永远量不出来，也不能让
  /// 回调一帧接一帧地无限排下去。
  void _centerOnToday(TimelineRange range, DateTime now) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _centered) return;

      final ready =
          _bodyScroll.hasClients && _bodyScroll.position.hasContentDimensions;
      if (!ready) {
        if (_centerAttempts++ < _maxCenterAttempts) _centerOnToday(range, now);
        return;
      }

      _centered = true;
      final position = _bodyScroll.position;
      _bodyScroll.jumpTo(
        initialScrollOffset(range, now).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    });
  }

  /// 排序：按计划开始排，同一天的按截止先后。
  ///
  /// 用开始时间当主键而不是截止时间，条才会沿对角线往下走，像甘特图该有
  /// 的样子；按截止排会让长条短条交错，读起来很乱。
  int _byPlannedStart(CardRow a, CardRow b) {
    final sa = (a.start != null && a.start! <= a.due!) ? a.start! : a.due!;
    final sb = (b.start != null && b.start! <= b.due!) ? b.start! : b.due!;
    final d = sa.compareTo(sb);
    return d != 0 ? d : a.due!.compareTo(b.due!);
  }

  Widget _toolbar(ThemeData theme, KanbanColors k, int shown, int hidden) {
    return Container(
      // 和另外三个视图一致的 16/8，切视图时高度不跳。
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: k.hairline)),
      ),
      child: Row(
        children: [
          Text(
            '$shown 张排了期',
            style: theme.textTheme.labelSmall?.copyWith(
              color: k.cardBody.withValues(alpha: 0.75),
            ),
          ),
          if (hidden > 0)
            Text(
              ' · $hidden 张没排',
              style: theme.textTheme.labelSmall?.copyWith(
                color: k.cardBody.withValues(alpha: 0.6),
              ),
            ),
          const Spacer(),
          Text(
            '点条打开卡片',
            style: theme.textTheme.labelSmall?.copyWith(
              color: k.cardBody.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(width: 10),
          DoneFilterButton(
            value: widget.doneFilter,
            onTap: widget.onCycleDoneFilter,
          ),
        ],
      ),
    );
  }

  Widget _chart(
    ThemeData theme,
    KanbanColors k,
    List<CardRow> cards,
    DateTime now,
  ) {
    final range = timelineRange(
      cards: [for (final c in cards) (start: c.start, due: c.due!)],
      now: now,
    );

    if (!_centered) _centerOnToday(range, now);

    return Column(
      children: [
        // 表头：月份 + 日期刻度。固定在上面，竖着滚不会跑掉。
        Row(
          children: [
            SizedBox(width: kTitleWidth, child: _headerCorner(theme, k)),
            Expanded(
              child: SingleChildScrollView(
                controller: _headerScroll,
                scrollDirection: Axis.horizontal,
                // 表头自己不该被拖动——它只跟着下面的条区走，
                // 不然两条滚动条抢着改对方的位置。
                physics: const NeverScrollableScrollPhysics(),
                child: _ruler(theme, k, range, now),
              ),
            ),
          ],
        ),
        Expanded(
          child: SingleChildScrollView(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 左边的标题列：跟着竖向滚（在同一个滚动视图里），
                // 但横着滚时钉在原地。
                SizedBox(
                  width: kTitleWidth,
                  child: Column(
                    children: [
                      for (final c in cards) _titleCell(theme, k, c, now),
                    ],
                  ),
                ),
                Expanded(
                  child: Scrollbar(
                    controller: _bodyScroll,
                    // 常驻显示。默认那种滚一下才出现、几秒后淡掉的滚动条，
                    // 等于没有——横向能滚这件事得让人一眼看见。
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      controller: _bodyScroll,
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.only(bottom: 12),
                      child: SizedBox(
                        width: range.totalWidth,
                        child: Column(
                          children: [
                            for (final c in cards)
                              _barRow(theme, k, c, range, now),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _headerCorner(ThemeData theme, KanbanColors k) {
    return Container(
      height: 46,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.only(left: 16),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: k.hairline),
          right: BorderSide(color: k.hairline),
        ),
      ),
      child: Text(
        '卡片',
        style: theme.textTheme.labelSmall?.copyWith(color: k.cardBody),
      ),
    );
  }

  /// 日期刻度。
  ///
  /// **日期不是每格都写**——36 像素放不下「9月24日」。每周一写一次，
  /// 再在上面一行标月份，这样既认得出日子，又能一屏塞进一个月。
  Widget _ruler(
    ThemeData theme,
    KanbanColors k,
    TimelineRange range,
    DateTime now,
  ) {
    final todayIndex = range.indexOf(dateOnly(now));

    return SizedBox(
      width: range.totalWidth,
      height: 46,
      child: Column(
        children: [
          SizedBox(
            height: 20,
            child: Stack(
              children: [
                for (var i = 0; i < range.dayCount; i++)
                  if (range.dayAt(i).day == 1 || i == 0)
                    Positioned(
                      left: i * kDayWidth + 3,
                      top: 2,
                      child: Text(
                        '${range.dayAt(i).year}年${range.dayAt(i).month}月',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: k.cardBody,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
              ],
            ),
          ),
          Expanded(
            child: Row(
              children: [
                for (var i = 0; i < range.dayCount; i++)
                  _rulerCell(theme, k, range.dayAt(i), i == todayIndex),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _rulerCell(
    ThemeData theme,
    KanbanColors k,
    DateTime day,
    bool isToday,
  ) {
    final weekend =
        day.weekday == DateTime.saturday || day.weekday == DateTime.sunday;

    return Container(
      width: kDayWidth,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isToday
            ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.10)
            : (weekend ? k.hairline.withValues(alpha: 0.35) : null),
        border: Border(
          bottom: BorderSide(color: k.hairline),
          left: BorderSide(color: k.hairline.withValues(alpha: 0.5)),
        ),
      ),
      child: Text(
        // 每周一写一次日期，其余只写号数——一整排「9月24日」会挤成一团。
        day.weekday == DateTime.monday ? '${day.month}/${day.day}' : '${day.day}',
        style: theme.textTheme.labelSmall?.copyWith(
          fontSize: day.weekday == DateTime.monday ? 10 : 10.5,
          color: isToday
              ? Theme.of(context).colorScheme.primary
              : k.cardBody.withValues(alpha: weekend ? 0.6 : 0.9),
          fontWeight: day.weekday == DateTime.monday || isToday
              ? FontWeight.w600
              : FontWeight.w400,
        ),
      ),
    );
  }

  Widget _titleCell(
    ThemeData theme,
    KanbanColors k,
    CardRow card,
    DateTime now,
  ) {
    final status = cardDeadlineStatus(card, now);
    final alarm = dueStripeColor(k, status);

    return InkWell(
      onTap: () => showCardDetail(context, widget.boardId, card.id),
      child: Container(
        height: kRowHeight,
        padding: const EdgeInsets.only(left: 16, right: 8),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: k.hairline.withValues(alpha: 0.4)),
            right: BorderSide(color: k.hairline),
          ),
        ),
        child: Row(
          children: [
            if (card.done)
              Icon(Icons.check_circle, size: 13, color: k.doneStripe)
            else if (alarm != null)
              Icon(Icons.circle, size: 8, color: alarm)
            else
              Icon(
                Icons.circle_outlined,
                size: 8,
                color: k.cardBody.withValues(alpha: 0.4),
              ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                card.title.isEmpty ? '未命名' : card.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: card.title.isEmpty
                      ? k.cardBody.withValues(alpha: 0.6)
                      : k.cardTitle,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _barRow(
    ThemeData theme,
    KanbanColors k,
    CardRow card,
    TimelineRange range,
    DateTime now,
  ) {
    final bar = barFor(
      start: card.start,
      due: card.due!,
      range: range,
      now: now,
    );
    final status = cardDeadlineStatus(card, now);
    final todayIndex = range.indexOf(dateOnly(now));

    // 条的颜色：报警色优先，其次完成绿，最后才是卡片自己的颜色。
    final color = switch (status) {
      DeadlineStatus.overdue => k.overdueStripe,
      DeadlineStatus.soon => k.dueSoonStripe,
      DeadlineStatus.done => k.doneStripe,
      _ => k.accent(card.color),
    };

    return SizedBox(
      height: kRowHeight,
      child: Stack(
        children: [
          // 背景的格线和今天那道竖线。画在条下面，条才不会被线切开。
          Positioned.fill(
            child: Row(
              children: [
                for (var i = 0; i < range.dayCount; i++)
                  Container(
                    width: kDayWidth,
                    decoration: BoxDecoration(
                      color: i == todayIndex
                          ? theme.colorScheme.primary.withValues(alpha: 0.07)
                          : ((range.dayAt(i).weekday == DateTime.saturday ||
                                    range.dayAt(i).weekday == DateTime.sunday)
                                ? k.hairline.withValues(alpha: 0.25)
                                : null),
                      border: Border(
                        bottom: BorderSide(
                          color: k.hairline.withValues(alpha: 0.4),
                        ),
                        left: BorderSide(
                          color: k.hairline.withValues(alpha: 0.35),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Positioned(
            left: bar.left,
            top: (kRowHeight - kBarHeight) / 2,
            width: bar.width,
            height: kBarHeight,
            child: Tooltip(
              message: _barTooltip(card, bar, now),
              waitDuration: const Duration(milliseconds: 400),
              child: InkWell(
                onTap: () => showCardDetail(context, widget.boardId, card.id),
                borderRadius: BorderRadius.circular(4),
                child: Container(
                  decoration: BoxDecoration(
                    // 开始时间是推算的就画淡一点——这根条的左端不作准，
                    // 不该和真排过期的条长得一样确定。
                    color: color.withValues(alpha: bar.inferredStart ? 0.45 : 1),
                    borderRadius: BorderRadius.circular(4),
                    border: bar.inferredStart
                        ? Border.all(color: color, width: 1)
                        : null,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _barTooltip(CardRow card, TimelineBar bar, DateTime now) {
    final due = formatDueDate(card.due!, now);
    if (bar.inferredStart) {
      return '${card.title.isEmpty ? '未命名' : card.title}\n'
          '截止 $due（没设开始时间，条从今天画起）';
    }
    return '${card.title.isEmpty ? '未命名' : card.title}\n'
        '${formatDueDate(card.start!, now)} → $due';
  }

  /// 底部那条「没排期的卡片」。
  ///
  /// 默认收起来只留一行——它是给「想排但还没排」的卡片留的入口，
  /// 不该和真正排好的进度抢地方。
  Widget _unscheduledSection(
    ThemeData theme,
    KanbanColors k,
    List<CardRow> cards,
  ) {
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: k.hairline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _showUnscheduled = !_showUnscheduled),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 9, 16, 9),
              child: Row(
                children: [
                  Icon(
                    _showUnscheduled ? Icons.expand_more : Icons.chevron_right,
                    size: 17,
                    color: k.cardBody,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '未排期 ${cards.length} 张',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: k.cardBody,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '点开可以给它们设截止日期',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: k.cardBody.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_showUnscheduled)
            ConstrainedBox(
              // 未排期的卡片可能很多，不能让它把时间轴顶出屏幕。
              constraints: const BoxConstraints(maxHeight: 190),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: cards.length,
                itemBuilder: (context, i) {
                  final card = cards[i];
                  return ListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    title: Text(
                      card.title.isEmpty ? '未命名' : card.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium,
                    ),
                    trailing: TextButton(
                      onPressed: () => _scheduleToday(card),
                      child: const Text('设为今天'),
                    ),
                    onTap: () =>
                        showCardDetail(context, widget.boardId, card.id),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  /// 一键排到今天 23:59。
  ///
  /// 「未排期」列表里最常做的动作就是把某张卡拽进今天，为这个再开一次
  /// 详情、翻一次日历不值得。想设别的日子点标题进详情。
  void _scheduleToday(CardRow card) {
    final today = DateTime.now();
    ref.read(repositoryProvider).setCardDate(
      widget.boardId,
      card.id,
      CardF.due,
      combineDayTime(dateOnly(today), kDefaultDueSeconds),
    );
  }
}
