import 'package:flutter/material.dart';

/// 画布的视口变换：世界坐标 ↔ 屏幕坐标。
///
/// 卡片的 x/y 存的是**世界坐标**，与当前缩放和平移无关。屏幕上画在哪，
/// 由这个变换现算。这样缩放平移完全是视图状态，不产生任何 op，
/// 也不会同步到别的设备——每台设备各看各的视角，互不干扰。
@immutable
class CanvasTransform {
  /// 世界原点在屏幕上的位置。
  final Offset offset;

  final double scale;

  const CanvasTransform({this.offset = Offset.zero, this.scale = 1});

  static const double minScale = 0.2;
  static const double maxScale = 3.0;

  Offset toScreen(Offset world) => world * scale + offset;

  Offset toWorld(Offset screen) => (screen - offset) / scale;

  CanvasTransform panBy(Offset delta) =>
      CanvasTransform(offset: offset + delta, scale: scale);

  /// 以屏幕上的 [focus] 为锚点缩放——该点下的内容保持不动。
  ///
  /// 不这么做的话，缩放会以窗口左上角为中心，鼠标指着的东西会跑掉，
  /// 手感很差。
  CanvasTransform zoomTo(double newScale, Offset focus) {
    final clamped = newScale.clamp(minScale, maxScale);
    final world = toWorld(focus);
    return CanvasTransform(offset: focus - world * clamped, scale: clamped);
  }

  CanvasTransform zoomBy(double factor, Offset focus) =>
      zoomTo(scale * factor, focus);

  /// 缩放并平移到能装下 [bounds] 的视角。
  static CanvasTransform fit(Rect bounds, Size viewport, {double padding = 60}) {
    if (bounds.isEmpty || viewport.isEmpty) return const CanvasTransform();

    final sx = (viewport.width - padding * 2) / bounds.width;
    final sy = (viewport.height - padding * 2) / bounds.height;
    final scale = sx < sy ? sx : sy;
    // 只缩小不放大：卡片很少时把画布拉到 3 倍并不好看。
    final clamped = scale.clamp(minScale, 1.0);

    final center = bounds.center * clamped;
    final viewCenter = Offset(viewport.width / 2, viewport.height / 2);
    return CanvasTransform(offset: viewCenter - center, scale: clamped);
  }

  @override
  bool operator ==(Object other) =>
      other is CanvasTransform && other.offset == offset && other.scale == scale;

  @override
  int get hashCode => Object.hash(offset, scale);
}
