/// 导出一张透明底的驴（叼着干草）PNG，给做头像、贴纸之类用。
///
/// ```
/// flutter test tool/export_donkey.dart
/// ```
///
/// 和应用图标共用同一份画法（[paintDonkey]），所以导出的驴和应用里的
/// 一模一样。裁到图形的实际边界——按 64×64 的整块画板导会四周多一圈空白。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:kanban/ui/theme/donkey_icon.dart';

/// 驴在 64×64 画板里实际占的范围（左耳到草尖、耳尖到嘴巴）。
const _art = ui.Rect.fromLTRB(14.97, 10.8, 57.2, 51.0);

void main() {
  test('导出透明底的驴', () async {
    final outDir = Directory('${Directory.systemTemp.path}/kanban-donkey')
      ..createSync(recursive: true);

    for (final size in [256, 512, 1024, 2048]) {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);

      // 缩放到让图形的长边填满画布，再平移让图形左上角对齐原点。
      final scale = size / _art.width;
      canvas.translate(-_art.left * scale, -_art.top * scale);
      paintDonkey(canvas, 64 * scale);

      final height = (_art.height * scale).round();
      final image = await recorder.endRecording().toImage(size, height);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();

      final file = File('${outDir.path}/驴叼干草-$size.png');
      await file.writeAsBytes(data!.buffer.asUint8List());
      // ignore: avoid_print
      print('${file.path}  ${size}x$height');
    }
  });
}
