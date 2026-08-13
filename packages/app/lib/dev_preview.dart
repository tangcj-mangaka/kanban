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

import 'bootstrap.dart';
import 'providers.dart';
import 'ui/boards/board_list_page.dart';
import 'ui/board/board_page.dart';
import 'ui/card/card_detail_dialog.dart';
import 'ui/sync/sync_settings_dialog.dart';
import 'ui/theme/app_theme.dart';

Future<void> main() => runKanbanApp(const _PreviewApp());

class _PreviewApp extends ConsumerStatefulWidget {
  const _PreviewApp();

  @override
  ConsumerState<_PreviewApp> createState() => _PreviewAppState();
}

class _PreviewAppState extends ConsumerState<_PreviewApp> {
  @override
  void initState() {
    super.initState();
    if (_syncHost.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final client = ref.read(syncClientProvider);
        await client.configure(
          host: _syncHost,
          port: _syncPort,
          pairCode: _syncCode.isEmpty ? null : _syncCode,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '驴看板（画布预览）',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: switch (_forceTheme) {
        'dark' => ThemeMode.dark,
        'light' => ThemeMode.light,
        _ => ref.watch(themeModeProvider),
      },
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

/// `--dart-define=SYNC_HOST=... --dart-define=SYNC_CODE=...` 时启动即配对。
///
/// 手动填地址和配对码要点好几下，截图验证时没法自动点。
const _syncHost = String.fromEnvironment('SYNC_HOST');
const _syncPort = int.fromEnvironment('SYNC_PORT', defaultValue: 8765);
const _syncCode = String.fromEnvironment('SYNC_CODE');

/// `--dart-define=THEME=dark|light` 时强制主题。
///
/// 截图验证深色主题时不用去改系统外观——那会动用户的机器设置。
const _forceTheme = String.fromEnvironment('THEME');

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
      if (_autoOpen == 'sync') {
        _opened = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          showSyncSettings(context);
        });
      } else if (cards != null && cards.isNotEmpty) {
        _opened = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          showCardDetail(context, boardId, cards.first.id);
        });
      }
    }

    return BoardPage(
      boardId: boardId,
      // 不指定时传 null，让 BoardPage 按屏幕宽度自己定
      // （手机默认分组视图）。写死 canvas 会把那个默认绕过去。
      initialView: switch (_initialView) {
        'grouped' => BoardView.grouped,
        'haystack' => BoardView.haystack,
        'canvas' => BoardView.canvas,
        _ => null,
      },
    );
  }
}
