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
      child: app,
    ),
  );
}
