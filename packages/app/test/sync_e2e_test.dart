import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanban/data/database.dart';
import 'package:kanban/data/repository.dart';
import 'package:kanban/sync/sync_client.dart';
import 'package:server/src/store.dart';
import 'package:shared/shared.dart';
import 'package:server/src/sync_server.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

/// 端到端同步测试：一个真服务端 + 两个真客户端，全在一个进程里。
///
/// 比手动开两个 app 强的地方在于确定性和可重复——同步是最容易出玄学
/// bug 的地方，这类场景必须每次改动都自动验一遍，而不是靠人记得去点。
void main() {
  late Store store;
  late SyncServer syncServer;
  late HttpServer httpServer;
  late int port;

  late AppDatabase dbA;
  late AppDatabase dbB;
  late SyncClient clientA;
  late SyncClient clientB;
  late Repository repoA;
  late Repository repoB;

  setUp(() async {
    store = Store.memory();
    syncServer = SyncServer(store);
    httpServer = await shelf_io.serve(
      (request) => syncServer.handler(request),
      InternetAddress.loopbackIPv4,
      0,
    );
    port = httpServer.port;

    dbA = AppDatabase(NativeDatabase.memory());
    dbB = AppDatabase(NativeDatabase.memory());
    clientA = SyncClient(dbA);
    clientB = SyncClient(dbB);
    repoA = Repository(dbA);
    repoB = Repository(dbB);
  });

  tearDown(() async {
    await clientA.dispose();
    await clientB.dispose();
    await dbA.close();
    await dbB.close();
    await syncServer.shutdown();
    await httpServer.close(force: true);
    store.close();
  });

  /// 连上并等到握手完成。
  Future<void> connect(SyncClient client, String name) async {
    final code = syncServer.newPairCode();
    // 设备名必须在连接**之前**设好：握手时就要把名字报上去，
    // 服务端记的是 HELLO 里的那个。
    await client.setDeviceName(name);
    await client.configure(host: 'localhost', port: port, pairCode: code);
    await waitUntil(
      () => client.state.status == SyncStatus.online ||
          client.state.status == SyncStatus.syncing,
      what: '$name 上线',
    );
  }

  group('实时同步', () {
    test('一端建的看板，另一端能看到', () async {
      await connect(clientA, 'A');
      await connect(clientB, 'B');

      await repoA.createBoard(name: '从 A 建的');

      await waitUntil(
        () async => (await repoB.watchBoardSummaries().first).isNotEmpty,
        what: 'B 收到看板',
      );
      final onB = await repoB.watchBoardSummaries().first;
      expect(onB.single.board.name, '从 A 建的');
    });

    test('改标题传得过去', () async {
      await connect(clientA, 'A');
      await connect(clientB, 'B');

      final boardId = await repoA.createBoard(name: 'B1');
      final cardId = await repoA.createCard(
        boardId: boardId,
        x: 0,
        y: 0,
        title: '原标题',
      );
      await waitUntil(
        () async => (await repoB.watchCanvasCards(boardId).first).isNotEmpty,
        what: 'B 收到卡片',
      );

      await repoA.setCardField(boardId, cardId, 'title', '改过的标题');

      await waitUntil(
        () async =>
            (await repoB.watchCanvasCards(boardId).first).single.title ==
            '改过的标题',
        what: 'B 收到新标题',
      );
    });

    test('两端各自改不同字段，都保得住', () async {
      await connect(clientA, 'A');
      await connect(clientB, 'B');

      final boardId = await repoA.createBoard(name: 'B1');
      final cardId = await repoA.createCard(boardId: boardId, x: 0, y: 0);
      await waitUntil(
        () async => (await repoB.watchCanvasCards(boardId).first).isNotEmpty,
        what: 'B 收到卡片',
      );

      await repoA.setCardField(boardId, cardId, 'title', 'A 改的标题');
      await repoB.setCardField(boardId, cardId, 'body', 'B 改的正文');

      await waitUntil(() async {
        final a = (await repoA.watchCanvasCards(boardId).first).single;
        final b = (await repoB.watchCanvasCards(boardId).first).single;
        return a.title == 'A 改的标题' &&
            a.body == 'B 改的正文' &&
            b.title == 'A 改的标题' &&
            b.body == 'B 改的正文';
      }, what: '两端都拿到两个改动');
    });
  });

  group('离线与补发', () {
    test('离线期间的改动，重连后补发出去', () async {
      await connect(clientA, 'A');
      await connect(clientB, 'B');

      final boardId = await repoA.createBoard(name: 'B1');
      await waitUntil(
        () async => (await repoB.watchBoardSummaries().first).isNotEmpty,
        what: 'B 收到看板',
      );

      // B 掉线，期间照常改东西——本地优先，离线不该挡住任何操作
      await clientB.stop();
      final cardId = await repoB.createCard(
        boardId: boardId,
        x: 10,
        y: 20,
        title: '离线时建的',
      );
      expect(
        (await repoB.watchCanvasCards(boardId).first).single.id,
        cardId,
        reason: '离线时本地必须立刻生效',
      );

      // 重连
      await clientB.start();
      await waitUntil(
        () => clientB.state.status == SyncStatus.online,
        what: 'B 重新上线',
      );

      await waitUntil(
        () async => (await repoA.watchCanvasCards(boardId).first).isNotEmpty,
        what: 'A 收到 B 离线时建的卡片',
      );
      expect(
        (await repoA.watchCanvasCards(boardId).first).single.title,
        '离线时建的',
      );
    });

    test('服务端不在时也能一直用，回来后才同步', () async {
      await connect(clientA, 'A');
      final boardId = await repoA.createBoard(name: 'B1');
      await waitUntil(() => clientA.state.pending == 0, what: 'A 推完');

      // 服务端下线
      await syncServer.shutdown();
      await httpServer.close(force: true);

      // 照常干活
      await repoA.createCard(boardId: boardId, x: 0, y: 0, title: '服务端不在时建的');
      expect((await repoA.watchCanvasCards(boardId).first).length, 1);
      expect(
        (await dbA.pendingOps()).isNotEmpty,
        isTrue,
        reason: '这些改动应当攒在待发队列里',
      );
    });

    test('落后很多的设备，带着自己的改动重连，一块看板都不能少', () async {
      // 这是真实踩到的 bug：台式机离线很久，笔记本上建了 7 块板；台式机
      // 自己也离线建了板。重连后它只收到最新的 2 块，中间 5 块永久消失。
      //
      // 根因是客户端收到 ACK 时，把「服务端给我推上去的 op 分配的号」
      // 当成了「我已经收到了这个号之前的全部改动」。一台落后的设备刚连上
      // 就推送，服务端分配的号远超它实际收到的位置，中间那段从此被跳过。
      await connect(clientA, 'A');
      await connect(clientB, 'B');

      // B 先下线。
      await clientB.stop();

      // A 在 B 离线期间建一批板，攒出足够多的「B 没收到」的改动。
      final madeWhileAway = <String>[];
      for (var i = 0; i < 5; i++) {
        madeWhileAway.add(await repoA.createBoard(name: 'A 建的 $i'));
      }
      await waitUntil(() => clientA.state.pending == 0, what: 'A 推完');

      // B 离线期间也自己建了板——重连时它会把这些推上去，
      // 服务端分配的号会落在 A 那批的后面。这正是触发条件。
      final mine = await repoB.createBoard(name: 'B 自己的');
      expect((await dbB.pendingOps()).isNotEmpty, isTrue);

      await clientB.start();
      await waitUntil(
        () => clientB.state.status == SyncStatus.online,
        what: 'B 重新上线',
      );
      await waitUntil(() => clientB.state.pending == 0, what: 'B 推完自己的');

      Future<Set<String>> boardsOf(Repository repo) async => {
            for (final s in await repo.watchBoardSummaries().first) s.board.id,
          };

      await waitUntil(
        () async => (await boardsOf(repoB)).length >= 6,
        what: 'B 收齐 A 的 5 块 + 自己的 1 块',
      );

      final onB = await boardsOf(repoB);
      for (final id in madeWhileAway) {
        expect(onB, contains(id), reason: '离线期间 A 建的板一块都不能少');
      }
      expect(onB, contains(mine));
    });

    test('补齐中途出错，不能把进度跳到后面去', () async {
      // 真实事故的还原。
      //
      // 补齐循环中途抛异常时，原来的代码会：连接继续开着、状态永远停在
      // 「连接中」、不重连也不报错；而之后任何一条广播都会独立把 lastSeq
      // 设成那条新 op 的号，**一步跨过补齐没应用完的那几千条**——它们从此
      // 再也要不回来。用户那台设备就是这样少了 5 块看板。
      await connect(clientA, 'A');
      await connect(clientB, 'B');
      await clientB.stop();

      final madeWhileAway = <String>[];
      for (var i = 0; i < 4; i++) {
        madeWhileAway.add(await repoA.createBoard(name: 'A 建的 $i'));
      }
      await waitUntil(() => store.maxSeq >= 4, what: 'A 的改动到服务端');

      // 往补齐批次中间塞一条客户端应用不了的 op：标题字段给个数字，
      // 物化时按字符串取用会抛类型错误。
      // 现实里对应的是版本错位、日志损坏这类情况——不管什么原因，
      // 补齐半路失败都不该把后面的数据连带丢掉。
      store.append([
        Op(
          opId: 'poison',
          boardId: madeWhileAway.first,
          entity: Entity.card,
          entityId: 'poison-card',
          field: CardF.title,
          value: 12345, // 这里应该是字符串
          deviceId: 'A',
          wallTs: DateTime.now().millisecondsSinceEpoch,
        ),
      ]);
      // 毒丸之后再建一块，确保它排在毒丸后面。
      final afterPoison = await repoA.createBoard(name: '毒丸之后');
      await waitUntil(() => store.maxSeq >= 6, what: '毒丸之后的改动到服务端');

      await clientB.start();

      // 给它足够时间去尝试、失败、重连。
      await Future<void>.delayed(const Duration(seconds: 2));

      // A 再推一条，走广播这条路到 B。
      final seqBefore = store.maxSeq;
      await repoA.createBoard(name: '广播过来的');
      await waitUntil(() => store.maxSeq > seqBefore, what: 'A 再推完');
      await Future<void>.delayed(const Duration(seconds: 1));

      // **核心断言**：进度绝不能超过实际收到的最大号。
      // 超过了就意味着中间那段被永久跳过，再也补不回来。
      final lastSeq = await dbB.getIntSetting(SyncKeys.lastSeq);
      final have = {
        for (final r in await dbB.select(dbB.ops).get())
          if (r.seq != null) r.seq!,
      };
      final maxHave = have.isEmpty ? 0 : have.reduce((a, b) => a > b ? a : b);
      expect(
        lastSeq,
        lessThanOrEqualTo(maxHave),
        reason: '进度记到了 $lastSeq，实际只收到 $maxHave——'
            '中间 ${maxHave + 1}~$lastSeq 会被永久跳过',
      );
      // 而且要真的恢复：一条坏 op 不该挡住它后面的所有数据。
      final onB = {
        for (final x in await repoB.watchBoardSummaries().first) x.board.id,
      };
      for (final id in madeWhileAway) {
        expect(onB, contains(id), reason: '毒丸之前建的板不能少');
      }
      expect(onB, contains(afterPoison), reason: '毒丸之后建的板更不能少');
    });

    test('重新完整同步：把漏掉的数据补回来，且不产生重复', () async {
      await connect(clientA, 'A');
      await connect(clientB, 'B');

      final boardId = await repoA.createBoard(name: '共有的板');
      await repoA.createCard(boardId: boardId, x: 0, y: 0, title: '一张卡');
      await waitUntil(
        () async => (await repoB.watchCanvasCards(boardId).first).isNotEmpty,
        what: 'B 收到',
      );

      // 人为把 B 的进度推到最前面，模拟那台少了看板的设备：
      // 之后 A 再建东西，B 永远收不到。
      await dbB.setSetting(SyncKeys.lastSeq, '999999');
      final missed = await repoA.createBoard(name: 'B 会漏掉的板');
      await waitUntil(() => store.maxSeq > 0, what: 'A 推完');
      await clientB.stop();
      await clientB.start();
      await waitUntil(
        () => clientB.state.status == SyncStatus.online,
        what: 'B 重连',
      );

      final before = {
        for (final x in await repoB.watchBoardSummaries().first) x.board.id,
      };
      expect(before, isNot(contains(missed)), reason: '先确认确实漏了');

      // 按下「重新完整同步」。
      await clientB.resync();
      await waitUntil(
        () async => (await repoB.watchBoardSummaries().first)
            .any((x) => x.board.id == missed),
        what: 'B 把漏掉的板补回来',
      );

      // 补回来了，而且没有重复——重复的 op 按 opId 去重。
      final after = await repoB.watchBoardSummaries().first;
      expect(after.map((x) => x.board.id), contains(missed));
      expect(
        after.map((x) => x.board.id).toSet().length,
        after.length,
        reason: '不能出现重复的看板',
      );
      expect(
        (await repoB.watchCanvasCards(boardId).first).length,
        1,
        reason: '卡片也不能被复制一份',
      );
    });

    test('ACK 丢了之后，重连仍然能把自己的改动推出去', () async {
      // 真实事故的第二半：台式机能收到别人的改动，自己的两块看板却几个月
      // 都传不出去。原因是 `_flushing` 只在收到 ACK 时才清——一次 ACK 没
      // 回来，这个客户端就再也不推送任何东西，而界面上显示一切正常。
      await connect(clientA, 'A');
      await connect(clientB, 'B');

      // 先确认正常情况下是通的。
      final first = await repoA.createBoard(name: '正常的板');
      await waitUntil(
        () async => (await repoB.watchBoardSummaries().first)
            .any((x) => x.board.id == first),
        what: 'B 收到第一块',
      );

      // 摆出「推送出去了、ACK 永远不来」的状态。
      clientA.debugSimulateLostAck();

      final stuck = await repoA.createBoard(name: 'ACK 丢了之后建的');
      // 这时候推不出去是预期的——队列里有东西，但发不动。
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect((await dbA.pendingOps()).isNotEmpty, isTrue);

      // 断线重连。**重连必须把这个状态清掉**，否则永远卡死。
      await clientA.stop();
      await clientA.start();
      // 卡住时待发队列清不空，状态会一直停在「同步中」，所以这里两种都认，
      // 好让失败落在下面那条真正说明问题的断言上。
      await waitUntil(
        () =>
            clientA.state.status == SyncStatus.online ||
            clientA.state.status == SyncStatus.syncing,
        what: 'A 重新连上',
      );

      await waitUntil(
        () async => (await repoB.watchBoardSummaries().first)
            .any((x) => x.board.id == stuck),
        what: 'B 收到那块卡住的板',
      );
      expect((await dbA.pendingOps()), isEmpty, reason: '待发队列该清空了');
    });
  });

  group('并发冲突的收敛', () {
    test('两端同时改同一个字段，最终收敛到同一个值', () async {
      await connect(clientA, 'A');
      await connect(clientB, 'B');

      final boardId = await repoA.createBoard(name: 'B1');
      final cardId = await repoA.createCard(boardId: boardId, x: 0, y: 0);
      await waitUntil(
        () async => (await repoB.watchCanvasCards(boardId).first).isNotEmpty,
        what: 'B 收到卡片',
      );

      // 几乎同时改同一个字段
      await Future.wait([
        repoA.setCardField(boardId, cardId, 'title', 'A 的版本'),
        repoB.setCardField(boardId, cardId, 'title', 'B 的版本'),
      ]);

      await waitUntil(() async {
        final a = (await repoA.watchCanvasCards(boardId).first).single.title;
        final b = (await repoB.watchCanvasCards(boardId).first).single.title;
        return a == b && a.isNotEmpty;
      }, what: '两端收敛');

      final finalA = (await repoA.watchCanvasCards(boardId).first).single.title;
      final finalB = (await repoB.watchCanvasCards(boardId).first).single.title;
      expect(finalA, finalB, reason: '收敛结果必须一致——谁赢无所谓，不一致才是灾难');
      expect(['A 的版本', 'B 的版本'], contains(finalA));
    });

    test('两端同时给同一张卡加不同标签，一个都不丢', () async {
      await connect(clientA, 'A');
      await connect(clientB, 'B');

      final boardId = await repoA.createBoard(name: 'B1');
      final cardId = await repoA.createCard(boardId: boardId, x: 0, y: 0);
      final tagX = await repoA.createTag(boardId: boardId, name: 'X');
      final tagY = await repoA.createTag(boardId: boardId, name: 'Y');

      await waitUntil(
        () async => (await repoB.watchTags(boardId).first).length == 2,
        what: 'B 收到两个标签',
      );

      // 这正是「集合字段拆成独立记录」要防的场景：整集合 LWW 会丢一个。
      await Future.wait([
        repoA.setCardTag(boardId, cardId, tagX, on: true),
        repoB.setCardTag(boardId, cardId, tagY, on: true),
      ]);

      await waitUntil(() async {
        final a = await repoA.watchCardTags(boardId).first;
        final b = await repoB.watchCardTags(boardId).first;
        return a.length == 2 && b.length == 2;
      }, what: '两端都有两个标签');

      final tagsOnA =
          (await repoA.watchCardTags(boardId).first).map((r) => r.tagId).toSet();
      expect(tagsOnA, {tagX, tagY});
    });

    test('一端删卡片、另一端同时改内容，删除不会被撤销', () async {
      await connect(clientA, 'A');
      await connect(clientB, 'B');

      final boardId = await repoA.createBoard(name: 'B1');
      final cardId = await repoA.createCard(boardId: boardId, x: 0, y: 0);
      await waitUntil(
        () async => (await repoB.watchCanvasCards(boardId).first).isNotEmpty,
        what: 'B 收到卡片',
      );

      await repoA.deleteCard(boardId, cardId);
      await repoB.setCardField(boardId, cardId, 'title', '还在改');

      await waitUntil(() async {
        final a = await repoA.watchCanvasCards(boardId).first;
        final b = await repoB.watchCanvasCards(boardId).first;
        return a.isEmpty && b.isEmpty;
      }, what: '两端的卡片都消失');
    });
  });

  group('启动时序', () {
    test('start 和 configure 并发时不会互相踩掉配置', () async {
      // 这是实机演示时才发现的真 bug：应用启动会调 start()，而自动配对
      // 几乎同时调 configure()。start() 里的 _loadSettings 读到的是
      // configure 写入之前的旧值，回头把服务器地址覆盖成了 null，
      // 两边都以为"没配服务器"，连接根本没发起。
      final code = syncServer.newPairCode();
      await clientA.setDeviceName('A');

      // 故意不 await：模拟两者交错
      unawaited(clientA.start());
      await clientA.configure(host: 'localhost', port: port, pairCode: code);

      await waitUntil(
        () => clientA.state.status == SyncStatus.online ||
            clientA.state.status == SyncStatus.syncing,
        what: '并发启动后仍然连上',
      );
    });

    test('重复调用 start 只初始化一次', () async {
      await Future.wait([clientA.start(), clientA.start(), clientA.start()]);
      expect(clientA.state.status, SyncStatus.disabled, reason: '没配服务器时就该是未连接');

      final code = syncServer.newPairCode();
      await clientA.configure(host: 'localhost', port: port, pairCode: code);
      await waitUntil(
        () => clientA.state.status != SyncStatus.disabled,
        what: '配置后能连上',
      );
    });

    test('旧连接被拒的错误，不会盖掉新连接的成功', () async {
      // 实机演示时踩到的：数据库里留着上次的服务器地址但没有有效令牌，
      // 应用启动时用它连了一次（注定被拒），用户几乎同时用新配对码连了
      // 第二次。第二次成功了，但第一次被拒的错误**后到**，
      // 把「已同步」盖回了「令牌无效」。
      await dbA.setSetting(SyncKeys.host, 'localhost');
      await dbA.setSetting(SyncKeys.port, '$port');

      final code = syncServer.newPairCode();
      await clientA.setDeviceName('A');
      unawaited(clientA.start()); // 用旧设置，会被拒
      await clientA.configure(host: 'localhost', port: port, pairCode: code);

      await waitUntil(
        () => clientA.state.status == SyncStatus.online ||
            clientA.state.status == SyncStatus.syncing,
        what: '用新配对码连上',
      );

      // 再等一会儿，确认那条被拒的错误没有后到把状态搅掉
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(clientA.state.error, isNull, reason: '旧连接的错误不该出现');
      expect(clientA.state.status, isNot(SyncStatus.offline));
    });

    test('鉴权被拒之后，用正确的配对码仍然能救回来', () async {
      // 实机演示时踩到的：鉴权失败时把 _started 置成 false，本意是
      // 「别再无脑重试」，但它同时把用户主动发起的 configure() 也堵死了——
      // 带正确配对码的那次连接根本没发出去。停止自动重连 ≠ 拒绝重新配置。
      await clientA.setDeviceName('A');
      await clientA.configure(host: 'localhost', port: port, pairCode: '错误的码');
      await waitUntil(
        () => clientA.state.error != null,
        what: '被服务端拒绝',
      );

      final code = syncServer.newPairCode();
      await clientA.configure(host: 'localhost', port: port, pairCode: code);
      await waitUntil(
        () => clientA.state.status == SyncStatus.online ||
            clientA.state.status == SyncStatus.syncing,
        what: '用正确的配对码连上',
      );
    });

    test('stop 之后还能再 start', () async {
      await connect(clientA, 'A');
      await clientA.stop();
      expect(clientA.state.status, SyncStatus.disabled);

      await clientA.start();
      await waitUntil(
        () => clientA.state.status == SyncStatus.online,
        what: '重新启动后连上',
      );
    });
  });

  group('编辑态提示', () {
    test('一端开始编辑，另一端能看到是谁', () async {
      await connect(clientA, '我的 Mac');
      await connect(clientB, '台式机');

      clientA.reportEditing('card-1', active: true);

      await waitUntil(
        () => clientB.state.editingByOthers['card-1'] == '我的 Mac',
        what: 'B 看到 A 在编辑',
      );

      clientA.reportEditing('card-1', active: false);
      await waitUntil(
        () => !clientB.state.editingByOthers.containsKey('card-1'),
        what: '编辑态解除',
      );
    });
  });
}

/// 轮询直到条件成立。同步是异步的，没法断言"立刻"，只能断言"最终"。
Future<void> waitUntil(
  FutureOr<bool> Function() condition, {
  required String what,
  Duration timeout = const Duration(seconds: 8),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  fail('等待超时：$what');
}
