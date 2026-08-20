import 'package:flutter_test/flutter_test.dart';
import 'package:kanban/ui/board/done_filter.dart';

void main() {
  group('DoneFilter', () {
    test('全部：打勾没打勾都放行', () {
      expect(DoneFilter.all.accepts(cardIsDone: true), isTrue);
      expect(DoneFilter.all.accepts(cardIsDone: false), isTrue);
    });

    test('未完成：只放行没打勾的', () {
      expect(DoneFilter.todo.accepts(cardIsDone: false), isTrue);
      expect(DoneFilter.todo.accepts(cardIsDone: true), isFalse);
    });

    test('已完成：只放行打了勾的', () {
      expect(DoneFilter.done.accepts(cardIsDone: true), isTrue);
      expect(DoneFilter.done.accepts(cardIsDone: false), isFalse);
    });

    test('点一下按 全部 → 未完成 → 已完成 → 全部 轮换', () {
      expect(DoneFilter.all.next, DoneFilter.todo);
      expect(DoneFilter.todo.next, DoneFilter.done);
      expect(DoneFilter.done.next, DoneFilter.all);
    });

    test('存盘读回', () {
      for (final f in DoneFilter.values) {
        expect(DoneFilter.parse(f.name), f);
      }
    });

    test('存的是垃圾值时退回「全部」，不崩', () {
      expect(DoneFilter.parse(null), DoneFilter.all);
      expect(DoneFilter.parse(''), DoneFilter.all);
      expect(DoneFilter.parse('天知道'), DoneFilter.all);
    });
  });
}
