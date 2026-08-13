import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'providers.dart';

/// 两个入口共用的启动流程。
///
/// 抽出来是因为有两个入口（正式的 `main.dart` 和开发用的 `dev_preview.dart`），
/// 启动准备各写一遍必然漏——第一次就漏了附件缓存目录的覆盖，
/// 开发入口一打开卡片详情就崩。这种事只该有一处。
Future<void> runKanbanApp(Widget app) async {
  WidgetsFlutterBinding.ensureInitialized();

  // 附件缓存目录要异步取，而 provider 得同步给出结果，所以在这里先解析好。
  final support = await getApplicationSupportDirectory();
  final cacheDir = Directory(p.join(support.path, 'attachments'));

  runApp(
    ProviderScope(
      overrides: [attachmentCacheDirProvider.overrideWithValue(cacheDir)],
      child: _KeepAlive(child: app),
    ),
  );
}

/// 让必须常驻的后台组件从启动起就活着。
///
/// Riverpod 的 provider 是惰性的——没人读就不会创建。附件同步器的
/// 「一连上就补传」监听写在它的创建函数里，不主动读一次的话，
/// **除非用户恰好打开一张带附件的卡片，附件永远不会上传**。
/// 这个 bug 只有真的跨设备跑一遍才会暴露。
class _KeepAlive extends ConsumerWidget {
  final Widget child;

  const _KeepAlive({required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(attachmentSyncerProvider);
    return child;
  }
}
