import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 干草仓库的「草垛脸」图标。
///
/// 就是当初在配色页上选定的第 3 版：草垛加眯眼和笑脸。用 [CustomPainter]
/// 画而不是放一张图片——图标要在 16px 的标签页和 96px 的空状态上都用，
/// 位图得备好几套尺寸，而这个形状简单到画出来比管资源还省事。
///
/// 颜色写死不跟主题走：它是品牌色的一部分，当初就是照着在浅色和深色
/// 两种底上都成立来挑的。跟着主题变反而会变成两个不同的东西。
class HaystackIcon extends StatelessWidget {
  final double size;

  /// 眯成一条缝。空状态用——仓库空着的时候它在打盹。
  final bool sleeping;

  const HaystackIcon({super.key, required this.size, this.sleeping = false});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _HaystackPainter(sleeping: sleeping),
        // 图标是装饰，但它是「干草仓库」唯一的视觉标识，
        // 读屏软件得知道这里是什么。
        isComplex: false,
      ),
    );
  }
}

class _HaystackPainter extends CustomPainter {
  final bool sleeping;

  const _HaystackPainter({required this.sleeping});

  // 原图是 64×64 的画板，下面所有坐标都按它写，最后统一缩放。
  static const _art = 64.0;

  static const _straw = Color(0xFFC99A2E);
  static const _body = Color(0xFFE0B44A);
  static const _bodyTop = Color(0xFFEAC468);
  static const _texture = Color(0xFFC08F22);
  static const _face = Color(0xFF7A5A12);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / _art;
    canvas.save();
    canvas.scale(s);

    final strawPaint = Paint()
      ..color = _straw
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    // 顶上翘出来的三根草茎。
    canvas
      ..drawLine(const Offset(22, 14), const Offset(27, 25), strawPaint)
      ..drawLine(const Offset(42, 14), const Offset(37, 25), strawPaint)
      ..drawLine(const Offset(32, 10), const Offset(32, 23), strawPaint);

    // 垛身：一个圆角矩形，上半截颜色浅一点当受光面。
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(7, 24, 50, 33),
        const Radius.circular(9),
      ),
      Paint()..color = _body,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(7, 24, 50, 17),
        const Radius.circular(8.5),
      ),
      Paint()..color = _bodyTop,
    );

    // 两道横纹，暗示草是一层层堆起来的。
    final texturePaint = Paint()
      ..color = _texture.withValues(alpha: 0.55)
      ..strokeWidth = 1.7
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    canvas
      ..drawPath(
        Path()
          ..moveTo(12, 34)
          ..quadraticBezierTo(32, 30, 52, 34),
        texturePaint,
      )
      ..drawPath(
        Path()
          ..moveTo(10, 46)
          ..quadraticBezierTo(32, 42, 54, 46),
        texturePaint,
      );

    final facePaint = Paint()..color = _face;

    if (sleeping) {
      // 打盹时眼睛是两道下弯的弧，不是圆点。
      final lid = Paint()
        ..color = _face
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;
      canvas
        ..drawArc(
          Rect.fromCircle(center: const Offset(24, 41), radius: 3.4),
          0,
          math.pi,
          false,
          lid,
        )
        ..drawArc(
          Rect.fromCircle(center: const Offset(40, 41), radius: 3.4),
          0,
          math.pi,
          false,
          lid,
        );
    } else {
      canvas
        ..drawCircle(const Offset(24, 42), 2.6, facePaint)
        ..drawCircle(const Offset(40, 42), 2.6, facePaint);
    }

    // 嘴。
    canvas.drawPath(
      Path()
        ..moveTo(27, 49)
        ..quadraticBezierTo(32, 53, 37, 49),
      Paint()
        ..color = _face
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(_HaystackPainter old) => old.sleeping != sleeping;
}
