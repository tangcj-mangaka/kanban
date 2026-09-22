import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanban/data/database.dart';
import 'package:kanban/data/repository.dart';
import 'package:kanban/ui/timeline/timeline_mobile.dart';
import 'package:shared/shared.dart';

/// 手机上的时间轴是按「已过期／今天／这几天／以后」分档的列表。
/// 分档的边界（今天的最后一毫秒、第 3 天和第 4 天之间）容易差一天。
void main() {
  late AppDatabase db;
  late Repository repo;
  late String boardId;

  final now = DateTime(2026, 9, 21, 14, 30);

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = Repository(db);
    boardId = await repo.createBoard(name: 'B');
  });
  tearDown(() => db.close());

  Future<CardRow> make(DateTime due, {bool done = false}) async {
    final id = await repo.createCard(boardId: boardId, x: 0, y: 0);
    await repo.setCardDate(boardId, id, CardF.due, due);
    if (done) await repo.toggleCardDone(boardId, id, true);
    return (db.select(db.cards)..where((c) => c.id.equals(id))).getSingle();
  }

  test('按日期分档，边界落在正确的一侧', () async {
    final cards = [
      await make(DateTime(2026, 9, 20, 23, 59)), // 昨天 → 已过期
      await make(DateTime(2026, 9, 21, 0, 1)), // 今天凌晨，钟点已过
      await make(DateTime(2026, 9, 21, 23, 59)), // 今天深夜
      await make(DateTime(2026, 9, 24, 23, 59)), // 第 3 天 → 这几天
      await make(DateTime(2026, 9, 25, 0, 1)), // 第 4 天 → 以后
    ];

    final groups = groupByDueBucket(cards, now);

    expect(groups[DueBucket.overdue]!.length, 1);
    // 今天到期的留在「今天」，哪怕钟点已经过了——它仍然是今天的事。
    expect(groups[DueBucket.today]!.length, 2);
    expect(groups[DueBucket.soon]!.length, 1);
    expect(groups[DueBucket.later]!.length, 1);
  });

  test('已完成的卡片照样按日期分档，不挪窝', () async {
    // 「完成了不再报警」管的是颜色，不是位置。把它挪到别的档是撒谎——
    // 它的截止日期确实在上周。想清爽就用工具条上的三态开关滤掉。
    final cards = [await make(DateTime(2026, 9, 10), done: true)];
    final groups = groupByDueBucket(cards, now);

    expect(groups[DueBucket.overdue]!.single.done, isTrue);
  });

  test('每一档内部按截止先后排', () async {
    final cards = [
      await make(DateTime(2026, 9, 24, 12, 0)),
      await make(DateTime(2026, 9, 22, 12, 0)),
      await make(DateTime(2026, 9, 23, 12, 0)),
    ];

    final soon = groupByDueBucket(cards, now)[DueBucket.soon]!;
    expect(
      soon.map((c) => DateTime.fromMillisecondsSinceEpoch(c.due!).day),
      [22, 23, 24],
    );
  });

  test('没设截止时间的卡片一张都不进来', () async {
    final id = await repo.createCard(boardId: boardId, x: 0, y: 0);
    final row =
        await (db.select(db.cards)..where((c) => c.id.equals(id))).getSingle();

    final groups = groupByDueBucket([row], now);
    expect(groups.values.expand((l) => l), isEmpty);
  });

  test('每一档都存在，哪怕是空的', () async {
    // 界面按 DueBucket.values 遍历，缺一档会抛。
    final groups = groupByDueBucket(const [], now);
    for (final b in DueBucket.values) {
      expect(groups[b], isNotNull, reason: '$b 这一档不该缺');
    }
  });
}
