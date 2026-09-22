import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared/shared.dart';

import '../../data/database.dart';
import '../../providers.dart';
import '../deadline.dart';
import '../theme/app_theme.dart';

/// 卡片详情里的排期区：开始时间和截止时间。
///
/// **没设日期时只露一个「+ 截止日期」**，点了才展开。否则每张卡片顶上都
/// 挂着两个空日期框——绝大多数卡片根本不需要排期。
class CardDates extends ConsumerStatefulWidget {
  final String boardId;
  final CardRow card;

  const CardDates({super.key, required this.boardId, required this.card});

  @override
  ConsumerState<CardDates> createState() => _CardDatesState();
}

class _CardDatesState extends ConsumerState<CardDates> {
  /// 手动展开过。卡片本身有日期时不需要它——那种情况直接就是展开的。
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final k = theme.kanban;
    final card = widget.card;
    final hasDates = card.due != null || card.start != null;

    if (!hasDates && !_expanded) {
      return Padding(
        padding: const EdgeInsets.only(left: 27),
        child: Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() => _expanded = true),
            icon: const Icon(Icons.schedule, size: 15),
            label: const Text('截止日期'),
            style: TextButton.styleFrom(
              foregroundColor: k.cardBody,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ),
      );
    }

    // 开始晚于截止：不拦，只提醒。本地优先架构下别的设备也能改出这种
    // 状态，硬拦在输入处没有意义——时间轴那边按「只有截止日」画。
    final inverted =
        card.start != null && card.due != null && card.start! > card.due!;

    return Padding(
      padding: const EdgeInsets.only(left: 27, right: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DateRow(
            label: '截止',
            millis: card.due,
            defaultSeconds: kDefaultDueSeconds,
            emphasize: true,
            onChanged: (at) => _save(CardF.due, at),
          ),
          const SizedBox(height: 6),
          _DateRow(
            label: '开始',
            millis: card.start,
            defaultSeconds: kDefaultStartSeconds,
            emphasize: false,
            onChanged: (at) => _save(CardF.start, at),
          ),
          if (inverted)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '开始时间晚于截止时间，时间轴里会按「只有截止」画',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: k.overdueStripe,
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _save(String field, DateTime? at) {
    ref
        .read(repositoryProvider)
        .setCardDate(widget.boardId, widget.card.id, field, at);
  }
}

/// 一行日期：`[日历 9月25日] [23:59] [×]`，没设时是一排快捷按钮。
class _DateRow extends StatefulWidget {
  final String label;
  final int? millis;

  /// 刚设上日期时用哪个钟点。截止是 23:59，开始是 00:00。
  final int defaultSeconds;

  /// 截止那一行更重要，字重高一档。
  final bool emphasize;

  final ValueChanged<DateTime?> onChanged;

  const _DateRow({
    required this.label,
    required this.millis,
    required this.defaultSeconds,
    required this.emphasize,
    required this.onChanged,
  });

  @override
  State<_DateRow> createState() => _DateRowState();
}

class _DateRowState extends State<_DateRow> {
  final _timeController = TextEditingController();
  final _timeFocus = FocusNode();

  /// 输入框里的字解析不了。解析不了就不写库，只把框标红。
  bool _timeInvalid = false;

  @override
  void initState() {
    super.initState();
    _syncTimeText();
    // 焦点离开时把框里的字规整回标准写法（`9:5` → `09:05`），
    // 顺便把没提交的坏输入退回上一次的好值。
    _timeFocus.addListener(() {
      if (!_timeFocus.hasFocus) _syncTimeText();
    });
  }

  @override
  void didUpdateWidget(_DateRow old) {
    super.didUpdateWidget(old);
    // 同步过来的改动、或者点了快捷按钮，都要回填到框里。
    // 但正在输入时不能动它，否则打到一半会被抢走。
    if (old.millis != widget.millis && !_timeFocus.hasFocus) _syncTimeText();
  }

  void _syncTimeText() {
    final millis = widget.millis;
    setState(() {
      _timeInvalid = false;
      _timeController.text = millis == null
          ? ''
          : formatDayTime(dayTimeOf(millis));
    });
  }

  @override
  void dispose() {
    _timeController.dispose();
    _timeFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final k = theme.kanban;
    final millis = widget.millis;

    return Row(
      children: [
        SizedBox(
          width: 34,
          child: Text(
            widget.label,
            style: theme.textTheme.labelMedium?.copyWith(color: k.cardBody),
          ),
        ),
        if (millis == null) ..._quickButtons(theme, k) else ..._editors(theme, k, millis),
      ],
    );
  }

  /// 没设日期时：今天 / 明天 / 本周五 / 下周一 / 选日期。
  ///
  /// 九成的排期就是这四个之一，点一下就完，比翻日历快。
  List<Widget> _quickButtons(ThemeData theme, KanbanColors k) {
    final now = DateTime.now();
    return [
      for (final q in quickDays(now))
        Padding(
          padding: const EdgeInsets.only(right: 6),
          child: OutlinedButton(
            onPressed: () =>
                widget.onChanged(combineDayTime(q.day, widget.defaultSeconds)),
            style: OutlinedButton.styleFrom(
              foregroundColor: k.cardBody,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: theme.textTheme.labelSmall,
            ),
            child: Text(q.label),
          ),
        ),
      IconButton(
        onPressed: _pickDate,
        icon: const Icon(Icons.calendar_today_outlined, size: 15),
        tooltip: '选个别的日期',
        color: k.cardBody,
        visualDensity: VisualDensity.compact,
      ),
    ];
  }

  /// 设了日期时：日期按钮 + 可输入的时间框 + 清除。
  List<Widget> _editors(ThemeData theme, KanbanColors k, int millis) {
    final at = DateTime.fromMillisecondsSinceEpoch(millis);
    return [
      OutlinedButton.icon(
        onPressed: _pickDate,
        icon: const Icon(Icons.calendar_today_outlined, size: 14),
        label: Text(formatDayLabel(at, withYear: at.year != DateTime.now().year)),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          minimumSize: const Size(0, 30),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: theme.textTheme.labelMedium?.copyWith(
            fontWeight: widget.emphasize ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
      const SizedBox(width: 8),
      SizedBox(
        width: 92,
        child: TextField(
          controller: _timeController,
          focusNode: _timeFocus,
          style: theme.textTheme.labelMedium,
          textAlign: TextAlign.center,
          // 只放行时间里用得上的字符。中文冒号也放行——中文输入法下
          // 打出 `23：59` 是常事，解析那边认，这里就不该把它挡在门外。
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9:：]')),
            LengthLimitingTextInputFormatter(8),
          ],
          decoration: InputDecoration(
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            hintText: '23:59',
            errorText: _timeInvalid ? '' : null,
            errorStyle: const TextStyle(height: 0, fontSize: 0),
          ),
          onChanged: (raw) => _applyTime(millis, raw),
          onSubmitted: (_) => _timeFocus.unfocus(),
        ),
      ),
      const SizedBox(width: 2),
      IconButton(
        onPressed: () => widget.onChanged(null),
        icon: const Icon(Icons.close, size: 15),
        tooltip: '清除',
        color: k.cardBody,
        visualDensity: VisualDensity.compact,
      ),
    ];
  }

  /// 边打边存，但只在这一刻解析得出来时才存。
  ///
  /// 打 `23:59` 的过程中会经过 `2`、`23`、`23:`，这些都不是合法时间。
  /// 那几帧只把框标红，不写库——不能因为打了一半就把日期改坏。
  void _applyTime(int millis, String raw) {
    final seconds = parseDayTime(raw);
    setState(() => _timeInvalid = seconds == null && raw.trim().isNotEmpty);
    if (seconds == null) return;
    widget.onChanged(
      combineDayTime(DateTime.fromMillisecondsSinceEpoch(millis), seconds),
    );
  }

  Future<void> _pickDate() async {
    final current = widget.millis == null
        ? DateTime.now()
        : DateTime.fromMillisecondsSinceEpoch(widget.millis!);

    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      // 往前也留出余地：补记一件早该做完的事是常有的。
      firstDate: DateTime(current.year - 5),
      lastDate: DateTime(current.year + 10),
      helpText: '选择${widget.label}日期',
    );
    if (picked == null) return;

    // 只换日期，钟点保留——改期一般是改哪天，不是改几点。
    final seconds =
        widget.millis == null ? widget.defaultSeconds : dayTimeOf(widget.millis!);
    widget.onChanged(combineDayTime(picked, seconds));
  }
}
