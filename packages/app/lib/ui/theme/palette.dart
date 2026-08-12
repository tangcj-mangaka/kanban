import 'package:flutter/material.dart';

/// 一个色板项在某个主题下的两个值。
///
/// [surface] 是卡片底色，大面积铺开，必须够浅/够深不抢眼；
/// [accent] 是同一色相的饱和版，用在标签色点这类小面积高辨识的地方。
@immutable
class SwatchTones {
  final Color surface;
  final Color accent;

  const SwatchTones(this.surface, this.accent);
}

/// 色板中的一色。
///
/// 卡片底色和标签色共用同一套色板，视觉才统一。每色在浅色和深色主题下
/// **各有一组值**，不是把浅色值调暗了事——直接调暗会让文字对比度掉到
/// 不可读，深色那组是单独定的。
@immutable
class Swatch {
  /// 存进数据库的标识。存 key 而不是十六进制值，以后换色板不用迁移数据。
  final String key;
  final String label;
  final SwatchTones light;
  final SwatchTones dark;

  const Swatch(this.key, this.label, this.light, this.dark);

  SwatchTones tones(Brightness b) => b == Brightness.dark ? dark : light;
}

/// 色板 B「明快」。见设计文档 §7.2。
///
/// 12 色 + 无色，不提供任意取色器——个人取色十有八九会把画布搞得很花，
/// 预设色板能保证怎么点都好看。
const List<Swatch> kSwatches = [
  Swatch('red', '红',
      SwatchTones(Color(0xFFFFE0DC), Color(0xFFD93A2B)),
      SwatchTones(Color(0xFF4A2320), Color(0xFFFF9C90))),
  Swatch('orange', '橙',
      SwatchTones(Color(0xFFFFE7CE), Color(0xFFE07A00)),
      SwatchTones(Color(0xFF45301A), Color(0xFFFFB74D))),
  Swatch('yellow', '黄',
      SwatchTones(Color(0xFFFFF3C9), Color(0xFFB99000)),
      SwatchTones(Color(0xFF403716), Color(0xFFF0C93B))),
  Swatch('lime', '柠',
      SwatchTones(Color(0xFFECF7C6), Color(0xFF78A600)),
      SwatchTones(Color(0xFF2E3818), Color(0xFFC3E256))),
  Swatch('green', '绿',
      SwatchTones(Color(0xFFD6F2DD), Color(0xFF1F9D51)),
      SwatchTones(Color(0xFF1D3527), Color(0xFF6EDB99))),
  Swatch('teal', '青',
      SwatchTones(Color(0xFFCFF0EF), Color(0xFF009490)),
      SwatchTones(Color(0xFF143331), Color(0xFF4FD6CE))),
  Swatch('blue', '蓝',
      SwatchTones(Color(0xFFD8E8FD), Color(0xFF1B72D0)),
      SwatchTones(Color(0xFF182B42), Color(0xFF82BAF7))),
  Swatch('indigo', '靛',
      SwatchTones(Color(0xFFDFE0FC), Color(0xFF4A4FD0)),
      SwatchTones(Color(0xFF24254A), Color(0xFFA9ACF9))),
  Swatch('purple', '紫',
      SwatchTones(Color(0xFFEDDDFB), Color(0xFF8A3FC4)),
      SwatchTones(Color(0xFF33214A), Color(0xFFCB9BF0))),
  Swatch('pink', '粉',
      SwatchTones(Color(0xFFFDDCEA), Color(0xFFCE3A7E)),
      SwatchTones(Color(0xFF43202F), Color(0xFFF893BE))),
  Swatch('brown', '棕',
      SwatchTones(Color(0xFFEFE2D4), Color(0xFF8D6134)),
      SwatchTones(Color(0xFF38291B), Color(0xFFD2A776))),
  Swatch('gray', '灰',
      SwatchTones(Color(0xFFE6E8EA), Color(0xFF5F676D)),
      SwatchTones(Color(0xFF262A2D), Color(0xFFA8B0B6))),
];

final Map<String, Swatch> kSwatchByKey = {
  for (final s in kSwatches) s.key: s,
};

/// 界面主色。只用在按钮、选中态、状态指示器上，不参与卡片配色。
const Color kBrandColor = Color(0xFF4A4FD0);

/// 无色卡片的底色。
const SwatchTones kPlainCard = SwatchTones(Color(0xFFFFFFFF), Color(0xFF9C978E));
const Color kPlainCardDark = Color(0xFF26262A);
