import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database.dart';
import '../../providers.dart';
import '../format.dart';
import '../theme/app_theme.dart';

/// 卡片详情里的附件区。
class AttachmentSection extends ConsumerStatefulWidget {
  final String boardId;
  final String cardId;

  const AttachmentSection({
    super.key,
    required this.boardId,
    required this.cardId,
  });

  @override
  ConsumerState<AttachmentSection> createState() => _AttachmentSectionState();
}

class _AttachmentSectionState extends ConsumerState<AttachmentSection> {
  bool _adding = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final k = theme.kanban;
    final list =
        ref.watch(attachmentsProvider(widget.cardId)).value ?? const [];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Row(
            children: [
              Text(
                list.isEmpty ? '附件' : '附件 ${list.length}',
                style: theme.textTheme.labelLarge?.copyWith(color: k.cardBody),
              ),
              const SizedBox(width: 10),
              Expanded(child: Divider(color: k.hairline)),
              const SizedBox(width: 10),
              TextButton.icon(
                onPressed: _adding ? null : _add,
                icon: const Icon(Icons.attach_file, size: 15),
                label: Text(_adding ? '添加中…' : '添加'),
                style: TextButton.styleFrom(
                  foregroundColor: k.cardBody,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
        ),
        if (list.isNotEmpty) ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final a in list)
                  _AttachmentTile(boardId: widget.boardId, attachment: a),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _add() async {
    final files = await openFiles();
    if (files.isEmpty) return;

    setState(() => _adding = true);
    try {
      final store = ref.read(attachmentStoreProvider);
      final repo = ref.read(repositoryProvider);

      for (final picked in files) {
        // 只做本地的事：算哈希、拷贝、生成缩略图。**离线也立刻可用**，
        // 上传是后台的事。
        final imported = await store.importFile(
          File(picked.path),
          displayName: picked.name,
        );
        await repo.addAttachment(
          boardId: widget.boardId,
          cardId: widget.cardId,
          hash: imported.hash,
          filename: imported.filename,
          size: imported.size,
          mime: imported.mime,
          thumbHash: imported.thumbHash,
        );
      }

      // 顺手推一把。连不上也无所谓，文件在队列里等着。
      unawaited(ref.read(attachmentSyncerProvider).flush());
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }
}

class _AttachmentTile extends ConsumerWidget {
  final String boardId;
  final AttachmentRow attachment;

  const _AttachmentTile({required this.boardId, required this.attachment});

  bool get isImage => attachment.mime.startsWith('image/');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final k = theme.kanban;

    return Tooltip(
      message: '${attachment.filename}\n${humanBytes(attachment.size)}',
      child: Material(
        color: k.hairline.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          onTap: () => _open(context, ref),
          borderRadius: BorderRadius.circular(9),
          child: SizedBox(
            width: 132,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(9),
                  ),
                  child: SizedBox(
                    height: 84,
                    child: isImage
                        ? _AttachmentImage(
                            hash: attachment.thumbHash ?? attachment.hash,
                            fit: BoxFit.cover,
                          )
                        : Center(
                            child: Icon(
                              _iconFor(attachment.mime),
                              size: 30,
                              color: k.cardBody,
                            ),
                          ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              attachment.filename,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelMedium?.copyWith(
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            Row(
                              children: [
                                Text(
                                  humanBytes(attachment.size),
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: k.cardBody,
                                  ),
                                ),
                                _PendingBadge(hash: attachment.hash),
                              ],
                            ),
                          ],
                        ),
                      ),
                      InkWell(
                        onTap: () => ref
                            .read(repositoryProvider)
                            .deleteAttachment(boardId, attachment.id),
                        borderRadius: BorderRadius.circular(4),
                        child: Padding(
                          padding: const EdgeInsets.all(3),
                          child: Icon(
                            Icons.close,
                            size: 13,
                            color: k.cardBody.withValues(alpha: 0.7),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    if (isImage) {
      await showDialog<void>(
        context: context,
        builder: (_) => _ImagePreview(attachment: attachment),
      );
      return;
    }

    // 非图片就让用户存到自己想放的地方——应用没法替所有类型的文件
    // 决定用什么打开。
    final bytes = await ref
        .read(attachmentSyncerProvider)
        .fetch(attachment.hash);
    if (bytes == null) {
      if (context.mounted) _showUnavailable(context);
      return;
    }
    final location = await getSaveLocation(suggestedName: attachment.filename);
    if (location == null) return;
    await File(location.path).writeAsBytes(bytes);
  }

  static IconData _iconFor(String mime) {
    if (mime.startsWith('video/')) return Icons.movie_outlined;
    if (mime.startsWith('audio/')) return Icons.audiotrack_outlined;
    if (mime.contains('pdf')) return Icons.picture_as_pdf_outlined;
    if (mime.startsWith('text/')) return Icons.description_outlined;
    if (mime.contains('zip') || mime.contains('compressed')) {
      return Icons.folder_zip_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }
}

/// 还没传上服务端的角标。
///
/// 离线时加的附件停在这个状态。标出来是为了让用户知道「别的设备现在
/// 还看不到它」，而不是以为出了错。
class _PendingBadge extends ConsumerWidget {
  final String hash;

  const _PendingBadge({required this.hash});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(attachmentStoreProvider);
    return FutureBuilder<List<String>>(
      future: store.pendingUploads(),
      builder: (context, snapshot) {
        if (snapshot.data?.contains(hash) != true) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(left: 6),
          child: Text(
            '待同步',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontSize: 10,
            ),
          ),
        );
      },
    );
  }
}

/// 按哈希取图并显示。
///
/// 本地没有就去服务端下。服务端也不在的话显示占位符——**不报错、不卡住**。
/// 看不到一张图不该让整个界面出问题。
class _AttachmentImage extends ConsumerWidget {
  final String hash;
  final BoxFit fit;

  const _AttachmentImage({required this.hash, this.fit = BoxFit.contain});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final k = Theme.of(context).kanban;

    return FutureBuilder<Uint8List?>(
      future: ref.read(attachmentSyncerProvider).fetch(hash),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 1.8,
                color: k.cardBody.withValues(alpha: 0.5),
              ),
            ),
          );
        }
        final bytes = snapshot.data;
        if (bytes == null) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.cloud_off_outlined,
                  size: 20,
                  color: k.cardBody.withValues(alpha: 0.6),
                ),
                const SizedBox(height: 3),
                Text(
                  '服务端离线',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: k.cardBody.withValues(alpha: 0.6),
                    fontSize: 9.5,
                  ),
                ),
              ],
            ),
          );
        }
        return Image.memory(bytes, fit: fit, gaplessPlayback: true);
      },
    );
  }
}

class _ImagePreview extends StatelessWidget {
  final AttachmentRow attachment;

  const _ImagePreview({required this.attachment});

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: screen.width * 0.85,
              maxHeight: screen.height * 0.8,
            ),
            // 预览用原图，不用缩略图。
            child: _AttachmentImage(hash: attachment.hash),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '${attachment.filename}　${humanBytes(attachment.size)}',
              style: const TextStyle(color: Colors.white, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}

void _showUnavailable(BuildContext context) {
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text('这个文件本机还没有，服务端也连不上'),
      behavior: SnackBarBehavior.floating,
      width: 340,
    ),
  );
}
