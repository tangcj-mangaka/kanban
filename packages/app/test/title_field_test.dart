import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanban/ui/card/title_field.dart';

/// 卡片标题要自己存下来。
///
/// 用户报的：改完标题去点正文，标题白改了；点到弹窗外面，弹窗关了、标题
/// 也没了；只有按回车才存得住。
///
/// 根子在 Flutter 的 `onTapOutside`——所有 TextField 默认挂在同一个
/// `TapRegion` 组里（groupId 就是 `EditableText`），所以从标题点进正文
/// **不算点到了外面**，回调根本不触发。偏偏这个名字看着像能管这件事。
void main() {
  /// 把标题框和另一个输入框摆在一起。
  ///
  /// 「另一个输入框」是这组测试的关键：出问题的恰恰是从一个输入框跳到
  /// 另一个输入框，换成点一块空白是复现不出来的。
  Future<List<String>> pump(
    WidgetTester tester, {
    String initial = '旧标题',
  }) async {
    final saved = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              TitleField(initialValue: initial, onChanged: saved.add),
              const TextField(key: Key('正文')),
            ],
          ),
        ),
      ),
    );
    return saved;
  }

  testWidgets('改了标题点进正文，存下来', (tester) async {
    final saved = await pump(tester);

    await tester.enterText(find.byType(TitleField), '新标题');
    await tester.tap(find.byKey(const Key('正文')));
    await tester.pump();

    expect(saved, ['新标题']);
  });

  testWidgets('打字停下来就存，不用等失焦', (tester) async {
    // 「只要改了就自动存」——人停手之后，哪怕光标还在标题里，
    // 这会儿断电也不该丢。
    final saved = await pump(tester);

    await tester.enterText(find.byType(TitleField), '新标题');
    expect(saved, isEmpty, reason: '还在打字，别一个字一条 op');

    await tester.pump(const Duration(seconds: 1));
    expect(saved, ['新标题']);
  });

  testWidgets('按回车立刻存', (tester) async {
    final saved = await pump(tester);

    await tester.enterText(find.byType(TitleField), '新标题');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(saved, ['新标题']);
  });

  testWidgets('组件被销毁时，没提交的补上', (tester) async {
    // 点弹窗外面就是这条路：遮罩直接把弹窗弹掉，没有失焦那一步。
    final saved = await pump(tester);

    await tester.enterText(find.byType(TitleField), '新标题');
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));

    expect(saved, ['新标题']);
  });

  testWidgets('没动过就不写', (tester) async {
    // 每打开一次详情就写一条标题 op 的话，改动记录会被没改过的东西刷屏，
    // 还白白制造一次跨设备同步。
    final saved = await pump(tester);

    await tester.tap(find.byKey(const Key('正文')));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));

    expect(saved, isEmpty);
  });

  testWidgets('前后空格不算改动', (tester) async {
    final saved = await pump(tester);

    await tester.enterText(find.byType(TitleField), '  旧标题  ');
    await tester.pump(const Duration(seconds: 1));

    expect(saved, isEmpty);
  });

  testWidgets('连改两次，存两次，不重复存同一个值', (tester) async {
    final saved = await pump(tester);

    await tester.enterText(find.byType(TitleField), '第一版');
    await tester.pump(const Duration(seconds: 1));
    await tester.enterText(find.byType(TitleField), '第二版');
    await tester.pump(const Duration(seconds: 1));
    // 再失焦一次，不该又写一条一样的。
    await tester.tap(find.byKey(const Key('正文')));
    await tester.pump();

    expect(saved, ['第一版', '第二版']);
  });

  testWidgets('标题可以清空', (tester) async {
    // 空字符串是合法标题（画布上显示「未命名」），不能被当成「没改」。
    final saved = await pump(tester);

    await tester.enterText(find.byType(TitleField), '');
    await tester.pump(const Duration(seconds: 1));

    expect(saved, ['']);
  });
}
