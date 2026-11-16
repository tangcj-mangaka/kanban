import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:kanban/ui/card/attachment_add.dart';
import 'package:kanban/ui/card/paste_image.dart';

/// 粘贴进来的图要先压一道再存。
///
/// 用户报的：同一张淘宝图，存成文件再复制进来 65KB，网页上右键复制直接
/// 粘贴进来 8.6MB。差 130 倍。
///
/// 原因是剪贴板里装的根本不是那个 JPEG 文件，是**解码后的位图**；
/// Windows 上剪贴板库交给我们的更直接——一张未压缩的 32 位 BMP。
void main() {
  /// 手搓一张 32bpp BI_RGB 的 BMP，第四个字节（X）填 0。
  ///
  /// Windows 剪贴板那条路产出的就是这种：`CF_DIB` → 32 位 XRGB 位图 →
  /// 写成 .bmp。手搓是因为这个格式在 Mac 上造不出来，而它恰恰是出问题
  /// 的那一种。
  Uint8List xrgbBmp(int w, int h, int Function(int x, int y) rgb) {
    const headerSize = 14 + 40;
    final data = BytesBuilder();
    final b = ByteData(headerSize);
    b.setUint8(0, 0x42); // 'B'
    b.setUint8(1, 0x4D); // 'M'
    b.setUint32(2, headerSize + w * h * 4, Endian.little);
    b.setUint32(10, headerSize, Endian.little);
    b.setUint32(14, 40, Endian.little); // BITMAPINFOHEADER
    b.setInt32(18, w, Endian.little);
    b.setInt32(22, h, Endian.little);
    b.setUint16(26, 1, Endian.little); // planes
    b.setUint16(28, 32, Endian.little); // 32bpp
    b.setUint32(30, 0, Endian.little); // BI_RGB
    data.add(b.buffer.asUint8List());
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final c = rgb(x, y);
        data.add([c & 0xFF, (c >> 8) & 0xFF, (c >> 16) & 0xFF, 0]);
      }
    }
    return data.toBytes();
  }

  /// 照片那样的内容。
  ///
  /// 渐变**加一层细颗粒**，不能只有渐变：纯渐变 PNG 能压到比 JPEG 还小，
  /// 拿它当照片测，测出来的结论是反的。真照片处处有细微起伏，PNG 预测
  /// 不了，JPEG 一量化就没了——这才是两者拉开差距的地方。
  Uint8List photoLike(int w, int h) {
    var seed = 12345;
    int noise() {
      seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
      return (seed >> 16) % 24 - 12;
    }

    return xrgbBmp(w, h, (x, y) {
      int clamp(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);
      final r = clamp(x * 255 ~/ w + noise());
      final g = clamp(y * 255 ~/ h + noise());
      final b = clamp(128 + noise());
      return (r << 16) | (g << 8) | b;
    });
  }

  Uint8List encode(img.Image image, {required bool png}) => Uint8List.fromList(
    png ? img.encodePng(image) : img.encodeJpg(image, quality: 90),
  );

  test('未压缩的 BMP 会被压下来，而且压得多', () {
    final raw = photoLike(600, 400);
    final out = squeezePastedImageSync(raw);

    expect(out.length, lessThan(raw.length ~/ 4), reason: '至少该小一个数量级');
    // 尺寸不变——我们只换编码，不缩图。附件是原件，不是缩略图。
    final decoded = img.decodeImage(out)!;
    expect(decoded.width, 600);
    expect(decoded.height, 400);
  });

  test('压完的后缀跟着真实格式走，不会留下一个叫 .bmp 的 JPEG', () {
    final out = squeezePastedImageSync(photoLike(600, 400));
    final name = pastedImageName(out);
    expect(name, endsWith('.jpg'), reason: '这种内容 JPEG 该赢');
  });

  test('有透明像素时不碰 JPEG', () {
    // JPEG 没有透明通道，转过去透明处会变成黑块。
    final image = img.Image(width: 80, height: 80, numChannels: 4);
    for (final p in image) {
      p.setRgba(200, 30, 30, p.x < 40 ? 255 : 0);
    }
    final raw = encode(image, png: true);

    final out = squeezePastedImageSync(raw);
    final decoded = img.decodeImage(out)!;
    expect(decoded.getPixel(60, 10).a, 0, reason: '透明的那半还得是透明的');
  });

  test('32 位 XRGB 不算透明', () {
    // 这是最容易写错的一处：Windows 剪贴板出来的位图**有** alpha 通道，
    // 但每个像素都是不透明的。照 `hasAlpha` 判断的话 JPEG 永远用不上，
    // 等于这个功能白做。
    final raw = photoLike(400, 300);
    final out = squeezePastedImageSync(raw);
    expect(pastedImageName(out), endsWith('.jpg'));
  });

  test('文字截图那种内容留无损，不会被 JPEG 糊掉', () {
    // 纯黑白、大片同色——PNG 的主场，JPEG 反而更大，还会在笔画边上起毛刺。
    final image = img.Image(width: 400, height: 300);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    for (var y = 20; y < 280; y += 12) {
      img.drawLine(
        image,
        x1: 20,
        y1: y,
        x2: 380,
        y2: y,
        color: img.ColorRgb8(0, 0, 0),
      );
    }
    final raw = encode(image, png: true);

    final out = squeezePastedImageSync(raw);
    expect(pastedImageName(out), endsWith('.png'));
  });

  test('本来就是压好的 JPEG，就留着不动', () {
    // 再编一道只会掉画质，省不下多少。
    final raw = encode(img.decodeImage(photoLike(400, 300))!, png: false);

    expect(squeezePastedImageSync(raw), same(raw));
  });

  test('解不开的东西原样返回，不能把用户粘的内容弄丢', () {
    final junk = Uint8List.fromList(List.filled(300, 7));
    expect(squeezePastedImageSync(junk), same(junk));
  });

  test('空字节也不炸', () {
    final empty = Uint8List(0);
    expect(squeezePastedImageSync(empty), same(empty));
  });
}
