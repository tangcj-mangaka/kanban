import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'done_filter.dart';

/// 画布和分组视图工具条上的完成状态筛选开关。
///
/// 点一下轮换：全部 → 未完成 → 已完成 → 全部。做成三态一个按钮而不是
/// 三个单选，是因为工具条上没那么多地方，而且这三个状态天然是一条环。
///
/// 「全部」时故意画得很淡——它是默认状态，不该在工具条上抢眼；
/// 一旦切到筛选状态就上主题色，好让人知道**现在看到的不是全部卡片**。
class DoneFilterButton extends StatelessWidget {
  final DoneFilter value;
  final VoidCallback onTap;

  const DoneFilterButton({
    super.key,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final k = theme.kanban;
    final filtering = value != DoneFilter.all;
    final color = filtering ? theme.colorScheme.primary : k.cardBody;

    return Tooltip(
      message: '按完成状态筛选：${value.label}',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                switch (value) {
                  DoneFilter.all => Icons.filter_list_off_outlined,
                  DoneFilter.todo => Icons.radio_button_unchecked,
                  DoneFilter.done => Icons.task_alt,
                },
                size: 15,
                color: color,
              ),
              const SizedBox(width: 5),
              Text(
                value.label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: color,
                  fontWeight: filtering ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
