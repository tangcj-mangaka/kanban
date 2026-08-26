import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../providers.dart';
import '../card/attachment_add.dart';
import '../card/card_detail_dialog.dart';
import '../responsive.dart';
import '../theme/app_theme.dart';

/// 从系统分享面板收到文件后，问一句「放到哪张卡片」。
///
/// 为什么要问而不是自动放：分享进来的东西没有上下文——系统只给了文件，
/// 不知道它属于哪块看板、哪张卡片。默默塞到某个地方，用户回头根本找不着。
///
/// 但也不该问太多。所以只有一层：**选一块看板**（记住上次选的），
/// 然后要么点「新建一张卡片」，要么点列表里已有的某张。选完直接打开那张
/// 卡片的详情——你分享图片进来，多半就是想接着写点什么。
Future<void> showShareTarget(
  BuildContext context,
  List<({String path, String name})> files,
) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ShareTargetSheet(files: files),
  );
}

class _ShareTargetSheet extends ConsumerStatefulWidget {
  final List<({String path, String name})> files;

  const _ShareTargetSheet({required this.files});

  @override
  ConsumerState<_ShareTargetSheet> createState() => _ShareTargetSheetState();
}

class _ShareTargetSheetState extends ConsumerState<_ShareTargetSheet> {
  String? _boardId;
  bool _working = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final k = theme.kanban;
    final boards = ref.watch(boardSummariesProvider).value ?? const [];

    if (boards.isEmpty) {
      return AlertDialog(
        title: const Text('还没有看板'),
        content: const Text('先建一块看板，再往里分享东西。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      );
    }

    // 默认选第一块（列表按 sortOrder 排，第一块通常就是最常用的那块）。
    final boardId = _boardId ??= boards.first.board.id;
    final cards = ref.watch(canvasCardsProvider(boardId)).value ?? const [];

    return AlertDialog(
      title: Text(
        widget.files.length == 1
            ? '把「${widget.files.single.name}」放到'
            : '把 ${widget.files.length} 个文件放到',
        style: theme.textTheme.titleMedium,
      ),
      content: SizedBox(
        width: dialogWidth(context, 420),
        height: dialogHeight(context, fraction: 0.6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              initialValue: boardId,
              decoration: const InputDecoration(
                labelText: '看板',
                isDense: true,
              ),
              items: [
                for (final b in boards)
                  DropdownMenuItem(
                    value: b.board.id,
                    child: Text(
                      b.board.name.isEmpty ? '未命名看板' : b.board.name,
                    ),
                  ),
              ],
              onChanged: _working
                  ? null
                  : (v) => setState(() => _boardId = v),
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: _working ? null : () => _addToNewCard(boardId),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('新建一张卡片'),
            ),
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                cards.isEmpty ? '这块板还没有卡片' : '或者加到已有的卡片上',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: k.cardBody,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: ListView.builder(
                itemCount: cards.length,
                itemBuilder: (context, i) {
                  final card = cards[i];
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      card.title.isEmpty ? '未命名' : card.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: _working
                        ? null
                        : () => _addTo(boardId, card.id, open: true),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _working ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    );
  }

  Future<void> _addToNewCard(String boardId) async {
    setState(() => _working = true);
    final repo = ref.read(repositoryProvider);

    // 用第一个文件的名字当标题——总比「未命名」强，用户想改随时能改。
    final title = p.basenameWithoutExtension(widget.files.first.name);
    final cardId = await repo.createCard(
      boardId: boardId,
      x: 40,
      y: 40,
      title: title,
    );
    await _addTo(boardId, cardId, open: true);
  }

  Future<void> _addTo(
    String boardId,
    String cardId, {
    required bool open,
  }) async {
    setState(() => _working = true);
    await addAttachmentFiles(
      ref,
      boardId: boardId,
      cardId: cardId,
      files: widget.files,
    );

    if (!mounted) return;
    Navigator.pop(context);
    if (open) await showCardDetail(context, boardId, cardId);
  }
}

/// 分享进来的文件可能落在应用私有的临时目录里，系统随时会清。
///
/// 导入那一步会把内容按哈希拷进自己的缓存，所以拷完原文件就没用了——
/// 这里只是顺手擦掉，别让它们在缓存目录里越积越多。
Future<void> cleanupSharedFiles(List<String> paths) async {
  for (final path in paths) {
    try {
      final f = File(path);
      if (f.existsSync()) await f.delete();
    } on FileSystemException {
      // 删不掉就算了，系统自己会清。
    }
  }
}
