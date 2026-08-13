import 'package:flutter/material.dart';

import 'palette.dart';

/// 色板之外、界面自己要用的一组颜色。
///
/// 挂在 ThemeData 的扩展上，widget 通过 `Theme.of(context).kanban` 取，
/// 不在 widget 里写死颜色——浅色深色各一套，写死就等于只做对一半。
@immutable
class KanbanColors extends ThemeExtension<KanbanColors> {
  final Brightness brightness;

  /// 画布底色与网格点。网格点提供空间参照，但要淡到不干扰阅读。
  final Color canvas;
  final Color canvasDot;

  /// 无色卡片的底色。
  final Color cardPlain;

  final Color cardBorder;
  final Color cardTitle;
  final Color cardBody;

  /// 分隔线。
  final Color hairline;

  const KanbanColors({
    required this.brightness,
    required this.canvas,
    required this.canvasDot,
    required this.cardPlain,
    required this.cardBorder,
    required this.cardTitle,
    required this.cardBody,
    required this.hairline,
  });

  bool get isDark => brightness == Brightness.dark;

  /// 已完成卡片的底色和边框。
  ///
  /// 完成态**盖掉**卡片本来的颜色——卡片色是用来分类的，而「做完了」
  /// 要一眼扫出来，两者叠在一起谁都看不清。
  Color get doneSurface =>
      isDark ? const Color(0xFF3A2A2C) : const Color(0xFFFBEAE9);

  /// 边框和勾选框的实色。带 alpha 是给边框用的，勾选框会把它调到不透明。
  Color get doneBorder =>
      isDark ? const Color(0x66FF8A80) : const Color(0x55C1613A);

  /// 完成卡片左边那道色条。
  ///
  /// **光靠淡红底色是不够的**：色板里本来就有「红」(#FFE0DC) 和
  /// 「粉」(#FDDCEA) 两种卡片色，和完成态的淡红几乎一个色，
  /// 一眼扫过去分不出「这张做完了」和「这张是粉色的」。
  /// 色条是实色竖杠，色板不会产生这种形状，才真的区分得开。
  Color get doneStripe =>
      isDark ? const Color(0xFFFF9C90) : const Color(0xFFD93A2B);

  /// 卡片底色。[key] 为 null 表示无色卡片。
  Color cardSurface(String? key) {
    if (key == null) return cardPlain;
    return kSwatchByKey[key]?.tones(brightness).surface ?? cardPlain;
  }

  /// 标签色点、色块用的饱和色。
  Color accent(String? key) {
    return kSwatchByKey[key]?.tones(brightness).accent ??
        kSwatchByKey['gray']!.tones(brightness).accent;
  }

  static const light = KanbanColors(
    brightness: Brightness.light,
    canvas: Color(0xFFF4F2ED),
    canvasDot: Color(0x11000000),
    cardPlain: Color(0xFFFFFFFF),
    cardBorder: Color(0x12000000),
    cardTitle: Color(0xFF232220),
    cardBody: Color(0xFF6E6B63),
    hairline: Color(0xFFDFDAD0),
  );

  static const dark = KanbanColors(
    brightness: Brightness.dark,
    canvas: Color(0xFF1B1B1E),
    canvasDot: Color(0x14FFFFFF),
    cardPlain: Color(0xFF26262A),
    cardBorder: Color(0x17FFFFFF),
    cardTitle: Color(0xFFEAE7E1),
    cardBody: Color(0xFF9C978E),
    hairline: Color(0xFF383430),
  );

  @override
  KanbanColors copyWith({
    Brightness? brightness,
    Color? canvas,
    Color? canvasDot,
    Color? cardPlain,
    Color? cardBorder,
    Color? cardTitle,
    Color? cardBody,
    Color? hairline,
  }) => KanbanColors(
    brightness: brightness ?? this.brightness,
    canvas: canvas ?? this.canvas,
    canvasDot: canvasDot ?? this.canvasDot,
    cardPlain: cardPlain ?? this.cardPlain,
    cardBorder: cardBorder ?? this.cardBorder,
    cardTitle: cardTitle ?? this.cardTitle,
    cardBody: cardBody ?? this.cardBody,
    hairline: hairline ?? this.hairline,
  );

  @override
  KanbanColors lerp(ThemeExtension<KanbanColors>? other, double t) {
    if (other is! KanbanColors) return this;
    return KanbanColors(
      brightness: t < 0.5 ? brightness : other.brightness,
      canvas: Color.lerp(canvas, other.canvas, t)!,
      canvasDot: Color.lerp(canvasDot, other.canvasDot, t)!,
      cardPlain: Color.lerp(cardPlain, other.cardPlain, t)!,
      cardBorder: Color.lerp(cardBorder, other.cardBorder, t)!,
      cardTitle: Color.lerp(cardTitle, other.cardTitle, t)!,
      cardBody: Color.lerp(cardBody, other.cardBody, t)!,
      hairline: Color.lerp(hairline, other.hairline, t)!,
    );
  }
}

extension KanbanTheme on ThemeData {
  KanbanColors get kanban => extension<KanbanColors>()!;
}

ThemeData buildTheme(Brightness brightness) {
  final kanban = brightness == Brightness.dark
      ? KanbanColors.dark
      : KanbanColors.light;

  // 用固定种子色生成配色，不跟随系统取色——保证 Windows 和 Android 上
  // 观感完全一致。
  final scheme = ColorScheme.fromSeed(
    seedColor: kBrandColor,
    brightness: brightness,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: kanban.canvas,
    extensions: [kanban],
    dividerTheme: DividerThemeData(color: kanban.hairline, thickness: 1, space: 1),
    cardTheme: CardThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    inputDecorationTheme: InputDecorationThemeData(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      isDense: true,
    ),
    tooltipTheme: const TooltipThemeData(waitDuration: Duration(milliseconds: 500)),
  );
}
