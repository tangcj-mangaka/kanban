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
import 'package:image/image.dart' as img;
import 'package:kanban/sync/attachment_store.dart';
import 'package:path/path.dart' as p;
import 'package:shared/shared.dart';

/// macOS 上应用是沙盒的，库在容器里。
String get _dbPath {
  final home = Platform.environment['HOME'];
  return '$home/Library/Containers/com.tangcj.kanban/Data/Documents/kanban.sqlite';
}

/// 附件缓存目录，和应用里 bootstrap 用的是同一处。
Directory get _cacheDir {
  final home = Platform.environment['HOME'];
  return Directory(
    '$home/Library/Containers/com.tangcj.kanban/Data/Library/Application Support/'
    'com.tangcj.kanban/attachments',
  );
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

      // 每块板尽量多灌几张，好让「整理」有东西可换行——卡片数少于列数时
      // 谁也不会排到谁下面，等于验不到高度算得对不对。
      final count = pool.length;
      for (var i = 0; i < count; i++) {
        final (title, body) = pool[i % pool.length];
        final cardId = await repo.createCard(
          boardId: boardId,
          // 排成两列的网格，不随机撒。
          //
          // 原来是随机坐标，结果每次截图卡片都互相压着，想看清某个
          // 状态还得先找哪张没被盖住——验证界面时非常碍事。
          x: 40 + (i % 2) * 300,
          y: 40 + (i ~/ 2) * 260,
          title: title,
          colorKey: rand.nextInt(4) == 0
              ? null
              : kSwatchKeys[rand.nextInt(kSwatchKeys.length)],
        );
        // 每块板留一张长正文的卡片，用来验证折叠态截到三行。
        await repo.setCardField(
          boardId,
          cardId,
          CardF.body,
          i == 2
              ? '$body。这段是特意写长的，用来看折叠状态下正文截到第三行是什么'
                    '效果，后面这些字在画布上应该看不到，要点展开才会全部显示'
                    '出来，不然一张卡片能占掉半个屏幕。'
              : body,
        );

        if (tagIds.isNotEmpty && rand.nextInt(4) != 0) {
          await repo.setCardTag(
            boardId,
            cardId,
            tagIds[rand.nextInt(tagIds.length)],
            on: true,
          );
        }

        // 每块板上勾掉一张，好在截图里看到完成态。
        if (i == 0) await repo.toggleCardDone(boardId, cardId, true);

        // 第一张卡片编一段多设备改动历史，用来看改动记录长什么样。
        if (i == 0) await _seedHistory(db, repo, boardId, cardId);

        // 每块板的第二张卡片配一张图，用来验证封面。
        if (i == 1) {
          await _attachDemoImage(db, repo, boardId, cardId, rand);
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

/// 生成一张纯色渐变小图当演示附件。
///
/// 不从磁盘找现成图片：那样脚本就依赖某台机器上有什么文件，
/// 换台机器跑就挂了。
Future<void> _attachDemoImage(
  AppDatabase db,
  Repository repo,
  String boardId,
  String cardId,
  Random rand,
) async {
  const w = 320;
  const h = 200;
  final image = img.Image(width: w, height: h);
  final hue = rand.nextInt(360);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final t = x / w;
      final v = 0.55 + 0.35 * (y / h);
      final rgb = _hsvToRgb((hue + t * 60) % 360, 0.45, v);
      image.setPixelRgb(x, y, rgb.$1, rgb.$2, rgb.$3);
    }
  }

  final bytes = img.encodePng(image);
  final dir = Directory(p.join(Directory.systemTemp.path, 'kanban-seed'));
  await dir.create(recursive: true);
  final file = File(p.join(dir.path, 'demo-$cardId.png'));
  await file.writeAsBytes(bytes);

  final store = AttachmentStore(db, _cacheDir);
  final imported = await store.importFile(file);
  await repo.addAttachment(
    boardId: boardId,
    cardId: cardId,
    hash: imported.hash,
    filename: '示例图片.png',
    size: imported.size,
    mime: imported.mime,
    thumbHash: imported.thumbHash,
  );
}

(int, int, int) _hsvToRgb(double hDeg, double s, double v) {
  final c = v * s;
  final x = c * (1 - ((hDeg / 60) % 2 - 1).abs());
  final m = v - c;
  final (r, g, b) = switch (hDeg ~/ 60) {
    0 => (c, x, 0.0),
    1 => (x, c, 0.0),
    2 => (0.0, c, x),
    3 => (0.0, x, c),
    4 => (x, 0.0, c),
    _ => (c, 0.0, x),
  };
  return (
    ((r + m) * 255).round(),
    ((g + m) * 255).round(),
    ((b + m) * 255).round(),
  );
}

/// 给一张卡片编一段「三台设备各改过」的历史。
///
/// 直接灌 op 而不是调 Repository：要模拟别的设备的改动，就得自己指定
/// deviceId 和 seq——那正是真实同步下服务端分配的东西。
Future<void> _seedHistory(
  AppDatabase db,
  Repository repo,
  String boardId,
  String cardId,
) async {
  final now = DateTime.now().millisecondsSinceEpoch;

  await repo.setCardField(boardId, cardId, CardF.body, '笔记本上刚改的，还没同步出去');

  var seq = 9000;
  Future<void> remote(
    String device,
    String field,
    Object? value,
    int minutesAgo,
  ) => db.applyOp(
    Op(
      seq: seq++,
      opId: 'seed-$device-$field-$seq',
      boardId: boardId,
      entity: Entity.card,
      entityId: cardId,
      field: field,
      value: value,
      deviceId: device,
      wallTs: now - minutesAgo * 60 * 1000,
    ),
  );

  await remote('phone-1', CardF.body, '在手机上改的，出门路上想到的', 90);
  await remote('desktop-1', CardF.title, '台式机改过的标题', 45);
  await remote('desktop-1', CardF.body, '回家在台式机上重写的，同步过来的最新一版', 20);

  // 让设备名单有内容，好显示成人话而不是一串 ID。
  await db.setSetting(
    'sync.device_names',
    '{"phone-1":"手机","desktop-1":"台式机","local":"笔记本"}',
  );
}
