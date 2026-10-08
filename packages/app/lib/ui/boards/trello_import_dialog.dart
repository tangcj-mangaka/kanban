import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/trello/trello_export.dart';
import '../../data/trello/trello_import.dart';
import '../../providers.dart';
import '../responsive.dart';
import '../theme/app_theme.dart';

/// 从 Trello 的 JSON 导出文件建一块看板。
///
/// **先看清楚再写。** 一份导出动辄几百张卡片，闷头导进去再发现映射不对，
/// 只能整块删了重来。所以这个弹窗把「会建成什么样」摆在前面：多少张卡、
/// 多少个标签，以及那几个只有用户自己知道答案的选择。
Future<void> showTrelloImport(BuildContext context) async {
  const type = XTypeGroup(label: 'Trello 导出', extensions: ['json']);
  final file = await openFile(acceptedTypeGroups: const [type]);
  if (file == null || !context.mounted) return;

  final String text;
  try {
    text = await File(file.path).readAsString();
  } on FileSystemException catch (e) {
    if (context.mounted) _tell(context, '读不了这个文件：${e.message}');
    return;
  }

  final TrelloBoard board;
  try {
    board = parseTrelloExport(text);
  } on TrelloParseException catch (e) {
    if (context.mounted) _tell(context, '$e');
    return;
  }

  if (!context.mounted) return;
  await showTrelloImportFor(context, board);
}

/// 对一块**已经解析好**的看板开导入弹窗。
///
/// 和 [showTrelloImport] 分开，是为了截图验证时能绕过选文件那一步——
/// 文件对话框是系统的，自动化点不动。
Future<void> showTrelloImportFor(BuildContext context, TrelloBoard board) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ImportDialog(board: board),
  );
}

void _tell(BuildContext context, String message) {
  showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('导入不了'),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}

class _ImportDialog extends ConsumerStatefulWidget {
  final TrelloBoard board;

  const _ImportDialog({required this.board});

