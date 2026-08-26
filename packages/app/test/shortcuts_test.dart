import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 两条快捷交互的行为验证。
///
/// 都用合成事件测**我写的那部分逻辑**。至于「Windows 到底会不会把鼠标侧键
/// 交给应用」，属于平台那一环，这里验不了。
void main() {
  group('鼠标侧键一步退回列表', () {
    /// 复刻 main.dart 里的挂法：Listener 包住整个 Navigator。
    Future<GlobalKey<NavigatorState>> pump(WidgetTester tester) async {
      final navKey = GlobalKey<NavigatorState>();

      void onPointer(PointerDownEvent e) {
        if (e.buttons & kBackMouseButton == 0) return;
        navKey.currentState?.popUntil((r) => r.isFirst);
      }

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navKey,
          builder: (context, child) =>
              Listener(onPointerDown: onPointer, child: child!),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const Scaffold(body: Text('看板页')),
                  ),
                ),
                child: const Text('打开看板'),
              ),
            ),
          ),
        ),
      );
      return navKey;
    }

    /// 按一下鼠标的某个键。
    Future<void> press(WidgetTester tester, int buttons) async {
      final g = await tester.startGesture(
        const Offset(200, 300),
        kind: PointerDeviceKind.mouse,
        buttons: buttons,
      );
      await g.up();
      await tester.pumpAndSettle();
    }

    testWidgets('从看板页按侧键，回到列表', (tester) async {
      await pump(tester);
      await tester.tap(find.text('打开看板'));
      await tester.pumpAndSettle();
      expect(find.text('看板页'), findsOneWidget);

      await press(tester, kBackMouseButton);
      expect(find.text('打开看板'), findsOneWidget, reason: '应当回到列表');
    });

    testWidgets('开着弹窗时也是一步到位，不是先关弹窗', (tester) async {
      // 用户明确要的是一步回到总览，而不是连按好几次。
      final navKey = await pump(tester);
      await tester.tap(find.text('打开看板'));
      await tester.pumpAndSettle();

      showDialog<void>(
        context: navKey.currentContext!,
        builder: (_) => const AlertDialog(title: Text('卡片详情')),
      );
      await tester.pumpAndSettle();
      expect(find.text('卡片详情'), findsOneWidget);

      await press(tester, kBackMouseButton);
      expect(find.text('卡片详情'), findsNothing, reason: '弹窗该关掉');
      expect(find.text('看板页'), findsNothing, reason: '看板页也该退掉');
      expect(find.text('打开看板'), findsOneWidget, reason: '一步回到列表');
    });

    testWidgets('已经在列表时按侧键，什么都不发生', (tester) async {
      await pump(tester);
      await press(tester, kBackMouseButton);
      expect(find.text('打开看板'), findsOneWidget);
    });

    testWidgets('普通左键不会触发后退', (tester) async {
      // 判据是按键位，不是「有没有点击」——写错就会变成点哪都退回列表。
      await pump(tester);
      await tester.tap(find.text('打开看板'));
      await tester.pumpAndSettle();

      await press(tester, kPrimaryMouseButton);
      expect(find.text('看板页'), findsOneWidget, reason: '左键不该退');
    });

    testWidgets('前进键也不触发', (tester) async {
      await pump(tester);
      await tester.tap(find.text('打开看板'));
      await tester.pumpAndSettle();

      await press(tester, kForwardMouseButton);
      expect(find.text('看板页'), findsOneWidget);
    });
  });

  group('Ctrl+V 不能弄坏文字粘贴', () {
    testWidgets('剪贴板是文字时，Ctrl+V 照常粘进输入框', (tester) async {
      // 这是这次改动最容易弄坏的地方：为了让 Ctrl+V 能加图片，我们在弹窗
      // 那一层把它拦下来了。拦下来之后必须把「不是图片」的情况还给输入框，
      // 否则用户在正文里按 Ctrl+V 会发现什么都没发生。
      var interceptCalled = false;
      final controller = TextEditingController();

      // 模拟剪贴板里是纯文字。
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') {
            return <String, dynamic>{'text': '剪贴板里的文字'};
          }
          return null;
        },
      );

      Future<void> onPaste() async {
        interceptCalled = true;
        // 这里假装剪贴板里没有图片，走「还给输入框」那条路。
        final focused = primaryFocus?.context;
        if (focused != null && focused.mounted) {
          Actions.maybeInvoke(
            focused,
            const PasteTextIntent(SelectionChangedCause.keyboard),
          );
        }
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CallbackShortcuts(
              bindings: {
                const SingleActivator(
                  LogicalKeyboardKey.keyV,
                  control: true,
                ): onPaste,
              },
              child: Focus(
                autofocus: true,
                child: TextField(controller: controller),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(interceptCalled, isTrue, reason: '我们这一层应当先拿到 Ctrl+V');
      expect(
        controller.text,
        '剪贴板里的文字',
        reason: '拦下来之后必须把文字粘贴还回去，否则输入框里什么都不会出现',
      );
    });
  });
}
