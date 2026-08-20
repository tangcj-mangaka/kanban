import 'package:flutter/gestures.dart';

/// 拖动画布卡片用的识别器，**把鼠标下的判定阈值调大**。
///
/// Flutter 对鼠标这类精确指针的拖动阈值写死是 2 逻辑像素
/// （`kPrecisePointerPanSlop`）。对「拖动画布上的卡片」这个动作来说太灵敏了：
///
/// 双击时手在两次点击之间挪一两个像素是常事。只要越过那 2 像素，这个拖动
/// 识别器就会赢下手势、把双击判掉——用户看到的是「双击卡片没反应」，运气
/// 差的时候背景那条路捡漏，还会在卡片上凭空新建一张卡。这不是假想，是拿
/// 鼠标事件做实验测出来的：移动 0~1 像素双击正常，≥2 像素双击就没了。
///
/// 拖一张卡片和拖动文本选区、拖动滚动条不一样，不需要像素级的灵敏度——
/// 手真想拖的时候，移动量远不止几个像素。所以把阈值放宽到 [mouseSlop]，
/// 换回双击的可靠性，是笔划算的买卖。
///
/// **触摸不动**：触摸本来就是 36 像素（`kPanSlop`），足够宽松，手机上
/// 从来没出过这个问题。
class CardPanRecognizer extends PanGestureRecognizer {
  CardPanRecognizer({super.debugOwner});

  /// 鼠标下要移动多少逻辑像素才算「开始拖动」。
  ///
  /// 8 是权衡出来的：手抖通常在 1~3 像素，真要拖动时第一下就远超 8，
  /// 所以既挡得住误判，又不会让拖动显得迟钝。
  static const double mouseSlop = 8;

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) {
    if (pointerDeviceKind == PointerDeviceKind.mouse) {
      return globalDistanceMoved.abs() > mouseSlop;
    }
    return super.hasSufficientGlobalDistanceToAccept(
      pointerDeviceKind,
      deviceTouchSlop,
    );
  }
}
