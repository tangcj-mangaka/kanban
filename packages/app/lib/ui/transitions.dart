import 'package:flutter/material.dart';

/// 进看板用的转场：淡入 + 极轻微地放大。
///
/// 默认的 [MaterialPageRoute] 在桌面上是整页横向滑入，像手机。而这里的
/// 动作在语义上是**钻进去**——从列表页那块小方块进入它代表的那块画布，
/// 所以用「原地放大浮现」而不是「从右边推进来」。
///
/// 起始缩放只有 0.96：再大就成了特效，用户一天要进出看板几十次，
/// 转场应该是察觉不到的顺滑，不是每次都表演一遍。
class BoardRoute<T> extends PageRouteBuilder<T> {
  BoardRoute({required WidgetBuilder builder})
    : super(
        transitionDuration: const Duration(milliseconds: 260),
        reverseTransitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (context, _, _) => builder(context),
        transitionsBuilder: (context, animation, _, child) {
          // 系统开了「减弱动态效果」就直接切，不做任何位移缩放。
          if (MediaQuery.disableAnimationsOf(context)) return child;

          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
              child: child,
            ),
          );
        },
      );
}
