import 'package:shared/shared.dart';
import 'package:test/test.dart';

/// 把「拖动重排」完整走一遍：算邻居 → 取小数序 → 重新排序，
/// 断言最终的顺序符合直觉。
List<String> reorder(List<String> names, int from, int to) {
  final orders = {
    for (var i = 0; i < names.length; i++) names[i]: i.toDouble(),
  };
  final n = reorderNeighbors(names.map((x) => orders[x]!).toList(), from, to);
  orders[names[from]] = fractionalIndex(before: n.before, after: n.after);

  final result = [...names]..sort((a, b) => orders[a]!.compareTo(orders[b]!));
  return result;
}

void main() {
  group('小数序', () {
    test('往中间插取中点', () {
      expect(fractionalIndex(before: 1, after: 2), 1.5);
    });

    test('插在头部或尾部', () {
      expect(fractionalIndex(before: null, after: 1), 0);
      expect(fractionalIndex(before: 1, after: null), 2);
      expect(fractionalIndex(), 0);
    });

    test('反复往同一条缝里插，有限步内触发重排阈值', () {
      var lo = 0.0;
      const hi = 1.0;
      var steps = 0;
      while (!needsRebalance(lo, hi) && steps < 200) {
        lo = fractionalIndex(before: lo, after: hi);
        steps++;
      }
      expect(needsRebalance(lo, hi), isTrue);
      expect(steps, lessThan(200));
    });

    test('重排后保持先后顺序且均匀分布', () {
      expect(rebalance(4), [0.0, 1.0, 2.0, 3.0]);
    });
  });

  group('拖动重排的下标换算', () {
    // 这里最容易出 off-by-one：被拖的元素要先从列表里摘掉，
    // 剩下元素的下标就整体前移了。
    const abcd = ['A', 'B', 'C', 'D'];

    test('往右拖，落在目标之后', () {
      expect(reorder(abcd, 0, 2), ['B', 'C', 'A', 'D']);
      expect(reorder(abcd, 0, 3), ['B', 'C', 'D', 'A']);
    });

    test('往左拖，落在目标之前', () {
      expect(reorder(abcd, 3, 0), ['D', 'A', 'B', 'C']);
      expect(reorder(abcd, 2, 1), ['A', 'C', 'B', 'D']);
    });

    test('拖到相邻位置', () {
      expect(reorder(abcd, 0, 1), ['B', 'A', 'C', 'D']);
      expect(reorder(abcd, 1, 0), ['B', 'A', 'C', 'D']);
    });

    test('拖到自己原来的位置，顺序不变', () {
      expect(reorder(abcd, 1, 1), abcd);
    });

    test('两个元素互换', () {
      expect(reorder(['A', 'B'], 0, 1), ['B', 'A']);
      expect(reorder(['A', 'B'], 1, 0), ['B', 'A']);
    });

    test('单个元素怎么拖都还是它', () {
      expect(reorder(['A'], 0, 0), ['A']);
    });

    test('目标下标越界时被夹到合法范围，不抛异常', () {
      expect(reorder(abcd, 0, 99), ['B', 'C', 'D', 'A']);
      expect(reorder(abcd, 3, -5), ['D', 'A', 'B', 'C']);
    });

    test('起始下标越界时返回空邻居，不抛异常', () {
      final n = reorderNeighbors([0, 1, 2], 9, 0);
      expect(n.before, isNull);
      expect(n.after, isNull);
    });
  });

  group('关系 ID', () {
    test('由两端 ID 确定性拼出', () {
      expect(cardTagId('c1', 't1'), 'c1:t1');
      expect(cardTagId('c1', 't1'), cardTagId('c1', 't1'));
    });

    test('不同的两端给出不同的 ID', () {
      expect(cardTagId('c1', 't1'), isNot(cardTagId('c1', 't2')));
      expect(cardTagId('c1', 't1'), isNot(cardTagId('c2', 't1')));
    });
  });
}
