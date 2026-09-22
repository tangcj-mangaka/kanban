/// 给现有的演示卡片排上期，用来看时间轴和超时配色的效果。
///
/// 不在 `test/` 目录下，所以 `flutter test` 和 CI 都不会碰它。
/// 手动运行（要先跑过一次 seed_demo.dart）：
///
/// ```
/// flutter test tool/seed_dates.dart
/// ```
///
/// 排期是相对「今天」算的，所以每次跑出来的分布一样：一定有超时的、
/// 有今天到期的、有临近的、有还早的，四种颜色一次全看得见。
library;

import 'dart:io';

import 'package:drift/drift.dart' show OrderingTerm;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanban/data/database.dart';
import 'package:kanban/data/repository.dart';
import 'package:shared/shared.dart';

String get _dbPath {
  final home = Platform.environment['HOME'];
  return '$home/Library/Containers/com.tangcj.kanban/Data/Documents/kanban.sqlite';
}

void main() {
  test('给演示卡片排期', () async {
    final file = File(_dbPath);
    if (!file.existsSync()) {
      fail('数据库不存在：$_dbPath\n先跑一次应用，再跑 seed_demo.dart。');
    }

    final db = AppDatabase(NativeDatabase(file));
    final repo = Repository(db);

    final boards = await db.select(db.boards).get();
    final live = [for (final b in boards) if (!b.deleted) b];
    expect(live, isNotEmpty, reason: '一块看板都没有，先跑 seed_demo.dart');

    final now = DateTime.now();
    DateTime day(int offset, {int hour = 23, int minute = 59}) =>
        DateTime(now.year, now.month, now.day + offset, hour, minute);

    // (截止偏移天数, 开始偏移天数或 null)。
    // 覆盖四种状态：超时、今天到期、3 天内临近、还早。
    // 其中一半故意不填开始时间，好看清「条从今天画起」的浅色样子。
    const plan = <(int, int?)>[
      (-6, -12), // 超时很久，有完整区间
      (-2, null), // 刚超时，只有截止
      (0, -3), // 今天到期
      (1, null), // 明天，临近
      (3, 0), // 第 3 天，临近的边界
      (6, 2), // 还早
      (12, null), // 还早，只有截止
      (20, 14), // 下个月
    ];

    var total = 0;
    for (final board in live) {
      final cards =
          await (db.select(db.cards)
                ..where((c) => c.boardId.equals(board.id))
                ..where((c) => c.deleted.equals(false))
                ..where((c) => c.archived.equals(false))
                ..orderBy([(c) => OrderingTerm.asc(c.createdAt)]))
              .get();

      for (var i = 0; i < cards.length && i < plan.length; i++) {
        final (dueOffset, startOffset) = plan[i];
        await repo.setCardDate(
          board.id,
          cards[i].id,
          CardF.due,
          day(dueOffset),
        );
        if (startOffset != null) {
          await repo.setCardDate(
            board.id,
            cards[i].id,
            CardF.start,
            day(startOffset, hour: 0, minute: 0),
          );
        }
        total++;
      }
    }

    await db.close();
    // ignore: avoid_print
    print('排好了 $total 张卡片');
  });
}
