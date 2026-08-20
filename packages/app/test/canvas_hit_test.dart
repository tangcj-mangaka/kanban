import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanban/ui/canvas/canvas_transform.dart';

typedef Box = ({String id, Rect rect});

void main() {
  Rect rectOf(Box b) => b.rect;

  group('topmostAt', () {
    test('落在里面就命中', () {
      const boxes = [(id: 'a', rect: Rect.fromLTWH(0, 0, 100, 50))];
      expect(topmostAt(const Offset(50, 25), boxes, rectOf)?.id, 'a');
    });

    test('落在外面返回 null', () {
      const boxes = [(id: 'a', rect: Rect.fromLTWH(0, 0, 100, 50))];
      expect(topmostAt(const Offset(150, 25), boxes, rectOf), isNull);
      expect(topmostAt(const Offset(50, 80), boxes, rectOf), isNull);
    });

    test('重叠时命中最上面那张', () {
      // 列表靠后的画在上面，所以该命中 b。
      const boxes = [
        (id: 'a', rect: Rect.fromLTWH(0, 0, 100, 100)),
        (id: 'b', rect: Rect.fromLTWH(50, 50, 100, 100)),
      ];
      expect(
        topmostAt(const Offset(75, 75), boxes, rectOf)?.id,
        'b',
        reason: '正着找会命中被压在底下的 a',
      );
    });

    test('只落在下层时命中下层', () {
      const boxes = [
        (id: 'a', rect: Rect.fromLTWH(0, 0, 100, 100)),
        (id: 'b', rect: Rect.fromLTWH(50, 50, 100, 100)),
      ];
      expect(topmostAt(const Offset(10, 10), boxes, rectOf)?.id, 'a');
    });

    test('空列表返回 null', () {
      expect(topmostAt(const Offset(0, 0), <Box>[], rectOf), isNull);
    });

    test('左上角算命中，右下角算落空', () {
      // Rect.contains 的语义：含左上、不含右下。卡片紧挨着排时，
      // 边界重合处不会同时命中两张。
      const boxes = [(id: 'a', rect: Rect.fromLTWH(0, 0, 100, 50))];
      expect(topmostAt(const Offset(0, 0), boxes, rectOf)?.id, 'a');
      expect(topmostAt(const Offset(100, 50), boxes, rectOf), isNull);
    });
  });
}
