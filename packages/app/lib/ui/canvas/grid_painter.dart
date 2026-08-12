import 'package:flutter/material.dart';

import 'canvas_transform.dart';

/// 画布的网格点背景。
///
/// 提供空间参照——没有它，无限画布上平移时完全感觉不到自己在动。
/// 但必须淡到不干扰阅读，所以颜色取的是主题里几乎透明的那一档。
class GridPainter extends CustomPainter {
  final CanvasTransform transform;
  final Color dotColor;

  /// 世界坐标下的点间距。
  static const double spacing = 28;

  const GridPainter({required this.transform, required this.dotColor});

  @override
  void paint(Canvas canvas, Size size) {
    var step = spacing * transform.scale;
    // 缩得太小时点会糊成一片，这时改成隔几格画一个。
    var multiple = 1;
    while (step < 14) {
      multiple *= 2;
      step = spacing * multiple * transform.scale;
    }
    // 放得太大时点太稀疏，反过来加密。
    while (step > 90) {
      step /= 2;
    }

    final radius = (1.1 * transform.scale).clamp(0.7, 1.8);
    final paint = Paint()..color = dotColor;

    // 从视口左上角往回找第一个点，避免从世界原点开始遍历。
    final startX = -(transform.offset.dx % step);
    final startY = -(transform.offset.dy % step);

    for (var x = startX; x < size.width; x += step) {
      for (var y = startY; y < size.height; y += step) {
        canvas.drawCircle(Offset(x, y), radius, paint);
      }
    }
  }

  @override
  bool shouldRepaint(GridPainter old) =>
      old.transform != transform || old.dotColor != dotColor;
}
