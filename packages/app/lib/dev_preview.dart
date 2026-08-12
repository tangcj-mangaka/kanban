/// 开发用的备用入口：跳过看板列表，直接打开第一块看板的画布。
///
/// 正常构建走 `lib/main.dart`，这个文件不会被引用。要用它：
///
/// ```
/// flutter run -d macos --target=lib/dev_preview.dart
/// ```
///
/// 存在的理由是画布藏在列表页后面一次点击的地方，每次调试画布都要先点
/// 一下很烦；截图验证时更是没法自动点。
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';
import 'ui/boards/board_list_page.dart';
import 'ui/canvas/board_canvas_page.dart';
import 'ui/theme/app_theme.dart';

void main() {
  runApp(const ProviderScope(child: _PreviewApp()));
}

class _PreviewApp extends ConsumerWidget {
  const _PreviewApp();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: '驴看板（画布预览）',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ref.watch(themeModeProvider),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const _FirstBoardCanvas(),
    );
  }
}

class _FirstBoardCanvas extends ConsumerWidget {
  const _FirstBoardCanvas();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final boards = ref.watch(boardSummariesProvider).value;
    if (boards == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (boards.isEmpty) return const BoardListPage();
    return BoardCanvasPage(boardId: boards.first.board.id);
  }
}
