import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// 把剪贴板里的图重新编码一遍，三份里挑最小的那份存。
///
/// **为什么非做不可**：网页上右键「复制图片」，系统放进剪贴板的不是那个
/// JPEG 文件，是**解码后的一张位图**——压缩在那一刻就没了。Windows 上更
/// 直接，剪贴板库读 `CF_DIB` 之后写出来的是一张**未压缩的 32 位 BMP**，
/// 体积就是一道乘法：宽 × 高 × 4。实测一张 1500×1500 的淘宝主图，原图
/// JPEG 65KB，摊成 BMP 是 8.6MB，**130 倍**。这 8.6MB 还要原样过局域网、
/// 落到手机上、在服务端留着。
///
/// **为什么不直接定一种格式**：没有哪一种一直赢。照片类 JPEG 小得多；
/// 截图、界面图、带文字的图 PNG 反而更小，而且转 JPEG 会把字糊掉。所以
/// 两种都编一次，谁小用谁。
///
/// 规则：
/// - 解不开就原样返回——**宁可存大的，也不能把用户粘的东西弄丢**
/// - 有真透明像素就不考虑 JPEG（JPEG 没有透明通道，会填成黑块）
/// - JPEG 要**比无损那份小三成以上**才算赢。势均力敌时留无损的，
///   省得一张文字截图为了省几 KB 被糊掉
///
/// 只走剪贴板这一条路。用户自己选的文件、拖进来的文件一个字节都不动：
/// 那是他挑的东西，原样存着才对，而且那种图往往带着 EXIF 方向信息，
/// 重编码容易把照片转向。
Future<Uint8List> squeezePastedImage(Uint8List raw) =>
    // 放到后台 isolate：两次编码在这个量级上要半秒左右，占着 UI 线程
    // 的话，粘一张图界面就卡一下。
    compute(squeezePastedImageSync, raw);

/// [squeezePastedImage] 的同步版本，测试直接用这个。
@visibleForTesting
Uint8List squeezePastedImageSync(Uint8List raw) {
  final img.Image? decoded;
  try {
    decoded = img.decodeImage(raw);
  } on Object {
    return raw;
  }
  if (decoded == null) return raw;

  var best = raw;

  try {
    final png = img.encodePng(decoded);
    if (png.length < best.length) best = Uint8List.fromList(png);
  } on Object {
    // 编不出来就算了，还有原样那一份兜着。
  }

  if (!_hasTransparentPixel(decoded)) {
    try {
      final jpg = img.encodeJpg(decoded, quality: 90);
      if (jpg.length * 10 <= best.length * 7) best = Uint8List.fromList(jpg);
    } on Object {
      // 同上
    }
  }

  return best;
}

/// 真的有像素不是全不透明吗。
///
/// **不能用 `image.hasAlpha`**：那只说明这张图有没有 alpha 通道。Windows
/// 剪贴板出来的是 32 位 XRGB，第四个字节本来就在，`hasAlpha` 永远是 true，
/// 照它判断的话 JPEG 这条路永远走不到，白白多存好几倍。
///
/// 实测 image 包把 32bpp BI_RGB 里那个没用的字节读成 255（不透明），
/// 和 Windows 的约定一致，所以逐像素看 alpha 是可靠的。
/// 225 万像素扫一遍约 7ms，相对两次编码可以忽略。
bool _hasTransparentPixel(img.Image image) {
  if (!image.hasAlpha) return false;
  for (final pixel in image) {
    if (pixel.a != pixel.maxChannelValue) return true;
  }
  return false;
}