  @override
  ConsumerState<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends ConsumerState<_ImportDialog> {
  String? _doneLabel;
  String? _archiveLabel;
  bool _labelsAsColor = true;

  bool _running = false;
  int _progress = 0;

  @override
  void initState() {
    super.initState();
    // 猜一下哪个标签表示「做完了」。猜中是省事，猜不中用户一眼就能改——
    // 总比让人在九个标签里自己找强。
    for (final l in widget.board.usedLabels) {
      final n = l.name.toLowerCase();
      if (n.contains('通过') ||
          n.contains('完成') ||
          n.contains('done') ||
          n.contains('complete') ||
          n.contains('finish')) {
        _doneLabel = l.id;
        break;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final k = theme.kanban;
    final board = widget.board;
    final counts = board.labelCounts;

    final statusLabels = [
      for (final l in board.usedLabels)
        if (l.id != _doneLabel && l.id != _archiveLabel) l,
    ];
    final doneCount = _doneLabel == null ? 0 : counts[_doneLabel] ?? 0;
    final archiveCount =
        _archiveLabel == null ? 0 : counts[_archiveLabel] ?? 0;
    final tagCount =
        board.usedLists.length + (_labelsAsColor ? 0 : statusLabels.length);

    return AlertDialog(
      title: Text('从 Trello 导入「${board.name}」',
          style: theme.textTheme.titleMedium),
      content: SizedBox(
        width: dialogWidth(context, 520),
        height: dialogHeight(context, fraction: 0.78),
        child: _running
            ? _progressView(theme, k)
            : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _summary(theme, k, tagCount, doneCount, archiveCount),
                    const SizedBox(height: 16),
                    // 两个下拉并排。竖着排的话，下面那个「剩下的标签怎么办」
                    // 会被挤到折叠线以下——那恰恰是最该让人看见的选择。
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _labelPicker(
                            theme,
                            k,
                            title: '哪个标签表示「做完了」',
                            hint: '这些卡片直接打勾',
                            value: _doneLabel,
                            exclude: _archiveLabel,
                            onChanged: (v) => setState(() => _doneLabel = v),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: _labelPicker(
                            theme,
                            k,
                            title: '哪个标签表示「废弃」',
                            hint: '这些卡片收进干草仓库',
                            value: _archiveLabel,
                            exclude: _doneLabel,
                            onChanged: (v) => setState(() => _archiveLabel = v),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _labelModePicker(theme, k, statusLabels),
                  ],
                ),
              ),
      ),
      actions: _running
          ? null
          : [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: _run,
                child: Text('导入 ${board.cards.length} 张卡片'),
              ),
            ],
    );
  }

  Widget _summary(
    ThemeData theme,
    KanbanColors k,
    int tagCount,
    int doneCount,
    int archiveCount,
  ) {
    final board = widget.board;
    final withDue = board.cards.where((c) => c.due != null).length;
    final comments =
        board.cards.fold<int>(0, (n, c) => n + c.comments.length);
    final attachments =
        board.cards.where((c) => c.attachmentNames.isNotEmpty).length;
    final emptyLists = board.lists.length - board.usedLists.length;

    final lines = <String>[
      '${board.cards.length} 张卡片 → 新建一块看板',
      '${board.usedLists.length} 个列表 → 标签'
          '${emptyLists > 0 ? '（$emptyLists 个空列表跳过）' : ''}',
      if (doneCount > 0) '$doneCount 张打勾',
      if (archiveCount > 0) '$archiveCount 张收进干草仓库',
      if (withDue > 0) '$withDue 张带截止日期',
      if (comments > 0) '$comments 条评论（保留原始时间）',
      if (attachments > 0) '$attachments 张卡片有附件，只能留下文件名',
    ];

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: k.hairline.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                '· $line',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: k.cardTitle,
                  height: 1.5,
                ),
              ),
            ),
          const SizedBox(height: 4),
          Text(
            '一共会建 $tagCount 个标签。导完不满意就把整块板删了重导，'
            '不会动到你已有的看板。',
            style: theme.textTheme.labelSmall?.copyWith(
              color: k.cardBody,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _labelPicker(
    ThemeData theme,
    KanbanColors k, {
    required String title,
    required String hint,
    required String? value,
    required String? exclude,
    required ValueChanged<String?> onChanged,
  }) {
    final counts = widget.board.labelCounts;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: theme.textTheme.labelLarge
                ?.copyWith(fontWeight: FontWeight.w600)),
        Text(hint,
            style: theme.textTheme.labelSmall?.copyWith(color: k.cardBody)),
        const SizedBox(height: 6),
        DropdownButtonFormField<String?>(
          initialValue: value,
          isDense: true,
          decoration: const InputDecoration(isDense: true),
          items: [
            const DropdownMenuItem(value: null, child: Text('不指定')),
            for (final l in widget.board.usedLabels)
              if (l.id != exclude)
                DropdownMenuItem(
                  value: l.id,
                  child: Text('${l.displayName}（${counts[l.id]} 张）'),
                ),
          ],
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _labelModePicker(
    ThemeData theme,
    KanbanColors k,
    List<TrelloLabel> statusLabels,
  ) {
    final affected = widget.board.cards
        .where((c) => c.labelIds.any((id) => statusLabels.any((l) => l.id == id)))
        .length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('剩下的 ${statusLabels.length} 个标签怎么办',
            style: theme.textTheme.labelLarge
                ?.copyWith(fontWeight: FontWeight.w600)),
        Text(
          '影响 $affected 张卡片：'
          '${statusLabels.map((l) => l.displayName).join('、')}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall?.copyWith(color: k.cardBody),
        ),
        RadioGroup<bool>(
          groupValue: _labelsAsColor,
          onChanged: (v) => setState(() => _labelsAsColor = v ?? true),
          child: const Row(
            children: [
              Expanded(
                child: RadioListTile<bool>(
                  value: true,
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text('变成卡片颜色'),
                ),
              ),
              Expanded(
                child: RadioListTile<bool>(
                  value: false,
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text('也变成标签'),
                ),
              ),
            ],
          ),
        ),
        Text(
          _labelsAsColor
              ? '分组视图只剩 ${widget.board.usedLists.length} 个模块列，干净；代价是标签的文字没了，只剩颜色。'
              : '标签文字留着；代价是分组视图会多出 ${statusLabels.length} 个状态列，同一张卡在两处出现。',
          style: theme.textTheme.labelSmall?.copyWith(
            color: k.cardBody,
            height: 1.5,
          ),
        ),
      ],
    );
  }

  Widget _progressView(ThemeData theme, KanbanColors k) {
    final total = widget.board.cards.length;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 220,
            child: LinearProgressIndicator(
              value: total == 0 ? null : _progress / total,
            ),
          ),
          const SizedBox(height: 14),
          Text('正在导入 $_progress / $total',
              style: theme.textTheme.labelMedium?.copyWith(color: k.cardBody)),
        ],
      ),
    );
  }

  Future<void> _run() async {
    setState(() => _running = true);

    final result = await importTrelloBoard(
      ref.read(repositoryProvider),
      widget.board,
      options: TrelloImportOptions(
        doneLabelId: _doneLabel,
        archiveLabelId: _archiveLabel,
        labelsAsColor: _labelsAsColor,
      ),
      // 攒够一点再刷新：400 多张卡片每张都 setState，光重建进度条就够呛。
      onProgress: (done, total) {
        if (done % 10 != 0 && done != total) return;
        if (mounted) setState(() => _progress = done);
      },
    );

    if (!mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '「${result.boardName}」导好了：${result.cards} 张卡片、'
          '${result.tags} 个标签、${result.done} 张打勾'
          '${result.comments > 0 ? '、${result.comments} 条评论' : ''}',
        ),
        behavior: SnackBarBehavior.floating,
        width: 520,
      ),
    );
  }
}
