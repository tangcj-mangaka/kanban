import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import 'theme/app_theme.dart';

/// 本地没有就去服务端下。服务端也不在的话显示占位符——**不报错、不卡住**。
/// 看不到一张图不该让整个界面出问题。
class AttachmentImage extends ConsumerWidget {
  final String hash;
  final BoxFit fit;

  /// 加载中占位块的高度。给 null 表示由外部约束决定（详情里的方格）。
  final double? placeholderHeight;

  const AttachmentImage({
    super.key,
    required this.hash,
    this.fit = BoxFit.contain,
    this.placeholderHeight,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final k = Theme.of(context).kanban;

    return FutureBuilder<Uint8List?>(
      future: ref.read(attachmentSyncerProvider).fetch(hash),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return SizedBox(
            height: placeholderHeight,
            width: placeholderHeight == null ? null : double.infinity,
            child: Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 1.8,
                color: k.cardBody.withValues(alpha: 0.5),
              ),
              ),
            ),
          );
        }
        final bytes = snapshot.data;
        if (bytes == null) {
          return SizedBox(
            height: placeholderHeight,
            width: placeholderHeight == null ? null : double.infinity,
            child: Center(
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
            ),
          );
        }
        return Image.memory(bytes, fit: fit, gaplessPlayback: true);
      },
    );
  }
}
