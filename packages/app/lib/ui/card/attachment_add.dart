import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mime/mime.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path/path.dart' as p;

import '../../providers.dart';

/// 往卡片上加附件。
///
/// 三个入口共用这一条路——选文件、拖进来、从剪贴板粘贴——所以「导入本地、
/// 立刻可用、后台再传」这套行为在三种方式下完全一致。
///
/// 全程**只做本地的事**：算哈希、拷贝进缓存、生成缩略图。离线时照样能加，
/// 上传是后台队列的事。
Future<int> addAttachmentFiles(
  WidgetRef ref, {
  required String boardId,
  required String cardId,
  required List<({String path, String name})> files,
}) async {
  if (files.isEmpty) return 0;

  final store = ref.read(attachmentStoreProvider);
  final repo = ref.read(repositoryProvider);
  var added = 0;

  for (final picked in files) {
    final file = File(picked.path);
    if (!file.existsSync()) continue;

    final imported = await store.importFile(file, displayName: picked.name);
    await repo.addAttachment(
      boardId: boardId,
      cardId: cardId,
      hash: imported.hash,
      filename: imported.filename,
      size: imported.size,
      mime: imported.mime,
      thumbHash: imported.thumbHash,
    );
    added++;
  }

  // 顺手推一把。连不上也无所谓，文件在队列里等着。
  unawaited(ref.read(attachmentSyncerProvider).flush());
  return added;
}

/// 加一份**内存里的**数据当附件，主要给剪贴板里的图片用。
///
/// 剪贴板给的是裸字节，没有文件名也没有路径，所以要先落到临时文件——
/// 导入那套逻辑是按文件写的，而且算哈希时也需要真实内容在盘上。
Future<void> addAttachmentBytes(
  WidgetRef ref, {
  required String boardId,
  required String cardId,
  required Uint8List bytes,
}) async {
  final dir = await Directory(
    p.join(Directory.systemTemp.path, 'kanban-paste'),
  ).create(recursive: true);

  final name = pastedImageName(bytes);
  final file = File(p.join(dir.path, name));
  await file.writeAsBytes(bytes);

  await addAttachmentFiles(
    ref,
    boardId: boardId,
    cardId: cardId,
    files: [(path: file.path, name: name)],
  );
}

/// 给剪贴板里的图片起个名字。
///
/// 剪贴板不带文件名，但附件列表、下载、分享都要显示和使用它，不能留空。
/// 后缀按内容的魔数判断而不是瞎猜——从聊天工具复制出来的可能是 PNG 也
/// 可能是 JPEG，后缀错了在别的程序里打不开。
String pastedImageName(Uint8List bytes) {
  final mime = lookupMimeType('', headerBytes: bytes.take(32).toList());
  final ext = switch (mime) {
    'image/png' => 'png',
    'image/jpeg' => 'jpg',
    'image/gif' => 'gif',
    'image/webp' => 'webp',
    'image/bmp' => 'bmp',
    _ => 'png',
  };

  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final stamp =
      '${now.year}${two(now.month)}${two(now.day)}'
      '-${two(now.hour)}${two(now.minute)}${two(now.second)}';
  return '粘贴的图片-$stamp.$ext';
}

/// 把剪贴板里的东西加成附件。
///
/// 返回 **是否真的加了**——调用方要靠它决定「这次 Ctrl+V 我接管了」还是
/// 「不关我事，还给输入框去粘文字」。
///
/// 认两种东西：剪贴板里的**图像数据**（从聊天工具复制的图），以及剪贴板里
/// 的**文件路径**（在资源管理器里复制的文件）。
Future<bool> pasteAttachment(
  WidgetRef ref, {
  required String boardId,
  required String cardId,
}) async {
  final image = await Pasteboard.image;
  if (image != null && image.isNotEmpty) {
    await addAttachmentBytes(
      ref,
      boardId: boardId,
      cardId: cardId,
      bytes: image,
    );
    return true;
  }

  final paths = await Pasteboard.files();
  if (paths.isNotEmpty) {
    await addAttachmentFiles(
      ref,
      boardId: boardId,
      cardId: cardId,
      files: [for (final path in paths) (path: path, name: p.basename(path))],
    );
    return true;
  }

  return false;
}
