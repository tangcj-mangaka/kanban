import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanban/data/database.dart';
import 'package:kanban/data/repository.dart';
import 'package:shared/shared.dart';

void main() {
  late AppDatabase db;
  late Repository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = Repository(db);
  });
  tearDown(() => db.close());

  Future<CardRow> card(String id) =>
      (db.select(db.cards)..where((c) => c.id.equals(id))).getSingle();

  group('卡片', () {
    test('新建的卡片落在指定坐标，层级排在最上面', () async {
      final boardId = await repo.createBoard(name: 'B');
      final first = await repo.createCard(boardId: boardId, x: 10, y: 20);
      final second = await repo.createCard(boardId: boardId, x: 30, y: 40);

      final a = await card(first);
      final b = await card(second);
      expect(a.x, 10);
      expect(a.y, 20);
      expect(b.z, greaterThan(a.z), reason: '后建的应该盖在先建的上面');
    });

    test('挪位置不改「最近修改」时间', () async {
      // 纯粹挪位置不该让卡片在列表里往上跳——那是内容变了才该有的待遇。
      final boardId = await repo.createBoard(name: 'B');
      final id = await repo.createCard(boardId: boardId, x: 0, y: 0);
      final before = (await card(id)).updatedAt;

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await repo.moveCard(boardId, id, 100, 200);

      final after = await card(id);
      expect(after.x, 100);
      expect(after.y, 200);
      expect(after.updatedAt, before);
    });

    test('改内容会推进「最近修改」时间', () async {
      final boardId = await repo.createBoard(name: 'B');
      final id = await repo.createCard(boardId: boardId, x: 0, y: 0);
      final before = (await card(id)).updatedAt;

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await repo.setCardField(boardId, id, 'title', '改了');

      expect((await card(id)).updatedAt, greaterThan(before));
    });

    test('提到最前只改这一张卡自己的字段', () async {
      final boardId = await repo.createBoard(name: 'B');
      final a = await repo.createCard(boardId: boardId, x: 0, y: 0);
      final b = await repo.createCard(boardId: boardId, x: 0, y: 0);

      final bZBefore = (await card(b)).z;
      await repo.bringToFront(boardId, a);

      expect((await card(a)).z, greaterThan(bZBefore));
      expect((await card(b)).z, bZBefore, reason: '其他卡片的层级不该被动过');
    });
  });

  group('整理', () {
    test('排成网格，并保持原有的相对顺序', () async {
      final boardId = await repo.createBoard(name: 'B');
      // 故意打乱着建，整理后应当按「先上后下、先左后右」重排。
      final bottom = await repo.createCard(boardId: boardId, x: 500, y: 900);
      final top = await repo.createCard(boardId: boardId, x: 300, y: 10);
      final middle = await repo.createCard(boardId: boardId, x: 80, y: 400);

      await repo.tidyCards(boardId, columns: 3);

      final t = await card(top);
      final m = await card(middle);
      final b = await card(bottom);

      expect(t.y, m.y, reason: '三张卡片应当排在同一行');
      expect(m.y, b.y);
      expect(t.x, lessThan(m.x), reason: '原来在上面的应当排在左边');
      expect(m.x, lessThan(b.x));
    });

    test('空画布整理不出错', () async {
      final boardId = await repo.createBoard(name: 'B');
      await repo.tidyCards(boardId);
    });
  });

  group('干草仓库', () {
    test('归档的卡片从画布上消失，但仍在仓库里', () async {
      final boardId = await repo.createBoard(name: 'B');
      final id = await repo.createCard(boardId: boardId, x: 0, y: 0);

      await repo.archiveCard(boardId, id);

      expect(await repo.watchCanvasCards(boardId).first, isEmpty);
      expect((await repo.watchArchivedCards(boardId).first).single.id, id);
    });

    test('捞回来时位置原样保留', () async {
      final boardId = await repo.createBoard(name: 'B');
      final id = await repo.createCard(boardId: boardId, x: 123, y: 456);

      await repo.archiveCard(boardId, id);
      await repo.archiveCard(boardId, id, archived: false);

      final c = await card(id);
      expect(c.x, 123);
      expect(c.y, 456);
    });

    test('清空全部走墓碑，画布上的卡片一张不动', () async {
      final boardId = await repo.createBoard(name: 'B');
      final onCanvas = await repo.createCard(boardId: boardId, x: 0, y: 0);
      final archivedA = await repo.createCard(boardId: boardId, x: 0, y: 0);
      final archivedB = await repo.createCard(boardId: boardId, x: 0, y: 0);
      await repo.archiveCard(boardId, archivedA);
      await repo.archiveCard(boardId, archivedB);

      final removed = await repo.emptyHaystack(boardId);

      expect(removed, 2);
      expect(await repo.watchArchivedCards(boardId).first, isEmpty);
      expect((await card(archivedA)).deleted, isTrue);
      expect(
        (await repo.watchCanvasCards(boardId).first).single.id,
        onCanvas,
        reason: '清空仓库不该碰画布上的卡片',
      );
    });
  });

  group('标签', () {
    test('删标签只解除关联，卡片一张不少', () async {
      // 标签是分类手段，不是卡片的容器。删分类不该连内容一起带走。
      final boardId = await repo.createBoard(name: 'B');
      final tagId = await repo.createTag(boardId: boardId, name: '临时');
      final cardId = await repo.createCard(boardId: boardId, x: 0, y: 0);
      await repo.setCardTag(boardId, cardId, tagId, on: true);

      await repo.deleteTag(boardId, tagId);

      expect(await repo.watchTags(boardId).first, isEmpty);
      expect((await repo.watchCanvasCards(boardId).first).single.id, cardId);
    });

    test('一张卡片可以打多个标签', () async {
      final boardId = await repo.createBoard(name: 'B');
      final a = await repo.createTag(boardId: boardId, name: 'a');
      final b = await repo.createTag(boardId: boardId, name: 'b');
      final cardId = await repo.createCard(boardId: boardId, x: 0, y: 0);

      await repo.setCardTag(boardId, cardId, a, on: true);
      await repo.setCardTag(boardId, cardId, b, on: true);

      final rels = await repo.watchCardTags(boardId).first;
      expect(rels.map((r) => r.tagId).toSet(), {a, b});
    });

    test('摘掉标签后关系不再出现在生效列表里', () async {
      final boardId = await repo.createBoard(name: 'B');
      final tagId = await repo.createTag(boardId: boardId, name: 'a');
      final cardId = await repo.createCard(boardId: boardId, x: 0, y: 0);

      await repo.setCardTag(boardId, cardId, tagId, on: true);
      await repo.setCardTag(boardId, cardId, tagId, on: false);

      expect(await repo.watchCardTags(boardId).first, isEmpty);
    });

    test('标签按顺序排列，新建的排在最后', () async {
      final boardId = await repo.createBoard(name: 'B');
      await repo.createTag(boardId: boardId, name: '一');
      await repo.createTag(boardId: boardId, name: '二');
      await repo.createTag(boardId: boardId, name: '三');

      final tags = await repo.watchTags(boardId).first;
      expect(tags.map((t) => t.name), ['一', '二', '三']);
    });
  });

  group('评论', () {
    test('按发表时间正序排列', () async {
      final boardId = await repo.createBoard(name: 'B');
      final cardId = await repo.createCard(boardId: boardId, x: 0, y: 0);

      await repo.addComment(boardId, cardId, '第一条');
      await Future<void>.delayed(const Duration(milliseconds: 3));
      await repo.addComment(boardId, cardId, '第二条');

      final comments = await repo.watchComments(cardId).first;
      expect(comments.map((c) => c.body), ['第一条', '第二条']);
    });

    test('删除走墓碑，不再出现在列表里', () async {
      final boardId = await repo.createBoard(name: 'B');
      final cardId = await repo.createCard(boardId: boardId, x: 0, y: 0);
      final id = await repo.addComment(boardId, cardId, '要删的');
      await repo.deleteComment(boardId, id);

      expect(await repo.watchComments(cardId).first, isEmpty);
    });

    test('评论数按卡片归组，删掉的不计入', () async {
      final boardId = await repo.createBoard(name: 'B');
      final a = await repo.createCard(boardId: boardId, x: 0, y: 0);
      final b = await repo.createCard(boardId: boardId, x: 0, y: 0);

      await repo.addComment(boardId, a, '一');
      await repo.addComment(boardId, a, '二');
      final toDelete = await repo.addComment(boardId, b, '三');
      await repo.deleteComment(boardId, toDelete);

      final counts = await repo.watchCommentCounts(boardId).first;
      expect(counts[a], 2);
      expect(counts[b], isNull, reason: '评论删光的卡片不该出现在计数里');
    });

    test('评论跟着卡片走，不与别的卡片串', () async {
      final boardId = await repo.createBoard(name: 'B');
      final a = await repo.createCard(boardId: boardId, x: 0, y: 0);
      final b = await repo.createCard(boardId: boardId, x: 0, y: 0);

      await repo.addComment(boardId, a, '给 A 的');

      expect((await repo.watchComments(a).first).single.body, '给 A 的');
      expect(await repo.watchComments(b).first, isEmpty);
    });
  });

  group('分组视图的列顶新建', () {
    test('放在所有卡片下方，不会盖住已有的卡', () async {
      final boardId = await repo.createBoard(name: 'B');
      await repo.createCard(boardId: boardId, x: 0, y: 100);
      await repo.createCard(boardId: boardId, x: 0, y: 500);

      final id = await repo.createCardBelowAll(boardId: boardId);

      expect((await card(id)).y, greaterThan(500));
    });

    test('可以顺带打上那一列的标签', () async {
      final boardId = await repo.createBoard(name: 'B');
      final tagId = await repo.createTag(boardId: boardId, name: '在读');

      final id = await repo.createCardBelowAll(boardId: boardId, tagId: tagId);

      final rels = await repo.watchCardTags(boardId).first;
      expect(rels.single.cardId, id);
      expect(rels.single.tagId, tagId);
    });

    test('空画布时也能建', () async {
      final boardId = await repo.createBoard(name: 'B');
      final id = await repo.createCardBelowAll(boardId: boardId);
      expect((await card(id)).y, 40);
    });
  });

  group('看板', () {
    test('删看板走墓碑，从列表里消失', () async {
      final boardId = await repo.createBoard(name: '要删的');
      await repo.deleteBoard(boardId);
      expect(await repo.watchBoardSummaries().first, isEmpty);
    });

    test('卡片数不算归档和已删的', () async {
      final boardId = await repo.createBoard(name: 'B');
      await repo.createCard(boardId: boardId, x: 0, y: 0);
      final archived = await repo.createCard(boardId: boardId, x: 0, y: 0);
      final deleted = await repo.createCard(boardId: boardId, x: 0, y: 0);
      await repo.archiveCard(boardId, archived);
      await repo.deleteCard(boardId, deleted);

      final summary = (await repo.watchBoardSummaries().first).single;
      expect(summary.cardCount, 1);
    });
  });

  group('搜索', () {
    Future<String> withText(
      String boardId, {
      String title = '',
      String body = '',
    }) async {
      final id = await repo.createCard(boardId: boardId, x: 0, y: 0);
      if (title.isNotEmpty) await repo.setCardField(boardId, id, CardF.title, title);
      if (body.isNotEmpty) await repo.setCardField(boardId, id, CardF.body, body);
      return id;
    }

    test('标题和正文都能命中，结果带上所属看板', () async {
      final b1 = await repo.createBoard(name: '工作');
      final b2 = await repo.createBoard(name: '家里');
      await withText(b1, title: '修水管');
      await withText(b2, body: '周末去买水管配件');
      await withText(b1, title: '写周报');

      final hits = await repo.searchCards('水管').first;
      expect(hits, hasLength(2));
      expect(
        hits.map((h) => h.boardName).toSet(),
        {'工作', '家里'},
        reason: '跨看板搜索要能同时搜到两块板上的卡片',
      );
    });

    test('空查询返回空，不是返回全部', () async {
      final b = await repo.createBoard(name: 'B');
      await withText(b, title: '随便什么');
      expect(await repo.searchCards('').first, isEmpty);
      expect(await repo.searchCards('   ').first, isEmpty);
    });

    test('百分号是普通字符，不是通配符', () async {
      // 这条是这次从 LIKE 换成 instr 的原因：SQLite 的 LIKE 没有默认转义符，
      // 用 LIKE 的话搜 '%' 会匹配到每一张卡片。
      final b = await repo.createBoard(name: 'B');
      await withText(b, title: '完成度 80%');
      await withText(b, title: '毫不相干');

      final hits = await repo.searchCards('%').first;
      expect(hits, hasLength(1));
      expect(hits.single.card.title, '完成度 80%');
    });

    test('下划线是普通字符，不是任意单字', () async {
      final b = await repo.createBoard(name: 'B');
      await withText(b, title: 'snake_case 命名');
      await withText(b, title: 'abc');

      final hits = await repo.searchCards('e_c').first;
      expect(hits, hasLength(1), reason: '_ 若当通配符，abc 也会被 e_c 之类的模式牵连');
      expect(hits.single.card.title, 'snake_case 命名');
    });

    test('限定看板时不串板', () async {
      final b1 = await repo.createBoard(name: '工作');
      final b2 = await repo.createBoard(name: '家里');
      await withText(b1, title: '共同关键词');
      await withText(b2, title: '共同关键词');

      expect(await repo.searchCards('共同关键词').first, hasLength(2));
      final scoped = await repo.searchCards('共同关键词', boardId: b1).first;
      expect(scoped, hasLength(1));
      expect(scoped.single.boardName, '工作');
    });

    test('删掉的卡片、删掉的看板都搜不到', () async {
      final b1 = await repo.createBoard(name: '留着');
      final b2 = await repo.createBoard(name: '要删的板');
      final gone = await withText(b1, title: '目标');
      await withText(b1, title: '目标 保留');
      await withText(b2, title: '目标');

      await repo.deleteCard(b1, gone);
      await repo.deleteBoard(b2);

      final hits = await repo.searchCards('目标').first;
      expect(hits, hasLength(1));
      expect(hits.single.card.title, '目标 保留');
    });

    test('归档的卡片仍然搜得到', () async {
      // 干草仓库是「收起来」不是「删掉」，全局搜索得能把它捞出来，
      // 否则归档等于把卡片弄丢。
      final b = await repo.createBoard(name: 'B');
      final id = await withText(b, title: '去年的方案');
      await repo.archiveCard(b, id);

      final hits = await repo.searchCards('方案').first;
      expect(hits, hasLength(1));
      expect(hits.single.card.archived, isTrue);
    });

    test('结果按最近修改排序', () async {
      final b = await repo.createBoard(name: 'B');
      await withText(b, title: '关键词 老的');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await withText(b, title: '关键词 新的');

      final hits = await repo.searchCards('关键词').first;
      expect(hits.map((h) => h.card.title).toList(), ['关键词 新的', '关键词 老的']);
    });

    test('改完卡片，已订阅的搜索结果会自己更新', () async {
      // customSelect 得声明 readsFrom，不然 drift 不知道该在哪张表变化时
      // 重新跑这条查询——这正是之前 _writeField 用 customStatement 踩过的坑。
      final b = await repo.createBoard(name: 'B');
      final stream = repo.searchCards('新加的');
      expect(await stream.first, isEmpty);

      final id = await repo.createCard(boardId: b, x: 0, y: 0);
      await repo.setCardField(b, id, CardF.title, '新加的卡片');

      await expectLater(
        stream,
        emitsThrough(predicate<List<SearchHit>>((hits) => hits.length == 1)),
      );
    });
  });
}
