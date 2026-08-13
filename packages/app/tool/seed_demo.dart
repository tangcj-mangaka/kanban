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

    // 每块看板有自己的卡片池。共用一个池子的话，「读书」板上会冒出
    // 「字段级 LWW」这种卡，截图验证搜索结果时根本分不清是数据不对
    // 还是分组逻辑不对。
    const boards = [
      (
        '驴看板开发',
        ['P1 单机版', 'P2 同步', '待定'],
        [
          ('先做单机版', '画布 + 卡片增删改，先不碰同步'),
          ('字段级 LWW', '整卡覆盖会丢改动，必须拆到字段'),
          ('广播强制走 IPv4', '多网卡环境会播出一个根本不通的地址'),
          ('干草仓库', '清空全部要强确认，附件延迟 30 天回收'),
          ('附件走独立 HTTP 通道', '文件不能塞进 WebSocket 的 JSON 消息'),
          ('拖动松手才发同步', '每帧都发会把局域网刷爆'),
          ('小数序排序', '拖一张卡只改它自己的一个字段'),
          ('墓碑删除', '不然删除和编辑并发时卡片会复活'),
        ],
      ),
      (
        '家里的事',
        ['买', '修', '约'],
        [
          ('阳台灯管不亮', '先量一下是镇流器还是灯管'),
          ('买猫砂', '上次那款结团好，别换'),
          ('约师傅通下水道', '厨房那个下水慢了快一个月'),
          ('换净水器滤芯', '包装盒上写着六个月一换'),
          ('订牛奶', '这周五之前要续上'),
          ('修纱窗', '客厅那扇脱轨了'),
        ],
      ),
      (
        '读书',
        ['在读', '想读', '读完'],
        [
          ('《人月神话》', '看到第四章，关于概念完整性那段很有意思'),
          ('《置身事内》', '讲地方财政那部分想再看一遍'),
          ('《海边的卡夫卡》', '朋友推荐的，还没开始'),
          ('《设计数据密集型应用》', '第五章讲复制，正好和这次做的同步对得上'),
          ('《小于一》', '读完了，散文比诗好读'),
        ],
      ),
      (
        '随手记',
        <String>[],
        [
          ('楼下那家面馆周一休息', '别再白跑一趟了'),
          ('相机电池充电器放在书桌第二个抽屉', ''),
          ('想去趟植物园', '据说四月的郁金香值得看'),
          ('那首歌叫什么来着', '副歌是「ла-ла-ла」，听着像东欧的'),
        ],
      ),
    ];

    for (final (name, tagNames, pool) in boards) {
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

      final count = 2 + rand.nextInt(pool.length - 1);
      for (var i = 0; i < count; i++) {
        final (title, body) = pool[i % pool.length];
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
