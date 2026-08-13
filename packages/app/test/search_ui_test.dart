import 'package:flutter_test/flutter_test.dart';
import 'package:kanban/data/database.dart';
import 'package:kanban/ui/board/board_search.dart';
import 'package:kanban/ui/format.dart';

CardRow _card({String title = '', String body = ''}) => CardRow(
  id: 'c1',
  boardId: 'b1',
  title: title,
  body: body,
  color: 'yellow',
  x: 0,
  y: 0,
  width: 240,
  z: 0,
  collapsed: false,
  done: false,
  archived: false,
  deleted: false,
  createdAt: 0,
  updatedAt: 0,
);

void main() {
  group('BoardSearch', () {
    test('没有搜索词时一切都算命中', () {
      expect(BoardSearch.none.active, isFalse);
      expect(BoardSearch.none.matches(_card(title: '随便')), isTrue);
    });

    test('标题和正文都搜，且大小写不敏感', () {
      const s = BoardSearch(query: 'todo');
      expect(s.matches(_card(title: 'TODO 清单')), isTrue);
      expect(s.matches(_card(body: '别忘了 ToDo')), isTrue);
      expect(s.matches(_card(title: '无关')), isFalse);
    });

    test('改搜索词会清掉旧的定位', () {
      // 不清的话，换了词以后画布还套着上一次命中那张卡片的光环，
      // 而那张卡现在可能根本不匹配。
      final s = const BoardSearch(query: 'a').focusOn('c1');
      expect(s.focusCardId, 'c1');
      expect(s.withQuery('b').focusCardId, isNull);
    });

    test('反复定位同一张卡片时 token 仍然递增', () {
      // 只有一张命中卡片时，用户按「下一个」，focusCardId 一直不变；
      // 画布靠 token 才知道该重新把视角挪回去。
      final a = const BoardSearch(query: 'x').focusOn('c1');
      final b = a.focusOn('c1');
      expect(b.focusToken, a.focusToken + 1);
      expect(a == b, isFalse, reason: '相等的话 didUpdateWidget 收不到变化');
    });
  });

  group('snippetAround', () {
    test('短正文原样返回，换行压成空格', () {
      expect(snippetAround('第一行\n第二行', '第二'), '第一行 第二行');
    });

    test('命中在很后面时往前截，并加省略号', () {
      final body = '${'铺垫' * 60}关键词后面还有很多字';
      final s = snippetAround(body, '关键词');
      expect(s.startsWith('…'), isTrue);
      expect(s.contains('关键词'), isTrue);
      expect(s.length, lessThan(body.length));
    });

    test('命中只在标题不在正文时，退回从头截', () {
      final body = '正文' * 100;
      final s = snippetAround(body, '标题里才有的词');
      expect(s.startsWith('正文'), isTrue);
      expect(s.startsWith('…'), isFalse);
    });

    test('截取不会越过正文末尾', () {
      final body = '${'x' * 100}尾巴';
      expect(() => snippetAround(body, '尾巴'), returnsNormally);
      expect(snippetAround(body, '尾巴').contains('尾巴'), isTrue);
    });
  });

  group('nextMatchIndex', () {
    test('还没定位过时，往后按落在第一项、往回按落在最后一项', () {
      expect(nextMatchIndex(-1, 3, 1), 0);
      expect(nextMatchIndex(-1, 3, -1), 2);
    });

    test('正常往后逐项走', () {
      expect(nextMatchIndex(0, 3, 1), 1);
      expect(nextMatchIndex(1, 3, 1), 2);
    });

    test('走到末尾再往后会绕回开头', () {
      expect(nextMatchIndex(2, 3, 1), 0);
    });

    test('在开头再往回会绕到末尾', () {
      // Dart 的 % 对负数返回非负结果，这里正是靠这一点；
      // 换成 C 那套语义会得到 -1，直接下标越界。
      expect(nextMatchIndex(0, 3, -1), 2);
    });

    test('只有一项时，怎么按都是这一项', () {
      expect(nextMatchIndex(-1, 1, 1), 0);
      expect(nextMatchIndex(0, 1, 1), 0);
      expect(nextMatchIndex(0, 1, -1), 0);
    });

    test('一项都没有时返回 -1，而不是崩', () {
      expect(nextMatchIndex(-1, 0, 1), -1);
      expect(nextMatchIndex(0, 0, -1), -1);
    });
  });
}
