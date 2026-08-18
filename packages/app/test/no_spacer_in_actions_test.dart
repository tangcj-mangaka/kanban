import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守住一个只在**发布版**才会露面的坑。
///
/// `AlertDialog.actions` 用 `OverflowBar` 布局，它不是 Flex；而 `Spacer`
/// 本质是 `Expanded`，只能用在 Flex 里。放错地方的后果分两种：
///
/// - 调试版：断言失败，能看到报错
/// - **发布版：抛类型错误，整棵子树被换成一个灰色方块**——不报错、不崩溃，
///   界面上就是一块什么都没有的灰色
///
/// v0.2.0 的同步设置弹窗就是这么废掉的：配对界面整个变成灰块，而配对是
/// 这个应用最关键的一步。单元测试查不出来，调试版跑也正常。
///
/// 这个检查是**源码文本层面**的启发式，不完美（比如变量名叫 actions 的
/// 普通列表也会被扫到），但它拦住的是一类沉默的致命错误，误报一次的代价
/// 只是改个写法。
void main() {
  test('AlertDialog 的 actions 里不能有 Spacer', () {
    final offenders = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();

      // 从每个 `actions: [` 起，扫到与之配对的 `]`，看里面有没有 Spacer。
      for (final match in RegExp(r'actions:\s*\[').allMatches(source)) {
        var depth = 1;
        var i = match.end;
        while (i < source.length && depth > 0) {
          final c = source[i];
          if (c == '[') depth++;
          if (c == ']') depth--;
          i++;
        }
        final body = source.substring(match.end, i);
        if (body.contains('Spacer(')) {
          offenders.add(entity.path);
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          '这些文件在 actions 里用了 Spacer，发布版会变成灰色方块：\n'
          '${offenders.join('\n')}\n'
          '想让某项靠左的话，把它挪到 title 的 Row 里，或者放进 content。',
    );
  });
}
