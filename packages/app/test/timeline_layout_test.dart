import 'package:flutter_test/flutter_test.dart';
import 'package:kanban/ui/timeline/timeline_layout.dart';

void main() {
  int ms(DateTime t) => t.millisecondsSinceEpoch;

  final now = DateTime(2026, 9, 21, 14, 30); // 周一

  group('日期算术', () {
    test('跨月、跨年都能进位', () {
      expect(addDays(DateTime(2026, 9, 30), 1), DateTime(2026, 10, 1));
      expect(addDays(DateTime(2026, 12, 31), 1), DateTime(2027, 1, 1));
      expect(addDays(DateTime(2026, 3, 1), -1), DateTime(2026, 2, 28));
    });

    test('闰年的 2 月 29 日', () {
      expect(addDays(DateTime(2028, 2, 28), 1), DateTime(2028, 2, 29));
      expect(daysBetween(DateTime(2028, 2, 28), DateTime(2028, 3, 1)), 2);
    });

    test('只看日期，不看钟点', () {
      // 23:59 到次日 00:01 只隔两分钟，但跨了一天。
      expect(
        daysBetween(DateTime(2026, 9, 21, 23, 59), DateTime(2026, 9, 22, 0, 1)),
        1,
      );
      expect(
        daysBetween(DateTime(2026, 9, 21, 0, 1), DateTime(2026, 9, 21, 23, 59)),
        0,
      );
    });

    test('往回数是负数', () {
      expect(daysBetween(DateTime(2026, 9, 21), DateTime(2026, 9, 18)), -3);
    });
  });

  group('时间轴范围', () {
    test('没有卡片时也横跨今天，且不短于下限', () {
      final r = timelineRange(cards: const [], now: now);
      expect(r.dayCount, 21);
      expect(r.indexOf(dateOnly(now)), greaterThanOrEqualTo(0));
      expect(r.indexOf(dateOnly(now)), lessThan(r.dayCount));
    });

    test('把最早和最晚的卡片都包进来，两头各留空白', () {
      final r = timelineRange(
        cards: [
          (start: ms(DateTime(2026, 9, 10)), due: ms(DateTime(2026, 9, 15))),
          (start: null, due: ms(DateTime(2026, 11, 20))),
        ],
        now: now,
      );
      expect(r.firstDay, DateTime(2026, 9, 8)); // 9/10 往前留 2 天
      expect(r.dayAt(r.dayCount - 1), DateTime(2026, 11, 22));
    });

    test('哪怕卡片全排在将来，也要包含今天', () {
      // 没有「今天」这个参照点，整张图读不出「还剩多久」。
      final r = timelineRange(
        cards: [(start: null, due: ms(DateTime(2027, 5, 1)))],
        now: now,
      );
      expect(r.indexOf(dateOnly(now)), greaterThanOrEqualTo(0));
    });

    test('开始晚于截止的卡片不该把范围往后撑', () {
      // 那个开始时间是填错的，按它撑开范围会拉出几个月的空白。
      // 该得到的结果和「没填开始」完全一样。
      final bogus = timelineRange(
        cards: [
          (start: ms(DateTime(2027, 1, 1)), due: ms(DateTime(2026, 9, 25))),
        ],
        now: now,
      );
      final asIfNull = timelineRange(
        cards: [(start: null, due: ms(DateTime(2026, 9, 25)))],
        now: now,
      );
      expect(bogus.firstDay, asIfNull.firstDay);
      expect(bogus.dayCount, asIfNull.dayCount);
    });

    test('格子索引和总宽度对得上', () {
      final r = timelineRange(cards: const [], now: now);
      expect(r.totalWidth, r.dayCount * kDayWidth);
      expect(r.indexOf(r.dayAt(7)), 7);
    });
  });

  group('条的位置', () {
    final range = timelineRange(
      cards: [
        (start: ms(DateTime(2026, 9, 15)), due: ms(DateTime(2026, 10, 5))),
      ],
      now: now,
    );

    test('有开始有截止，条覆盖首尾两天（含）', () {
      final bar = barFor(
        start: ms(DateTime(2026, 9, 22, 0, 0)),
        due: ms(DateTime(2026, 9, 24, 23, 59)),
        range: range,
        now: now,
      );
      expect(bar.spanDays, 3); // 22、23、24
      expect(bar.fromIndex, range.indexOf(DateTime(2026, 9, 22)));
      expect(bar.inferredStart, isFalse);
      expect(bar.left, bar.fromIndex * kDayWidth);
      expect(bar.width, 3 * kDayWidth);
    });

    test('只有截止：从今天画到截止，长度就是「还剩多少」', () {
      final bar = barFor(
        start: null,
        due: ms(DateTime(2026, 9, 24, 23, 59)),
        range: range,
        now: now,
      );
      expect(bar.fromIndex, range.indexOf(dateOnly(now)));
      expect(bar.spanDays, 4); // 21、22、23、24
      expect(bar.inferredStart, isTrue);
    });

    test('已经超时且没设开始：退化成截止日上的一格', () {
      // 从今天画到一个过去的日期会得到一根倒着长的条。
      final bar = barFor(
        start: null,
        due: ms(DateTime(2026, 9, 18, 23, 59)),
        range: range,
        now: now,
      );
      expect(bar.fromIndex, range.indexOf(DateTime(2026, 9, 18)));
      expect(bar.spanDays, 1);
      expect(bar.inferredStart, isTrue);
    });

    test('当天开始当天结束也有一格宽，不会是 0 宽看不见', () {
      final bar = barFor(
        start: ms(DateTime(2026, 9, 23, 9, 0)),
        due: ms(DateTime(2026, 9, 23, 18, 0)),
        range: range,
        now: now,
      );
      expect(bar.spanDays, 1);
      expect(bar.width, kDayWidth);
    });

    test('开始晚于截止：按「没设开始」处理，不画倒条', () {
      final bar = barFor(
        start: ms(DateTime(2026, 9, 30)),
        due: ms(DateTime(2026, 9, 24, 23, 59)),
        range: range,
        now: now,
      );
      expect(bar.inferredStart, isTrue);
      expect(bar.spanDays, greaterThanOrEqualTo(1));
      expect(bar.fromIndex, range.indexOf(dateOnly(now)));
    });
  });

  group('进来时滚到哪', () {
    test('把今天留在靠左但不贴边的位置', () {
      // 范围要往左伸得够远，才谈得上「留出过去」——有张卡片早就过期了。
      final range = timelineRange(
        cards: [
          (start: null, due: ms(DateTime(2026, 8, 1))),
          (start: null, due: ms(DateTime(2027, 5, 1))),
        ],
        now: now,
      );
      final offset = initialScrollOffset(range, now);
      final todayX = range.indexOf(dateOnly(now)) * kDayWidth;
      expect(todayX - offset, 3 * kDayWidth);
    });

    test('今天离左边不足 3 格时贴边，不会滚出负数', () {
      // 负的 offset 传给 jumpTo 会被 clamp 掉，但这里就该给 0。
      final range = timelineRange(cards: const [], now: now);
      expect(range.indexOf(dateOnly(now)), lessThan(3));
      expect(initialScrollOffset(range, now), 0);
    });
  });
}
