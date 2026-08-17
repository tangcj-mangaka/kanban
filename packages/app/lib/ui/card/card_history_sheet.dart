import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared/shared.dart';

import '../../data/repository.dart';
import '../../providers.dart';
import '../format.dart';
import '../responsive.dart';
import '../theme/app_theme.dart';
import '../theme/palette.dart';

/// 一张卡片的改动记录。
///
/// 存在的理由：多台设备离线各自改了同一张卡片、连上服务器后只有一个版本
/// 留在卡片上——**输掉的那些内容不会消失，但也不会露面**。它们一直在
/// op 日志里，这个面板就是把它们翻出来的地方。
///
/// 这里**不做「解决冲突」的流程**。卡片当前内容照旧由字段级 LWW 决定，
/// 面板只负责让人看见、并且能一键把某个旧值放回去。不引入「这张卡片处于
/// 冲突状态、必须先处理」这种会卡住正常使用的状态。
Future<void> showCardHistory(
  BuildContext context,
  String boardId,
  String cardId,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => _HistoryDialog(boardId: boardId, cardId: cardId),
  );
}

class _HistoryDialog extends ConsumerWidget {
  final String boardId;
  final String cardId;

  const _HistoryDialog({required this.boardId, required this.cardId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final k = theme.kanban;
    final changes = ref.watch(cardChangesProvider(cardId)).value;
    final names = ref.watch(deviceNamesProvider).value ?? const {};

    return AlertDialog(
      title: const Text('改动记录'),
      content: SizedBox(
        width: dialogWidth(context, 520),
        height: dialogHeight(context, fraction: 0.6),
        child: switch (changes) {
          null => const Center(child: CircularProgressIndicator()),
          [] => Center(
            child: Text(
              '还没有改动',
              style: theme.textTheme.bodyMedium?.copyWith(color: k.cardBody),
            ),
          ),
          final list => ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, _) => Divider(height: 18, color: k.hairline),
            itemBuilder: (context, i) => _ChangeRow(
              boardId: boardId,
              cardId: cardId,
              change: list[i],
              deviceNames: names,
            ),
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

class _ChangeRow extends ConsumerWidget {
  final String boardId;
  final String cardId;
  final CardChange change;
  final Map<String, String> deviceNames;

  const _ChangeRow({
    required this.boardId,
    required this.cardId,
    required this.change,
    required this.deviceNames,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final k = theme.kanban;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              _fieldLabel(change.field),
              style: theme.textTheme.labelMedium?.copyWith(
                color: k.cardTitle,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            if (change.current)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '当前',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            const Spacer(),
            // 没同步出去的改动标一下：它在别的设备上还看不到。
            if (change.seq == null)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(
                  Icons.cloud_off_outlined,
                  size: 13,
                  color: k.cardBody.withValues(alpha: 0.7),
                ),
              ),
            Text(
              _deviceLabel(),
              style: theme.textTheme.labelSmall?.copyWith(color: k.cardBody),
            ),
            const SizedBox(width: 8),
            Text(
              relativeTime(change.wallTs),
              style: theme.textTheme.labelSmall?.copyWith(
                color: k.cardBody.withValues(alpha: 0.75),
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        Text(
          _valueLabel(change.value),
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: k.cardBody,
            height: 1.5,
            fontStyle: change.value == null || change.value == ''
                ? FontStyle.italic
                : null,
          ),
        ),
        if (!change.current && _restorable) ...[
          const SizedBox(height: 3),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => ref
                  .read(repositoryProvider)
                  .restoreCardValue(
                    boardId,
                    cardId,
                    change.field,
                    change.value,
                  ),
              icon: const Icon(Icons.restore, size: 15),
              label: const Text('恢复这个值'),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// 删除和归档不给「恢复」按钮。
  ///
  /// 那两个字段有各自专门的入口（干草仓库的捞回、彻底删除），在这里
  /// 再放一个含义模糊的「恢复」只会让人搞不清点了会发生什么。
  bool get _restorable =>
      change.field != kDeleted && change.field != CardF.archived;

  String _deviceLabel() {
    final name = deviceNames[change.deviceId];
    if (name != null && name.isNotEmpty) return name;
    // 名单还没同步到（或者从没连过服务器）时退回短 ID——总比什么都不显示好，
    // 至少能区分出「这是另一台设备改的」。
    final id = change.deviceId;
    if (id == 'local') return '本机';
    return '设备 ${id.length > 6 ? id.substring(0, 6) : id}';
  }

  static String _fieldLabel(String field) => switch (field) {
    CardF.title => '标题',
    CardF.body => '正文',
    CardF.color => '颜色',
    CardF.done => '完成状态',
    CardF.archived => '归档状态',
    kDeleted => '删除状态',
    _ => field,
  };

  String _valueLabel(Object? value) {
    // 颜色存的是色板 key（blue、pink…），直接显示对用户没意义，
    // 翻成色板上那个中文名。
    if (change.field == CardF.color) {
      if (value == null) return '无色';
      return kSwatchByKey['$value']?.label ?? '$value';
    }
    return switch (value) {
      null => '（清空）',
      '' => '（空）',
      true => '是',
      false => '否',
      final s => '$s',
    };
  }
}
