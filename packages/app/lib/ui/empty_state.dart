import 'package:flutter/material.dart';

import 'theme/app_theme.dart';

/// 所有「这里还什么都没有」的统一长相。
///
/// 之前每处空状态各写各的 Column + Text，字号间距全靠手感，凑在一起像
/// 三个不同的应用。收拢成一个组件之后，空状态是这个应用里出镜率最高的
/// 画面之一——新建的看板、清空后的仓库、搜不到的结果，用户天天见。
class EmptyState extends StatelessWidget {
  /// 顶上的插画。给 null 就只有文字。
  final Widget? art;

  final String title;
  final String? body;

  /// 底下的按钮。
  final Widget? action;

  /// 悬浮在内容之上（比如画布的操作提示），此时不该吃鼠标事件。
  final bool ignorePointer;

  const EmptyState({
    super.key,
    this.art,
    required this.title,
    this.body,
    this.action,
    this.ignorePointer = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final k = theme.kanban;

    final content = Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (art != null) ...[art!, const SizedBox(height: 18)],
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall?.copyWith(
                color: k.cardTitle,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (body != null) ...[
              const SizedBox(height: 7),
              Text(
                body!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: k.cardBody,
                  height: 1.55,
                ),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 22), action!],
          ],
        ),
      ),
    );

    // 淡入并轻轻上浮。空状态往往是异步数据到达后才确定的，直接「啪」地
    // 出现会让人以为闪了一下错误。
    final animated = TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, (1 - t) * 10), child: child),
      ),
      child: content,
    );

    return ignorePointer ? IgnorePointer(child: animated) : animated;
  }
}

/// 让插画轻轻起伏的包装。
///
/// 幅度只有几个像素、周期三秒多——目的是让画面「活着」，不是让它表演。
/// 动得明显了，一个本来就没内容的页面反而更吵。
class GentleBob extends StatefulWidget {
  final Widget child;

  const GentleBob({super.key, required this.child});

  @override
  State<GentleBob> createState() => _GentleBobState();
}

class _GentleBobState extends State<GentleBob>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 系统开了「减弱动态效果」就老实待着——这个开关存在是有原因的，
    // 前庭功能敏感的人看循环动画会不舒服。
    if (MediaQuery.disableAnimationsOf(context)) return widget.child;

    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) => Transform.translate(
        offset: Offset(0, Curves.easeInOut.transform(_c.value) * 6 - 3),
        child: child,
      ),
      child: widget.child,
    );
  }
}
