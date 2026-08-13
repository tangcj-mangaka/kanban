import 'package:flutter/widgets.dart';

/// 窄屏（手机）判断。
///
/// 按宽度而不是按平台判断：Windows 上把窗口拖窄了也该用紧凑布局，
/// 而平板横屏时该用宽的那套。
bool isCompact(BuildContext context) => MediaQuery.sizeOf(context).width < 700;

/// 弹窗在窄屏上占满，在宽屏上按给定宽度居中。
///
/// 手机上留边距的弹窗既浪费空间又难点——760px 的卡片详情在 390px 的
/// 屏幕上根本放不下。
double dialogWidth(BuildContext context, double preferred) {
  final width = MediaQuery.sizeOf(context).width;
  return width < preferred + 48 ? width - 24 : preferred;
}

double dialogHeight(BuildContext context, {double fraction = 0.86}) {
  final height = MediaQuery.sizeOf(context).height;
  return isCompact(context) ? height - 60 : (height * fraction).clamp(420.0, 760.0);
}
