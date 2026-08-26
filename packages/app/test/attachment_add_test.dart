import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanban/ui/card/attachment_add.dart';

/// 剪贴板里的图片没有文件名，得自己起一个。后缀必须按**内容的魔数**判断，
/// 不能瞎猜——从聊天工具复制出来的可能是 PNG 也可能是 JPEG，后缀错了在
/// 别的程序里打不开。
void main() {
  /// 各格式的文件头魔数。
  Uint8List header(List<int> bytes) =>
      Uint8List.fromList([...bytes, ...List.filled(32, 0)]);

  group('给粘贴的图片起名', () {
    test('PNG 认得出来', () {
      final name = pastedImageName(
        header([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
      );
      expect(name, endsWith('.png'));
      expect(name, startsWith('粘贴的图片-'));
    });

    test('JPEG 认得出来，用 .jpg 而不是 .jpeg', () {
      expect(pastedImageName(header([0xFF, 0xD8, 0xFF, 0xE0])), endsWith('.jpg'));
    });

    test('GIF 认得出来', () {
      expect(
        pastedImageName(header([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])),
        endsWith('.gif'),
      );
    });

    test('认不出来的内容退回 png，不能没有后缀', () {
      // 没后缀的文件在 Windows 上双击打不开，也不知道用什么程序。
      expect(pastedImageName(header([1, 2, 3, 4])), endsWith('.png'));
    });

    test('名字带时间戳，连续粘两张不会重名', () {
      // 重名本身不会覆盖数据（内容按哈希存），但附件列表里两个同名条目
      // 分不清谁是谁。
      final a = pastedImageName(header([0x89, 0x50, 0x4E, 0x47]));
      expect(RegExp(r'粘贴的图片-\d{8}-\d{6}\.png').hasMatch(a), isTrue);
    });
  });
}
