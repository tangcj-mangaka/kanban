import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanban/ui/theme/app_theme.dart';
import 'package:kanban/ui/theme/palette.dart';
import 'package:shared/shared.dart';

void main() {
  test('UI 色板与领域层的 key 列表严格一致', () {
    // 数据库里存的是 key。UI 少定义一个色，那个色的卡片就会退化成无色；
    // 多定义一个，则是个永远存不进数据库的死色。两边必须同步改。
    expect(kSwatches.map((s) => s.key).toList(), kSwatchKeys);
  });

  test('每个色在浅深两个主题下都有独立的一组值', () {
    for (final s in kSwatches) {
      expect(
        s.light.surface,
        isNot(s.dark.surface),
        reason: '${s.key} 的深色底色不该照搬浅色',
      );
      expect(
        s.light.accent,
        isNot(s.dark.accent),
        reason: '${s.key} 的深色标签色不该照搬浅色',
      );
    }
  });

  test('未知的 key 退化成无色/灰，不抛异常', () {
    // 以后换色板时，数据库里可能残留旧 key。这时必须安静降级，
    // 不能让整个画布因为一个未知颜色崩掉。
    const k = KanbanColors.light;
    expect(k.cardSurface('这个色不存在'), k.cardPlain);
    expect(k.cardSurface(null), k.cardPlain);
    expect(k.accent('这个色不存在'), kSwatchByKey[kDefaultTagSwatch]!.light.accent);
  });

  test('两个主题的卡片文字色与底色区分得开', () {
    for (final theme in [KanbanColors.light, KanbanColors.dark]) {
      for (final s in kSwatches) {
        final surface = s.tones(theme.brightness).surface;
        expect(
          _contrast(surface, theme.cardTitle),
          greaterThan(4.5),
          reason: '${theme.brightness.name} 主题下，${s.key} 底色上的标题对比度不足',
        );
      }
    }
  });
}

/// WCAG 相对亮度对比度。4.5 是正文级别的及格线。
double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

double _luminance(Color c) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}
