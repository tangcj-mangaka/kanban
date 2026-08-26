import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import 'bootstrap.dart';
import 'providers.dart';
import 'ui/boards/board_list_page.dart';
import 'ui/share/share_target_sheet.dart';
import 'ui/theme/app_theme.dart';

Future<void> main() => runKanbanApp(const KanbanApp());

class KanbanApp extends ConsumerWidget {
  const KanbanApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: '驴看板',
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
      // 收系统分享面板送进来的文件。桌面上这一层什么都不做。
      home: const _ShareIntake(child: BoardListPage()),
    );
  }
}

/// 接住从系统分享面板送进来的文件。
///
/// 两条路都要接：应用**冷启动**时被分享唤起（getInitialMedia），以及应用
/// **已经在运行**时又分享了一次（媒体流）。只接一条的话，另一种情形下
/// 用户点了分享却什么都不发生。
///
/// 只在安卓/iOS 上生效——桌面没有系统分享面板这回事，那边靠粘贴和拖拽。
class _ShareIntake extends ConsumerStatefulWidget {
  final Widget child;

  const _ShareIntake({required this.child});

  @override
  ConsumerState<_ShareIntake> createState() => _ShareIntakeState();
}

class _ShareIntakeState extends ConsumerState<_ShareIntake> {
  StreamSubscription<List<SharedMediaFile>>? _sub;

  static bool get _supported => Platform.isAndroid || Platform.isIOS;

  @override
  void initState() {
    super.initState();
    if (!_supported) return;

    _sub = ReceiveSharingIntent.instance.getMediaStream().listen(_handle);

    // 冷启动那一份要单独取一次，它不会出现在流里。
    ReceiveSharingIntent.instance.getInitialMedia().then((media) {
      if (media.isEmpty) return;
      _handle(media);
      // 取过就要清掉，否则每次回到前台都会再弹一次。
      ReceiveSharingIntent.instance.reset();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _handle(List<SharedMediaFile> media) async {
    if (media.isEmpty || !mounted) return;

    final files = [
      for (final m in media) (path: m.path, name: p.basename(m.path)),
    ];

    // 等这一帧画完再弹窗：冷启动时这里可能还没进 Navigator。
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await showShareTarget(context, files);
      await cleanupSharedFiles([for (final m in media) m.path]);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
