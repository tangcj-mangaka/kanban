import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanban/data/database.dart';
import 'package:kanban/data/repository.dart';
import 'package:kanban/data/trello/trello_export.dart';
import 'package:kanban/data/trello/trello_import.dart';

/// 这里的样例是**照着一份真实导出文件的形状**捏的，不是凭空想的：
/// 每个古怪之处（没有截止日期却 dueComplete、空清单、空列表、
/// 评论埋在 actions 里）都在真文件里见过。
///
/// 用捏的而不是直接拿真文件，是因为真文件是用户的项目内容，不该进仓库。
String fixture({
  List<Map<String, dynamic>>? cards,
  List<Map<String, dynamic>>? lists,
  List<Map<String, dynamic>>? labels,
  List<Map<String, dynamic>>? actions,
  List<Map<String, dynamic>>? checklists,
}) => jsonEncode({
  'name': '测试板',
  'lists': lists ??
      [
        {'id': 'L1', 'name': 'Core', 'closed': false, 'pos': 100},
        {'id': 'L2', 'name': 'Graphics', 'closed': false, 'pos': 200},
        {'id': 'L3', 'name': '空列表', 'closed': false, 'pos': 300},
      ],
  'labels': labels ??
      [
        {'id': 'G', 'name': '通过', 'color': 'green'},
        {'id': 'Y', 'name': '普通待办', 'color': 'yellow'},
        {'id': 'P', 'name': '撤销', 'color': 'purple'},
        {'id': 'S', 'name': '测试', 'color': 'sky'},
      ],
  'cards': cards ?? const [],
  'actions': actions ?? const [],
  'checklists': checklists ?? const [],
});

Map<String, dynamic> card(
  String id, {
  String name = '卡片',
  String desc = '',
  String list = 'L1',
  List<String> labels = const [],
  bool closed = false,
  String? due,
  String? start,
  bool dueComplete = false,
  double pos = 100,
  List<Map<String, dynamic>> attachments = const [],
}) => {
  'id': id,
  'name': name,
  'desc': desc,
  'idList': list,
  'idLabels': labels,
  'closed': closed,
  'due': due,
  'start': start,
  'dueComplete': dueComplete,
  'pos': pos,
  'attachments': attachments,
};

