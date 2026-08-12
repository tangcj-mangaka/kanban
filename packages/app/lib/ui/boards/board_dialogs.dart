import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/palette.dart';

/// 问一个看板名字。返回 null 表示用户取消。
Future<String?> promptBoardName(
  BuildContext context, {
  required String title,
  String initial = '',
}) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 320,
        child: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '看板名称'),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text.trim()),
          child: const Text('确定'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (result == null || result.isEmpty) return null;
  return result;
}

/// 从预设色板里挑一色。返回 null 表示取消。
///
/// 不提供任意取色器：个人取色十有八九会把画布搞得很花，预设色板能保证
/// 怎么点都好看，深浅两个主题下也各有一套经过对比度校验的值。
Future<String?> pickSwatch(BuildContext context, {String? current}) {
  return showDialog<String>(
    context: context,
    builder: (context) {
      final k = Theme.of(context).kanban;
      return AlertDialog(
        title: const Text('选择颜色'),
        content: SizedBox(
          width: 328,
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final swatch in kSwatches)
                _SwatchButton(
                  swatch: swatch,
                  selected: swatch.key == current,
                  colors: k,
                  onTap: () => Navigator.pop(context, swatch.key),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        ],
      );
    },
  );
}

class _SwatchButton extends StatelessWidget {
  final Swatch swatch;
  final bool selected;
  final KanbanColors colors;
  final VoidCallback onTap;

  const _SwatchButton({
    required this.swatch,
    required this.selected,
    required this.colors,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tones = swatch.tones(colors.brightness);
    return Tooltip(
      message: swatch.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: Container(
          width: 52,
          height: 46,
          decoration: BoxDecoration(
            color: tones.surface,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: selected ? tones.accent : colors.cardBorder,
              width: selected ? 2 : 1,
            ),
          ),
          child: Center(
            child: Container(
              width: 13,
              height: 13,
              decoration: BoxDecoration(
                color: tones.accent,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 删除看板前的强确认。
Future<bool> confirmDeleteBoard(BuildContext context, String name) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('删除看板'),
      content: Text(
        '「${name.isEmpty ? '未命名看板' : name}」及其中的全部卡片都会被删除。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  return ok ?? false;
}
