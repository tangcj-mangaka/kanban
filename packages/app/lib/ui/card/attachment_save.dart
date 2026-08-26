import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../../data/database.dart';
import '../../providers.dart';

/// 把附件交到用户手上。
///
/// **必须分平台**，因为「保存文件」这个动作在桌面和安卓上根本不是一回事：
///
/// - **桌面**：弹系统的另存为对话框，用户自己挑目录
/// - **安卓**：**没有另存为对话框**。`file_selector` 的安卓实现只有「打开
///   文件」，基类的 `getSaveLocation` 会直接抛 `UnimplementedError` ——
///   也就是说在手机上，原来点任何附件都会抛异常，不只是图片下不了。
///   安卓的习惯做法是走系统分享面板：用户在那里可以选「保存到相册」、
///   「保存到文件」，也可以直接转发给别人
Future<void> saveAttachment(
  BuildContext context,
  WidgetRef ref,
  AttachmentRow attachment,
) async {
  final bytes = await ref.read(attachmentSyncerProvider).fetch(attachment.hash);
  if (bytes == null) {
    if (context.mounted) showAttachmentUnavailable(context);
    return;
  }

  final name = _safeFileName(attachment.filename);

  if (Platform.isAndroid || Platform.isIOS) {
    // 先落到临时文件——分享面板要的是文件，不是内存里的字节。
    // 用真实文件名，这样对方收到的、或者存下来的名字是对的。
    final dir = await Directory(
      p.join(Directory.systemTemp.path, 'kanban-share'),
    ).create(recursive: true);
    final file = File(p.join(dir.path, name));
    await file.writeAsBytes(bytes);

    await SharePlus.instance.share(
      ShareParams(files: [XFile(file.path, mimeType: attachment.mime)]),
    );
    return;
  }

  final location = await getSaveLocation(suggestedName: name);
  if (location == null) return;
  await File(location.path).writeAsBytes(bytes);

  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已保存到 ${location.path}'),
        behavior: SnackBarBehavior.floating,
        width: 420,
      ),
    );
  }
}

/// 去掉文件名里会让文件系统翻脸的字符。
///
/// 附件名是同步过来的，可能来自另一个操作系统——Windows 不接受 `:`、`?`
/// 这些字符，而它们在别处是合法的。
@visibleForTesting
String safeFileNameForTest(String raw) => _safeFileName(raw);

String _safeFileName(String raw) {
  final cleaned = raw.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_').trim();
  return cleaned.isEmpty ? '附件' : cleaned;
}

void showAttachmentUnavailable(BuildContext context) {
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text('这个文件本机还没有，服务端也连不上'),
      behavior: SnackBarBehavior.floating,
      width: 340,
    ),
  );
}
