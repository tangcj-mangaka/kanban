import 'package:flutter_test/flutter_test.dart';
import 'package:kanban/ui/deadline.dart';

void main() {
  int ms(DateTime t) => t.millisecondsSinceEpoch;

  group('超时判定', () {
    final now = DateTime(2026, 9, 21, 14, 30);

    DeadlineStatus statusAt(
      DateTime due, {
      bool done = false,
      bool archived = false,
    }) => deadlineStatus(
      due: ms(due),
      done: done,
      archived: archived,
      now: now,
    );

    test('没设截止时间就是 none', () {
      expect(
        deadlineStatus(due: null, done: false, archived: false, now: now),
        DeadlineStatus.none,
      );
    });

    test('到期那一毫秒就算超时', () {
      // 边界：设成 14:30:00.000，到了 14:30:00.000 就该红。
      // 「23:59 截止」的意思是 23:59 之前做完，不是「23:59 这一分钟还宽限」。
      expect(statusAt(now), DeadlineStatus.overdue);
      expect(
        statusAt(now.add(const Duration(milliseconds: 1))),
        DeadlineStatus.soon,
      );
      expect(
        statusAt(now.subtract(const Duration(milliseconds: 1))),
        DeadlineStatus.overdue,
      );
    });

    test('3 天窗口按自然日算，不按 72 小时', () {
      // now 是 9/21 14:30。9/24 23:59 是第 3 个自然日，但隔了 81 小时。
      // 按 72 小时算会漏掉它，而徽章上明明写着「还剩 3 天」。
      expect(
        statusAt(DateTime(2026, 9, 24, 23, 59)),
        DeadlineStatus.soon,
        reason: '第 3 个自然日该算临近',
      );
      expect(
        statusAt(DateTime(2026, 9, 25, 0, 1)),
        DeadlineStatus.later,
        reason: '第 4 个自然日就不算了',
      );
    });

    test('周五下班看得见下周一到期的事', () {
      // 定 3 天就是为了这个场景：周五 17:00 到周一 23:59 是 79 小时，
      // 按 72 小时的窗口框不进来，那这个阈值的理由就落空了。
      final friday = DateTime(2026, 9, 25, 17, 0);
      expect(friday.weekday, DateTime.friday);
      final monday = DateTime(2026, 9, 28, 23, 59);
      expect(monday.weekday, DateTime.monday);
      expect(monday.difference(friday).inHours, greaterThan(72));

      expect(
        deadlineStatus(
          due: ms(monday),
          done: false,
          archived: false,
          now: friday,
        ),
        DeadlineStatus.soon,
      );
    });

    test('颜色和徽章文字口径一致', () {
      // 「还剩 N 天」里的 N ≤ 3 就该是橙的，不能出现
      // 「写着还剩 3 天、颜色却是不着急」的卡片。
      for (var d = 1; d <= 6; d++) {
        final due = DateTime(2026, 9, 21 + d, 23, 59);
        final label = dueLabel(ms(due), now);
        final soon = statusAt(due) == DeadlineStatus.soon;
        expect(
          soon,
          d <= kDueSoonDays,
          reason: '第 $d 天：徽章写「$label」，颜色 ${soon ? '橙' : '不报警'}',
        );
      }
    });

    test('做完了就不再报警，哪怕早就超时', () {
      expect(
        statusAt(now.subtract(const Duration(days: 30)), done: true),
        DeadlineStatus.done,
      );
    });

    test('归档的卡片不参与催办，而且压过完成态', () {
      expect(
        statusAt(now.subtract(const Duration(days: 30)), archived: true),
        DeadlineStatus.archived,
      );
      expect(
        statusAt(now, done: true, archived: true),
        DeadlineStatus.archived,
      );
    });

    test('只有超时和临近才上警告色', () {
      expect(DeadlineStatus.overdue.isAlarming, isTrue);
      expect(DeadlineStatus.soon.isAlarming, isTrue);
      for (final s in [
        DeadlineStatus.none,
        DeadlineStatus.later,
        DeadlineStatus.done,
        DeadlineStatus.archived,
      ]) {
        expect(s.isAlarming, isFalse, reason: '$s 不该上警告色');
      }
    });
  });

  group('徽章文字', () {
    final now = DateTime(2026, 9, 21, 14, 30);

    test('按自然日说话，不按 24 小时整除', () {
      // 今晚 23:00 到明早 08:00 只隔 9 小时，但人会说「明天」。
      // 按 24 小时整除会说成「还剩 0 天」，没人看得懂。
      final lateTonight = DateTime(2026, 9, 21, 23, 0);
      final tomorrowMorning = DateTime(2026, 9, 22, 8, 0);
      expect(dueLabel(ms(lateTonight), now), '今天 23:00');
      expect(dueLabel(ms(tomorrowMorning), now), '明天 08:00');
    });

    test('超时说天数，今天到期单独说', () {
      expect(dueLabel(ms(DateTime(2026, 9, 21, 9, 0)), now), '今天到期');
      expect(dueLabel(ms(DateTime(2026, 9, 20, 9, 0)), now), '超时 1 天');
      expect(dueLabel(ms(DateTime(2026, 9, 18, 9, 0)), now), '超时 3 天');
    });

    test('一周以内说剩几天，再远就给日期', () {
      expect(dueLabel(ms(DateTime(2026, 9, 25, 23, 59)), now), '还剩 4 天');
      expect(
        dueLabel(ms(DateTime(2026, 10, 15, 23, 59)), now),
        '10月15日 23:59',
      );
    });

    test('跨年才带年份', () {
      expect(formatDueDate(ms(DateTime(2026, 9, 25, 18, 0)), now), '9月25日 18:00');
      expect(
        formatDueDate(ms(DateTime(2027, 1, 3, 18, 0)), now),
        '2027年1月3日 18:00',
      );
    });
  });

  group('时间输入解析', () {
    test('认 HH:mm 和 HH:mm:ss', () {
      expect(parseDayTime('23:59'), 23 * 3600 + 59 * 60);
      expect(parseDayTime('23:59:30'), 23 * 3600 + 59 * 60 + 30);
      expect(parseDayTime('00:00'), 0);
    });

    test('认不补零的写法和两边的空格', () {
      expect(parseDayTime('9:5'), 9 * 3600 + 5 * 60);
      expect(parseDayTime('  9:05  '), 9 * 3600 + 5 * 60);
    });

    test('认中文冒号', () {
      // 中文输入法下打出 `23：59` 是常事，为这个报错纯属添堵。
      expect(parseDayTime('23：59'), 23 * 3600 + 59 * 60);
    });

    test('坏输入一律返回 null，绝不猜', () {
      for (final bad in [
        '',
        '  ',
        '23',
        '23:',
        ':59',
        '24:00',
        '23:60',
        '23:59:60',
        '-1:30',
        '1:2:3:4',
        'ab:cd',
        '23:5x',
      ]) {
        expect(parseDayTime(bad), isNull, reason: '「$bad」不该解析成功');
      }
    });

    test('秒是 0 就不显示，非 0 才显示', () {
      expect(formatDayTime(23 * 3600 + 59 * 60), '23:59');
      expect(formatDayTime(23 * 3600 + 59 * 60 + 30), '23:59:30');
      expect(formatDayTime(0), '00:00');
      expect(formatDayTime(9 * 3600 + 5 * 60), '09:05');
    });

    test('解析和显示能来回跑一圈', () {
      for (final text in ['00:00', '09:05', '23:59', '12:34:56']) {
        expect(formatDayTime(parseDayTime(text)!), text);
      }
    });

    test('从时间戳取钟点', () {
      expect(
        dayTimeOf(ms(DateTime(2026, 9, 21, 23, 59, 30))),
        23 * 3600 + 59 * 60 + 30,
      );
    });

    test('日期和钟点合回时间戳', () {
      final at = combineDayTime(DateTime(2026, 9, 21), 23 * 3600 + 59 * 60 + 7);
      expect(at, DateTime(2026, 9, 21, 23, 59, 7));
    });

    test('默认钟点：截止 23:59、开始 00:00', () {
      expect(formatDayTime(kDefaultDueSeconds), '23:59');
      expect(formatDayTime(kDefaultStartSeconds), '00:00');
    });
  });

  group('快捷日期', () {
    test('今天和明天', () {
      final now = DateTime(2026, 9, 21, 14, 30); // 周一
      final days = quickDays(now);
      expect(days[0].label, '今天');
      expect(days[0].day, DateTime(2026, 9, 21));
      expect(days[1].day, DateTime(2026, 9, 22));
    });

    test('周一点「本周五」给的是本周的周五', () {
      final days = quickDays(DateTime(2026, 9, 21, 9, 0)); // 周一
      expect(days[2].label, '本周五');
      expect(days[2].day, DateTime(2026, 9, 25));
    });

    test('周六点「本周五」顺延到下周五，不给过去的日期', () {
      // 按字面给一个已经过去的周五，用户还得自己发现并改掉。
      final days = quickDays(DateTime(2026, 9, 26, 9, 0)); // 周六
      expect(days[2].day, DateTime(2026, 10, 2));
    });

    test('周一点「下周一」给下周，不是今天', () {
      final days = quickDays(DateTime(2026, 9, 21, 9, 0)); // 周一
      expect(days[3].label, '下周一');
      expect(days[3].day, DateTime(2026, 9, 28));
    });

    test('跨月也能正确进位', () {
      final days = quickDays(DateTime(2026, 9, 30, 9, 0));
      expect(days[1].day, DateTime(2026, 10, 1));
    });
  });
}