void main() {
  group('解析', () {
    test('空列表不算在内', () {
      final b = parseTrelloExport(fixture(cards: [card('c1', list: 'L1')]));
      expect(b.lists, hasLength(3));
      expect(b.usedLists.map((l) => l.name), ['Core']);
    });

    test('列表按 Trello 里的顺序，不按出现顺序', () {
      final b = parseTrelloExport(fixture(
        lists: [
          {'id': 'L1', 'name': '后', 'closed': false, 'pos': 900},
          {'id': 'L2', 'name': '前', 'closed': false, 'pos': 100},
        ],
        cards: [card('a', list: 'L1'), card('b', list: 'L2')],
      ));
      expect(b.usedLists.map((l) => l.name), ['前', '后']);
    });

    test('没有截止日期时 dueComplete 一律归零', () {
      // 真实导出里 418 张卡有 99 张是这个样子——改来改去留下的残渣。
      // 不归零的话会凭空多出上百张「已完成」。
      final b = parseTrelloExport(fixture(cards: [
        card('a', dueComplete: true),
        card('b', due: '2025-02-27T16:00:00.000Z', dueComplete: true),
      ]));
      expect(b.cards.firstWhere((c) => c.id == 'a').dueComplete, isFalse);
      expect(b.cards.firstWhere((c) => c.id == 'b').dueComplete, isTrue);
    });

    test('日期按 UTC 解析', () {
      final b = parseTrelloExport(fixture(cards: [
        card('a', due: '2025-02-27T16:00:00.000Z'),
      ]));
      expect(
        b.cards.single.due,
        DateTime.utc(2025, 2, 27, 16).millisecondsSinceEpoch,
      );
    });

    test('评论从 actions 里挖出来，按时间排好', () {
      final b = parseTrelloExport(fixture(
        cards: [card('a')],
        actions: [
          {
            'type': 'commentCard',
            'date': '2025-05-17T10:00:00.000Z',
            'memberCreator': {'fullName': 'heeb'},
            'data': {
              'text': '后说的',
              'card': {'id': 'a'},
            },
          },
          {
            'type': 'commentCard',
            'date': '2021-03-24T10:00:00.000Z',
            'memberCreator': {'fullName': 'heeb'},
            'data': {
              'text': '先说的',
              'card': {'id': 'a'},
            },
          },
          // 别的操作类型不该被当成评论。
          {
            'type': 'updateCard',
            'date': '2025-01-01T00:00:00.000Z',
            'data': {
              'card': {'id': 'a'},
            },
          },
        ],
      ));
      expect(b.cards.single.comments.map((c) => c.text), ['先说的', '后说的']);
      expect(b.cards.single.comments.first.author, 'heeb');
    });

    test('空清单丢掉，有内容的转成 Markdown 勾选行', () {
      // 真文件里 42 个清单只有 1 个有内容。照搬空壳会在几十张卡片的
      // 正文里加一行孤零零的标题。
      final b = parseTrelloExport(fixture(
        cards: [card('a'), card('b')],
        checklists: [
          {'id': 'k1', 'idCard': 'a', 'name': '空清单', 'checkItems': []},
          {
            'id': 'k2',
            'idCard': 'b',
            'name': '清单',
            'checkItems': [
              {'name': '做完的', 'state': 'complete', 'pos': 100},
              {'name': '没做的', 'state': 'incomplete', 'pos': 200},
            ],
          },
        ],
      ));
      expect(b.cards.firstWhere((c) => c.id == 'a').checklistLines, isEmpty);
      expect(b.cards.firstWhere((c) => c.id == 'b').checklistLines, [
        '**清单**',
        '- [x] 做完的',
        '- [ ] 没做的',
      ]);
    });

    test('色名带深浅后缀也认得出来', () {
      expect(trelloColorToSwatch('green'), 'green');
      expect(trelloColorToSwatch('green_dark'), 'green');
      expect(trelloColorToSwatch('yellow_light'), 'yellow');
      // sky 是偏青的浅蓝，色板里 teal 最接近。
      expect(trelloColorToSwatch('sky'), 'teal');
      // 认不出来给灰色，不报错——配色用户随手能改，不值得让导入失败。
      expect(trelloColorToSwatch('wasabi'), 'gray');
      expect(trelloColorToSwatch(''), 'gray');
    });

    test('不是 Trello 文件时报人话，不是抛一堆堆栈', () {
      expect(() => parseTrelloExport('不是 json'),
          throwsA(isA<TrelloParseException>()));
      expect(() => parseTrelloExport('[1,2,3]'),
          throwsA(isA<TrelloParseException>()));
      expect(() => parseTrelloExport('{"name":"x"}'),
          throwsA(isA<TrelloParseException>()));
    });
  });

  group('导入', () {
    late AppDatabase db;
    late Repository repo;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      repo = Repository(db);
    });
    tearDown(() => db.close());

    Future<List<CardRow>> cardsOf(String boardId) =>
        (db.select(db.cards)..where((c) => c.boardId.equals(boardId))).get();

    Future<List<TagRow>> tagsOf(String boardId) =>
        (db.select(db.tags)..where((t) => t.boardId.equals(boardId))).get();

    test('列表变成标签，空列表不建', () async {
      final b = parseTrelloExport(fixture(cards: [
        card('a', list: 'L1'),
        card('b', list: 'L2'),
      ]));
      final r = await importTrelloBoard(repo, b);

      final tags = await tagsOf(r.boardId);
      expect(tags.map((t) => t.name), containsAll(['Core', 'Graphics']));
      expect(tags.map((t) => t.name), isNot(contains('空列表')));
    });

    test('每张卡片都挂上它所在列表的标签', () async {
      final b = parseTrelloExport(fixture(cards: [card('a', list: 'L2')]));
      final r = await importTrelloBoard(repo, b);

      final tags = await tagsOf(r.boardId);
      final graphics = tags.firstWhere((t) => t.name == 'Graphics');
      final rel = await (db.select(db.cardTags)
            ..where((x) => x.tagId.equals(graphics.id) & x.deleted.equals(false)))
          .get();
      expect(rel, hasLength(1));
    });

    test('指认为「完成」的标签变成打勾，不建成标签', () async {
      final b = parseTrelloExport(fixture(cards: [
        card('a', labels: ['G']),
        card('b', labels: ['Y']),
      ]));
      final r = await importTrelloBoard(
        repo,
        b,
        options: const TrelloImportOptions(
          doneLabelId: 'G',
          labelsAsColor: false,
        ),
      );

      expect(r.done, 1);
      final cards = await cardsOf(r.boardId);
      expect(cards.where((c) => c.done), hasLength(1));
      expect((await tagsOf(r.boardId)).map((t) => t.name),
          isNot(contains('通过')));
    });

    test('指认为「废弃」的标签直接收进干草仓库', () async {
      final b = parseTrelloExport(fixture(cards: [card('a', labels: ['P'])]));
      final r = await importTrelloBoard(repo, b,
          options: const TrelloImportOptions(archiveLabelId: 'P'));

      expect(r.archived, 1);
      expect((await cardsOf(r.boardId)).single.archived, isTrue);
    });

    test('Trello 里归档的卡片也进干草仓库', () async {
      final b = parseTrelloExport(fixture(cards: [card('a', closed: true)]));
      final r = await importTrelloBoard(repo, b);
      expect((await cardsOf(r.boardId)).single.archived, isTrue);
    });

    test('标签变颜色：不建状态标签，卡片上色', () async {
      final b = parseTrelloExport(fixture(cards: [
        card('a', labels: ['Y']),
        card('b', labels: ['S']),
      ]));
      final r = await importTrelloBoard(repo, b,
          options: const TrelloImportOptions(labelsAsColor: true));

      final tags = await tagsOf(r.boardId);
      expect(tags.map((t) => t.name), isNot(contains('普通待办')));
      final cards = await cardsOf(r.boardId);
      expect(cards.map((c) => c.color).toSet(), {'yellow', 'teal'});
    });

    test('标签变标签：建标签，卡片不上色', () async {
      final b = parseTrelloExport(fixture(cards: [card('a', labels: ['Y'])]));
      final r = await importTrelloBoard(repo, b,
          options: const TrelloImportOptions(labelsAsColor: false));

      expect((await tagsOf(r.boardId)).map((t) => t.name),
          contains('普通待办'));
      expect((await cardsOf(r.boardId)).single.color, isNull);
    });

    test('截止时间和开始时间搬过来', () async {
      final b = parseTrelloExport(fixture(cards: [
        card('a',
            due: '2025-02-27T16:00:00.000Z',
            start: '2025-02-01T00:00:00.000Z'),
      ]));
      final r = await importTrelloBoard(repo, b);

      final c = (await cardsOf(r.boardId)).single;
      expect(c.due, DateTime.utc(2025, 2, 27, 16).millisecondsSinceEpoch);
      expect(c.start, DateTime.utc(2025, 2, 1).millisecondsSinceEpoch);
      expect(r.dated, 1);
    });

    test('评论保留原始时间，不是全挤成「刚刚」', () async {
      final b = parseTrelloExport(fixture(
        cards: [card('a')],
        actions: [
          {
            'type': 'commentCard',
            'date': '2021-03-24T10:00:00.000Z',
            'memberCreator': {'fullName': 'heeb'},
            'data': {
              'text': '四年前说的',
              'card': {'id': 'a'},
            },
          },
        ],
      ));
      final r = await importTrelloBoard(repo, b);

      final cards = await cardsOf(r.boardId);
      final comments = await repo.watchComments(cards.single.id).first;
      expect(comments, hasLength(1));
      expect(comments.single.body, '四年前说的');
      expect(
        comments.single.createdAt,
        DateTime.utc(2021, 3, 24, 10).millisecondsSinceEpoch,
      );
    });

    test('描述、清单、附件名单都落到正文里', () async {
      final b = parseTrelloExport(fixture(
        cards: [
          card('a',
              desc: '原来的描述',
              attachments: [
                {'name': '图片.png', 'isUpload': true},
              ]),
        ],
        checklists: [
          {
            'id': 'k',
            'idCard': 'a',
            'name': '清单',
            'checkItems': [
              {'name': '一项', 'state': 'complete', 'pos': 1},
            ],
          },
        ],
      ));
      final r = await importTrelloBoard(repo, b);

      final body = (await cardsOf(r.boardId)).single.body;
      expect(body, contains('原来的描述'));
      expect(body, contains('- [x] 一项'));
      // 附件文件不在导出里，至少把名字留成线索，别让人以为图丢了。
      expect(body, contains('图片.png'));
      expect(r.cardsWithAttachments, 1);
    });

    test('卡片按列表排成纵列，同列不重叠', () async {
      final b = parseTrelloExport(fixture(cards: [
        card('a', list: 'L1', pos: 100),
        card('b', list: 'L1', pos: 200),
        card('c', list: 'L2', pos: 100),
      ]));
      final r = await importTrelloBoard(repo, b);
      final cards = await cardsOf(r.boardId);

      final col1 = cards.where((c) => c.x == cards.first.x).toList();
      expect(col1, hasLength(2));
      expect(col1[0].y, isNot(col1[1].y));
      expect(cards.map((c) => c.x).toSet(), hasLength(2));
    });

    test('账目和实际写进去的对得上', () async {
      final b = parseTrelloExport(fixture(
        cards: [
          card('a', list: 'L1', labels: ['G']),
          card('b', list: 'L1', labels: ['Y']),
          card('c', list: 'L2', closed: true),
        ],
        actions: [
          {
            'type': 'commentCard',
            'date': '2024-01-01T00:00:00.000Z',
            'memberCreator': {'fullName': 'x'},
            'data': {
              'text': '一条',
              'card': {'id': 'a'},
            },
          },
        ],
      ));
      final r = await importTrelloBoard(repo, b,
          options: const TrelloImportOptions(doneLabelId: 'G'));

      expect(r.cards, 3);
      expect(r.done, 1);
      expect(r.archived, 1);
      expect(r.comments, 1);
      expect((await cardsOf(r.boardId)), hasLength(3));
    });

    test('进度回调每张卡片报一次', () async {
      final b = parseTrelloExport(fixture(cards: [
        card('a'),
        card('b'),
        card('c'),
      ]));
      final seen = <int>[];
      await importTrelloBoard(repo, b,
          onProgress: (done, total) {
            expect(total, 3);
            seen.add(done);
          });
      expect(seen, [1, 2, 3]);
    });

    test('导入不碰已有的看板', () async {
      final mine = await repo.createBoard(name: '我自己的板');
      await repo.createCard(boardId: mine, x: 0, y: 0, title: '我的卡');

      final b = parseTrelloExport(fixture(cards: [card('a')]));
      await importTrelloBoard(repo, b);

      expect(await cardsOf(mine), hasLength(1));
    });
  });
}
