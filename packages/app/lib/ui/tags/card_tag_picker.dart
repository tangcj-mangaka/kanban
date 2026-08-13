import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared/shared.dart';

import '../../providers.dart';
import '../responsive.dart';
import '../theme/app_theme.dart';

/// 给一张卡片挑标签。
///
/// 一张卡片可以打多个标签——分组视图里它会在每个对应的列各出现一份。
/// 所以这里是多选，不是单选。
Future<void> showCardTagPicker(
  BuildContext context,
  WidgetRef ref,
  String boardId,
  String cardId,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => _CardTagPicker(boardId: boardId, cardId: cardId),
  );
}

class _CardTagPicker extends ConsumerStatefulWidget {
  final String boardId;
  final String cardId;

  const _CardTagPicker({required this.boardId, required this.cardId});

  @override
  ConsumerState<_CardTagPicker> createState() => _CardTagPickerState();
}

class _CardTagPickerState extends ConsumerState<_CardTagPicker> {
  final _newTagController = TextEditingController();

  @override
  void dispose() {
    _newTagController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final k = theme.kanban;
    final tags = ref.watch(boardTagsProvider(widget.boardId)).value ?? const [];
    final onCard =
        (ref.watch(cardTagMapProvider(widget.boardId)).value ??
                const <String, List<String>>{})[widget.cardId] ??
            const <String>[];

    return AlertDialog(
      title: const Text('标签'),
      content: SizedBox(
        width: dialogWidth(context, 340),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (tags.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  '这个看板还没有标签。标签只属于本看板，不跨板共用。',
                  style: theme.textTheme.bodySmall?.copyWith(color: k.cardBody),
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final tag in tags)
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: onCard.contains(tag.id),
                        onChanged: (on) => ref
                            .read(repositoryProvider)
                            .setCardTag(
                              widget.boardId,
                              widget.cardId,
                              tag.id,
                              on: on ?? false,
                            ),
                        title: Row(
                          children: [
                            Container(
                              width: 9,
                              height: 9,
                              decoration: BoxDecoration(
                                color: k.accent(tag.color),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Flexible(child: Text(tag.name)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            const Divider(height: 22),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _newTagController,
                    decoration: const InputDecoration(hintText: '新标签名称'),
                    onSubmitted: (_) => _createTag(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: '新建并打到这张卡片上',
                  onPressed: _createTag,
                  icon: const Icon(Icons.add, size: 20),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('完成'),
        ),
      ],
    );
  }

  Future<void> _createTag() async {
    final name = _newTagController.text.trim();
    if (name.isEmpty) return;

    final repo = ref.read(repositoryProvider);
    final existing = ref.read(boardTagsProvider(widget.boardId)).value ?? const [];
    // 新标签的颜色按现有数量往下轮，省得用户每建一个都要挑色，
    // 也避免一板子标签全是同一个颜色。
    final color = kSwatchKeys[existing.length % kSwatchKeys.length];

    final tagId = await repo.createTag(
      boardId: widget.boardId,
      name: name,
      colorKey: color,
    );
    await repo.setCardTag(widget.boardId, widget.cardId, tagId, on: true);
    _newTagController.clear();
  }
}
