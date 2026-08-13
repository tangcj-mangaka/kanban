/// 从 [paintAppIcon] 生成三个平台的启动图标文件。
///
/// 不在 `test/` 目录下，所以 `flutter test` 和 CI 都不会碰它。
/// 改了驴的画法之后手动跑一次：
///
/// ```
/// flutter test tool/gen_icons.dart
/// ```
///
/// 为什么要借 `flutter test` 跑：把 Canvas 画的东西编码成 PNG 需要真正的
/// 图形引擎（`Picture.toImage`），纯 Dart 命令行跑不了。测试框架正好带一个。
///
/// 生成的 PNG/ICO 是**提交进仓库**的产物——CI 构建时不会重新生成，
/// 那样每台构建机都得有图形环境，不值当。
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:kanban/ui/theme/donkey_icon.dart';
import 'package:path/path.dart' as p;

/// 把一段绘制指令渲染成 PNG 字节。
Future<List<int>> _render(int size, void Function(ui.Canvas, double) draw) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  draw(canvas, size.toDouble());
  final picture = recorder.endRecording();
  final image = await picture.toImage(size, size);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  picture.dispose();
  image.dispose();
  return data!.buffer.asUint8List();
}

/// 完整图标：圆角底 + 驴。
Future<List<int>> _icon(int size) => _render(size, paintAppIcon);

/// 驴这个图形在 64×64 画板里**实际**占的范围。
///
/// 不是 0,0,64,64——驴的头顶到嘴巴只有 y 的 10.8~51，左耳到草尖是 x 的
/// 15~57.2。按整块画板去缩放定位的话，四周会多出一圈本来就是空的边距，
/// 图标在启动器里看着缩成一小团、还偏在一边。
const _artBounds = ui.Rect.fromLTRB(14.97, 10.8, 57.2, 51.0);

/// 安卓自适应图标的前景层：只有驴，按安全区居中放大。
///
/// 自适应图标的画板是 108dp，但系统会按各家厂商的形状（圆、方、水滴）
/// 去裁，只有中间 72dp（66.7%）保证不被裁掉。所以让驴的**长边**占到
/// 画板的 64%，再按图形的实际中心对齐——而不是按画板中心，
/// 那样会因为右边多出一根草而整体偏左。
Future<List<int>> _adaptiveForeground(int size) => _render(size, (canvas, s) {
  const longSide = 42.23; // _artBounds 的宽（比高大）
  final drawSize = s * 0.64 * 64 / longSide;
  final scale = drawSize / 64;

  canvas.save();
  canvas.translate(
    s / 2 - _artBounds.center.dx * scale,
    s / 2 - _artBounds.center.dy * scale,
  );
  paintDonkey(canvas, drawSize);
  canvas.restore();
});

void main() {
  test('生成启动图标', () async {
    final root = Directory.current.path; // packages/app
    var written = 0;

    Future<void> write(String relative, List<int> bytes) async {
      final file = File(p.join(root, relative));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
      written++;
    }

    // ---- 安卓：旧版方图标 ----
    const androidLegacy = {
      'mipmap-mdpi': 48,
      'mipmap-hdpi': 72,
      'mipmap-xhdpi': 96,
      'mipmap-xxhdpi': 144,
      'mipmap-xxxhdpi': 192,
    };
    for (final e in androidLegacy.entries) {
      await write(
        'android/app/src/main/res/${e.key}/ic_launcher.png',
        await _icon(e.value),
      );
    }

    // ---- 安卓：自适应图标前景（Android 8 以上用这套）----
    const androidAdaptive = {
      'mipmap-mdpi': 108,
      'mipmap-hdpi': 162,
      'mipmap-xhdpi': 216,
      'mipmap-xxhdpi': 324,
      'mipmap-xxxhdpi': 432,
    };
    for (final e in androidAdaptive.entries) {
      await write(
        'android/app/src/main/res/${e.key}/ic_launcher_foreground.png',
        await _adaptiveForeground(e.value),
      );
    }

    // ---- macOS ----
    for (final size in [16, 32, 64, 128, 256, 512, 1024]) {
      await write(
        'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_$size.png',
        await _icon(size),
      );
    }

    // ---- Windows：多尺寸打进一个 .ico ----
    //
    // 一个 ico 里要塞好几个尺寸，是因为 Windows 在不同地方用不同大小：
    // 任务栏 16、桌面 48、大图标视图 256。只放一个尺寸的话，其余场合
    // 由系统缩放，缩出来会糊。
    final frames = <img.Image>[];
    for (final size in [16, 32, 48, 64, 128, 256]) {
      final png = await _icon(size);
      frames.add(img.decodePng(Uint8List.fromList(png))!);
    }
    await write('windows/runner/resources/app_icon.ico', img.IcoEncoder().encodeImages(frames));

    expect(written, greaterThan(15));
    // ignore: avoid_print
    print('已生成 $written 个图标文件');
  });
}
