/// 专门复现「分组视图不显示卡片」的演示数据。
///
/// 建两块板：一块一个标签都没有，一块只有一个标签。
/// 用 `--dart-define=BOARD=0/1` 配合 dev_preview 分别打开看。
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanban/data/database.dart';
import 'package:kanban/data/repository.dart';

String get _dbPath {
  final home = Platform.environment['HOME'];
  return '$home/Library/Containers/com.tangcj.kanban/Data/Documents/kanban.sqlite';
}

void main() {
  test('灌入标签情形的演示数据', () async {
    final file = File(_dbPath);
    if (!file.existsSync()) fail('数据库不存在，先把应用跑一次');

    final db = AppDatabase(NativeDatabase(file));
    final repo = Repository(db);

    // 清掉已有看板，免得干扰
    for (final s in await repo.watchBoardSummaries().first) {
      await repo.deleteBoard(s.board.id);
    }

    // 板 0：一个标签都没有
    final b0 = await repo.createBoard(name: '没有标签的板');
    for (final t in ['买菜', '修水管', '写周报']) {
      await repo.createCard(boardId: b0, x: 40, y: 40, title: t);
    }

    // 板 1：只有一个标签，其中一张卡片打了这个标签
    final b1 = await repo.createBoard(name: '只有一个标签的板');
    final tag = await repo.createTag(boardId: b1, name: '待办', colorKey: 'blue');
    final tagged = await repo.createCard(
      boardId: b1,
      x: 40,
      y: 40,
      title: '打了标签的卡片',
    );
    await repo.setCardTag(b1, tagged, tag, on: true);
    await repo.createCard(boardId: b1, x: 340, y: 40, title: '没打标签的卡片');

    final summaries = await repo.watchBoardSummaries().first;
    for (final s in summaries) {
      // ignore: avoid_print
      print('${s.board.name}：${s.cardCount} 张卡片');
    }
    await db.close();
  });
}
