import 'package:flutter/material.dart';

import '../responsive.dart';
import '../theme/app_theme.dart';
import '../theme/palette.dart';

/// 问一个名字（看板、标签都用它）。返回 null 表示用户取消。
Future<String?> promptName(
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
        width: dialogWidth(context, 320),
        child: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '名称'),
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

/// 挑色的结果。
///
/// **必须和「取消」区分开。** 以前这个函数直接返回 `String?`，null 同时
/// 表示「用户取消了」和「用户想要无色」——两个意思挤在一个返回值上，
/// 结果就是**选了颜色之后再也回不到无色**，只能一直换着颜色用。
@immutable
class SwatchChoice {
  /// 选中的色板 key；null 表示**明确选择无色**。
  final String? key;

  const SwatchChoice(this.key);
}

/// 从预设色板里挑一色。返回 null 表示**取消**，返回 [SwatchChoice] 且
/// key 为 null 表示**选了「无色」**。
///
/// 不提供任意取色器：个人取色十有八九会把画布搞得很花，预设色板能保证
/// 怎么点都好看，深浅两个主题下也各有一套经过对比度校验的值。
Future<SwatchChoice?> pickSwatch(
  BuildContext context, {
  String? current,
  /// 允不允许选「无色」。
  ///
  /// 卡片和看板可以没有颜色；**标签不行**——标签的颜色是它在分组视图和
  /// 卡片上的识别标志，没颜色就没法认。设计里定的是标签必须有色，默认给灰。
  bool allowNone = true,
}) {
  return showDialog<SwatchChoice>(
    context: context,
    builder: (context) {
      final k = Theme.of(context).kanban;
      return AlertDialog(
        title: const Text('选择颜色'),
        content: SizedBox(
          width: dialogWidth(context, 328),
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              // 「无色」排在最前：它是卡片最初的样子，回到原状应该最好找。
              if (allowNone)
                _NoColorButton(
                  selected: current == null,
                  colors: k,
                  onTap: () => Navigator.pop(context, const SwatchChoice(null)),
                ),
              for (final swatch in kSwatches)
                _SwatchButton(
                  swatch: swatch,
                  selected: swatch.key == current,
                  colors: k,
                  onTap: () => Navigator.pop(context, SwatchChoice(swatch.key)),
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

/// 「无色」那一格：一个带斜杠的空心圆。
class _NoColorButton extends StatelessWidget {
  final bool selected;
  final KanbanColors colors;
  final VoidCallback onTap;

  const _NoColorButton({
    required this.selected,
    required this.colors,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: '无色',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: Container(
          width: 62,
          height: 46,
          decoration: BoxDecoration(
            color: colors.cardPlain,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: selected ? theme.colorScheme.primary : colors.cardBorder,
              width: selected ? 2 : 1,
            ),
          ),
          child: Center(
            child: Icon(
              Icons.format_color_reset_outlined,
              size: 18,
              color: colors.cardBody,
            ),
          ),
        ),
      ),
    );
  }
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
