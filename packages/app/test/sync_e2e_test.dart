import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanban/data/database.dart';
import 'package:kanban/data/repository.dart';
import 'package:kanban/sync/sync_client.dart';
import 'package:server/src/store.dart';
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
