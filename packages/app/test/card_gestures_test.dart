import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanban/ui/canvas/card_gestures.dart';

/// 卡片的双击不能被「鼠标手抖」判成拖动。
///
/// 这个问题是用户报的：放大后双击卡片有时不打开详情，反而像点在了空白处。
/// 实验测出来的机制是——Flutter 对鼠标的拖动阈值是 2 逻辑像素，两次点击
/// 之间挪超过这个数，拖动识别器就赢了手势、把双击判掉。
void main() {
  /// 造一张卡片，双击它并在两次点击之间挪 [jitter] 像素。
  ///
  /// [custom] 决定用我们放宽了阈值的识别器还是 Flutter 默认的。
  Future<({bool doubleTapped, bool dragged})> probe(
    WidgetTester tester, {
    required double jitter,
    required PointerDeviceKind kind,
    required bool custom,
  }) async {
    var doubleTapped = false;
    var dragged = false;

    Widget card = Container(width: 200, height: 150, color: Colors.red);

    await tester.pumpWidget(
      MaterialApp(
        home: custom
            ? RawGestureDetector(
                behavior: HitTestBehavior.opaque,
                gestures: {
                  DoubleTapGestureRecognizer:
                      GestureRecognizerFactoryWithHandlers<
                        DoubleTapGestureRecognizer
                      >(
                        DoubleTapGestureRecognizer.new,
                        (r) => r.onDoubleTap = () => doubleTapped = true,
                      ),
                  CardPanRecognizer:
                      GestureRecognizerFactoryWithHandlers<CardPanRecognizer>(
                        CardPanRecognizer.new,
                        (r) => r.onStart = (_) => dragged = true,
                      ),
                },
                child: card,
              )
            : GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTap: () => doubleTapped = true,
                onPanStart: (_) => dragged = true,
                child: card,
              ),
      ),
    );

    const at = Offset(100, 75);
    final first = await tester.startGesture(at, kind: kind);
    await first.up();
    await tester.pump(const Duration(milliseconds: 60));

    final second = await tester.startGesture(at, kind: kind);
    if (jitter > 0) await second.moveBy(Offset(jitter, 0));
    await second.up();
    await tester.pump(const Duration(milliseconds: 400));

    return (doubleTapped: doubleTapped, dragged: dragged);
  }

  testWidgets('默认识别器：鼠标挪 4 像素，双击就没了（问题本身）', (tester) async {
    // 阈值是「大于 2 像素」，所以正好 2 还活着，超过就死。
    final r = await probe(
      tester,
      jitter: 4,
      kind: PointerDeviceKind.mouse,
      custom: false,
    );
    expect(
      r.doubleTapped,
      isFalse,
      reason: '这条记录的是**坏掉的**行为，用来证明下面的修复确有必要',
    );
  });

  testWidgets('换了识别器后：鼠标挪 2、4、6 像素，双击照常', (tester) async {
    for (final jitter in [0.0, 2.0, 4.0, 6.0]) {
      final r = await probe(
        tester,
        jitter: jitter,
        kind: PointerDeviceKind.mouse,
        custom: true,
      );
      expect(r.doubleTapped, isTrue, reason: '挪 $jitter 像素时双击应当仍然有效');
      expect(r.dragged, isFalse, reason: '挪 $jitter 像素不该被当成拖动');
    }
  });

  testWidgets('真要拖动时照样拖得动', (tester) async {
    // 阈值放宽不能把拖动本身弄坏。
    final r = await probe(
      tester,
      jitter: 20,
      kind: PointerDeviceKind.mouse,
      custom: true,
    );
    expect(r.dragged, isTrue, reason: '移动 20 像素显然是拖动');
  });

  testWidgets('触摸的行为不变', (tester) async {
    // 触摸的阈值本来就是 36 像素，手机上从没出过这个问题，不该被我们改动。
    final r = await probe(
      tester,
      jitter: 4,
      kind: PointerDeviceKind.touch,
      custom: true,
    );
    expect(r.doubleTapped, isTrue);
    expect(r.dragged, isFalse);
  });
}
