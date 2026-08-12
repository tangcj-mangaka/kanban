import 'package:qr/qr.dart';

/// 把一段文本渲染成终端里能扫的二维码。
///
/// 服务端是个控制台程序，直接在终端里印出来最省事——手机对着屏幕一扫就
/// 连上，不用手抄 IP 和 6 位配对码。抄错一个字符就得重来，扫码把这个
/// 环节整个去掉了。
///
/// 用上半块字符 `▀`，一行文本表示两行模块——终端字符高约为宽的两倍，
/// 这样出来的码接近正方形，不会被拉长成扫不出来的形状。
String renderQrToText(String data, {int quietZone = 2}) {
  final qr = QrCode(
    payload: QrPayload.fromString(data),
    errorCorrectLevel: QrErrorCorrectLevel.medium,
  );
  final image = QrImage(qr);
  final size = qr.moduleCount;
  final total = size + quietZone * 2;

  // true 表示深色模块。静默区（边框）一律浅色，没有它扫不出来。
  bool dark(int row, int col) {
    final r = row - quietZone;
    final c = col - quietZone;
    if (r < 0 || c < 0 || r >= size || c >= size) return false;
    return image.isDark(r, c);
  }

  final buffer = StringBuffer();
  for (var row = 0; row < total; row += 2) {
    for (var col = 0; col < total; col++) {
      final top = dark(row, col);
      final bottom = row + 1 < total && dark(row + 1, col);
      // 终端默认浅底深字，所以"深色模块"对应打印出字符。
      buffer.write(switch ((top, bottom)) {
        (true, true) => '█',
        (true, false) => '▀',
        (false, true) => '▄',
        (false, false) => ' ',
      });
    }
    buffer.writeln();
  }
  return buffer.toString();
}
