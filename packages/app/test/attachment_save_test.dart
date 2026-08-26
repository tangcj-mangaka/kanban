import 'package:flutter_test/flutter_test.dart';
import 'package:kanban/ui/card/attachment_save.dart';

/// 文件名清洗：附件名是从别的设备同步过来的，可能带上本平台不接受的字符。
/// Windows 不认 `: ? * " < > | \\ /`，而它们在 macOS/Linux 上是合法的——
/// 手机上起的名字同步到 Windows 就可能存不下来。
void main() {
  group('保存时的文件名清洗', () {
    test('Windows 不认的字符被替换掉', () {
      expect(safeFileNameForTest('报告:2026?.pdf'), '报告_2026_.pdf');
      expect(safeFileNameForTest('a/b\\c.png'), 'a_b_c.png');
      expect(safeFileNameForTest('引用"这个".txt'), '引用_这个_.txt');
    });

    test('中文和空格保留', () {
      expect(safeFileNameForTest('会议 纪要.docx'), '会议 纪要.docx');
    });

    test('控制字符被替换', () {
      expect(safeFileNameForTest('图\u0007片.png'), '图_片.png');
    });

    test('空名字给个兜底，不能返回空串', () {
      // 空文件名会让另存为对话框和分享面板都出问题。
      expect(safeFileNameForTest(''), '附件');
      expect(safeFileNameForTest('   '), '附件');
    });

    test('正常名字原样返回', () {
      expect(safeFileNameForTest('照片.jpg'), '照片.jpg');
    });
  });
}
