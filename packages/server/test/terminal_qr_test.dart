import 'package:server/src/terminal_qr.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

/// 按行切开。注意**不能 trim**——留白和行尾空格正是要检查的东西，
/// 削掉了就等于把被测对象改了。
List<String> lines(String text) {
  final all = text.split('\n');
  if (all.isNotEmpty && all.last.isEmpty) all.removeLast();
  return all;
}

void main() {
  test('渲染出的二维码是方的', () {
    // 用半块字符一行表示两行模块。终端字符高约为宽的两倍，
    // 所以「行数 × 2 ≈ 列数」才是视觉上的正方形——拉长了就扫不出来。
    final rows = lines(
      renderQrToText('kanban://connect?host=192.168.1.23&port=8765'),
    );
    final width = rows.first.length;

    expect(rows.every((l) => l.length == width), isTrue, reason: '每行宽度要一致');
    expect(
      (rows.length * 2 - width).abs(),
      lessThanOrEqualTo(2),
      reason: '行数乘二应当约等于宽度，否则码被拉变形',
    );
  });

  test('四周有静默区，否则扫不出来', () {
    final rows = lines(renderQrToText('test', quietZone: 2));

    expect(rows.first.trim(), isEmpty, reason: '顶部要留白');
    expect(rows.last.trim(), isEmpty, reason: '底部要留白');
    for (final line in rows) {
      expect(line.startsWith('  '), isTrue, reason: '左侧要留白：[$line]');
      expect(line.endsWith('  '), isTrue, reason: '右侧要留白：[$line]');
    }
  });

  test('内容越长码越大', () {
    expect(
      lines(renderQrToText('a' * 300)).length,
      greaterThan(lines(renderQrToText('a')).length),
    );
  });

  test('真实的连接链接能渲染出来', () {
    const link = ConnectLink(host: '192.168.1.23', port: 8765, code: 'A1B2C3');
    final rows = lines(renderQrToText(link.toUri()));
    expect(rows.join(), contains('█'));
    expect(rows.length, greaterThan(10));
  });
}
