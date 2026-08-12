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
import 'ui/board/board_page.dart';
import 'ui/card/card_detail_dialog.dart';
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

/// `--dart-define=OPEN=detail` 时自动打开第一张卡片的详情弹窗。
///
/// 弹窗藏在两次点击之后，截图验证时没法自动点。
const _autoOpen = String.fromEnvironment('OPEN');

/// `--dart-define=VIEW=grouped|haystack` 时直接停在那个视图。
const _initialView = String.fromEnvironment('VIEW');

class _FirstBoardCanvas extends ConsumerStatefulWidget {
  const _FirstBoardCanvas();

  @override
  ConsumerState<_FirstBoardCanvas> createState() => _FirstBoardCanvasState();
}

class _FirstBoardCanvasState extends ConsumerState<_FirstBoardCanvas> {
  bool _opened = false;

  @override
  Widget build(BuildContext context) {
    final boards = ref.watch(boardSummariesProvider).value;
    if (boards == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (boards.isEmpty) return const BoardListPage();

    final boardId = boards.first.board.id;
    if (_autoOpen.isNotEmpty && !_opened) {
      final cards = ref.watch(canvasCardsProvider(boardId)).value;
      if (cards != null && cards.isNotEmpty) {
        _opened = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          showCardDetail(context, boardId, cards.first.id);
        });
      }
    }

    return BoardPage(
      boardId: boardId,
      initialView: switch (_initialView) {
        'grouped' => BoardView.grouped,
        'haystack' => BoardView.haystack,
        _ => BoardView.canvas,
      },
    );
  }
}
