import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 叼着一根干草的驴头——就是当初选定的应用图标那只。
///
/// 图标本身带一块浅色底，这里只画驴，好摆在任何背景上。用在空看板列表
/// 这类地方：一片空白配一行小字太冷淡了，这个应用叫「驴看板」，
/// 空的时候让它露个脸。
///
/// 和 [HaystackIcon] 一样，颜色写死不跟主题走——品牌形象不该变色。
class DonkeyIcon extends StatelessWidget {
  final double size;

  /// 叼不叼那根草。小尺寸下草茎会糊成一团，不如去掉。
  final bool withStraw;

  const DonkeyIcon({super.key, required this.size, this.withStraw = true});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _DonkeyPainter(withStraw: withStraw)),
    );
  }
}

class _DonkeyPainter extends CustomPainter {
  final bool withStraw;

  const _DonkeyPainter({required this.withStraw});

  static const _art = 64.0;

  static const _ear = Color(0xFF8B8178);
  static const _earInner = Color(0xFFB7A294);
  static const _head = Color(0xFF7C7269);
  static const _muzzle = Color(0xFFCFC5B9);
  static const _eye = Color(0xFF2E2924);
  static const _straw = Color(0xFFE0B44A);
  static const _strawDark = Color(0xFFC99A2E);

  /// 画一个绕自身中心转过 [degrees] 的椭圆。
  ///
  /// 耳朵是斜着支棱出去的，正椭圆画不出来。
  void _tiltedOval(
    Canvas canvas,
    Offset center,
    double rx,
    double ry,
    double degrees,
    Color color,
  ) {
    canvas
      ..save()
      ..translate(center.dx, center.dy)
      ..rotate(degrees * math.pi / 180)
      ..drawOval(
        Rect.fromCenter(center: Offset.zero, width: rx * 2, height: ry * 2),
        Paint()..color = color,
      )
      ..restore();
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / _art);

    // 两只耳朵，先画外廓再画内耳。
    _tiltedOval(canvas, const Offset(21, 21), 5.5, 10.5, -16, _ear);
    _tiltedOval(canvas, const Offset(43, 21), 5.5, 10.5, 16, _ear);
    _tiltedOval(canvas, const Offset(21.5, 22), 2.7, 6, -16, _earInner);
    _tiltedOval(canvas, const Offset(42.5, 22), 2.7, 6, 16, _earInner);

    // 脑袋和浅色的嘴部。
    canvas
      ..drawOval(
        Rect.fromCenter(center: const Offset(32, 35), width: 27, height: 25),
        Paint()..color = _head,
      )
      ..drawOval(
        Rect.fromCenter(center: const Offset(32, 44), width: 18, height: 14),
        Paint()..color = _muzzle,
      )
      ..drawCircle(const Offset(26.5, 33), 2.3, Paint()..color = _eye)
      ..drawCircle(const Offset(37.5, 33), 2.3, Paint()..color = _eye);

    if (withStraw) {
      canvas.drawLine(
        const Offset(40, 47),
        const Offset(54, 43),
        Paint()
          ..color = _straw
          ..strokeWidth = 3.4
          ..strokeCap = StrokeCap.round,
      );
      final leaf = Paint()
        ..color = _strawDark
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round;
      canvas
        ..drawLine(const Offset(48, 45), const Offset(52, 39), leaf)
        ..drawLine(const Offset(50, 44.4), const Offset(56, 45), leaf);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(_DonkeyPainter old) => old.withStraw != withStraw;
}
