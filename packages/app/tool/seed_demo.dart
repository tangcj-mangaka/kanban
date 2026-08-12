/// 往真实的应用数据库里灌一批演示数据，用来看界面效果。
///
/// 不在 `test/` 目录下，所以 `flutter test` 和 CI 都不会碰它。
/// 手动运行：
///
/// ```
/// flutter test tool/seed_demo.dart
/// ```
///
/// 走的是 Repository 的正常方法，产生的 op 和用户手点出来的一模一样。
library;

import 'dart:io';
import 'dart:math';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanban/data/database.dart';
import 'package:kanban/data/repository.dart';
import 'package:shared/shared.dart';

/// macOS 上应用是沙盒的，库在容器里。
String get _dbPath {
  final home = Platform.environment['HOME'];
  return '$home/Library/Containers/com.tangcj.kanban/Data/Documents/kanban.sqlite';
}

void main() {
  test('灌入演示数据', () async {
    final file = File(_dbPath);
    if (!file.existsSync()) {
      fail('数据库不存在：$_dbPath\n先把应用跑一次让它把库建出来。');
    }

    final db = AppDatabase(NativeDatabase(file));
    final repo = Repository(db);
    final rand = Random(7);

    const boards = [
      ('驴看板开发', ['P1 单机版', 'P2 同步', '待定']),
      ('家里的事', ['买', '修', '约']),
      ('读书', ['在读', '想读', '读完']),
      ('随手记', <String>[]),
    ];

    const cards = [
      ('先做单机版', '画布 + 卡片增删改，先不碰同步'),
      ('字段级 LWW', '整卡覆盖会丢改动，必须拆到字段'),
      ('广播强制走 IPv4', '多网卡环境会播出一个根本不通的地址'),
      ('干草仓库', '清空全部要强确认，附件延迟 30 天回收'),
      ('附件走独立 HTTP 通道', '文件不能塞进 WebSocket 的 JSON 消息'),
      ('拖动松手才发同步', '每帧都发会把局域网刷爆'),
      ('小数序排序', '拖一张卡只改它自己的一个字段'),
      ('墓碑删除', '不然删除和编辑并发时卡片会复活'),
    ];

    for (final (name, tagNames) in boards) {
      final boardId = await repo.createBoard(name: name);

      final tagIds = <String>[];
      for (final tagName in tagNames) {
        tagIds.add(
          await repo.createTag(
            boardId: boardId,
            name: tagName,
            colorKey: kSwatchKeys[rand.nextInt(kSwatchKeys.length)],
          ),
        );
      }

      final count = 2 + rand.nextInt(6);
      for (var i = 0; i < count; i++) {
        final (title, body) = cards[rand.nextInt(cards.length)];
        final cardId = await repo.createCard(
          boardId: boardId,
          x: 40 + rand.nextDouble() * 700,
          y: 40 + rand.nextDouble() * 420,
          title: title,
          colorKey: rand.nextInt(4) == 0
              ? null
              : kSwatchKeys[rand.nextInt(kSwatchKeys.length)],
        );
        await repo.setCardField(boardId, cardId, CardF.body, body);

        if (tagIds.isNotEmpty && rand.nextInt(4) != 0) {
          await repo.setCardTag(
            boardId,
            cardId,
            tagIds[rand.nextInt(tagIds.length)],
            on: true,
          );
        }
      }
    }

    final summaries = await repo.watchBoardSummaries().first;
    // ignore: avoid_print
    print('已灌入 ${summaries.length} 个看板，'
        '共 ${summaries.fold(0, (s, b) => s + b.cardCount)} 张卡片');

    await db.close();
  });
}
