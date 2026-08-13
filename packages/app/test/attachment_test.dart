import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:kanban/data/database.dart';
import 'package:kanban/data/repository.dart';
import 'package:kanban/sync/attachment_store.dart';
import 'package:kanban/sync/attachment_syncer.dart';
import 'package:server/src/file_store.dart';
import 'package:server/src/file_endpoints.dart';
import 'package:server/src/store.dart' as srv;
import 'package:shelf/shelf_io.dart' as shelf_io;

/// 造一张真图，用来验证缩略图逻辑。
Uint8List makeImage(int width, int height) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(120, 80, 200));
  return img.encodePng(image);
}

void main() {
  late Directory dir;
  late AppDatabase db;
  late AttachmentStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('kanban-attach-test');
    db = AppDatabase(NativeDatabase.memory());
    store = AttachmentStore(db, dir);
  });
  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  File writeTemp(String name, List<int> bytes) {
    final f = File('${dir.path}/src-$name')..writeAsBytesSync(bytes);
    return f;
  }

  group('导入文件', () {
    test('算出内容哈希并记进缓存', () async {
      final src = writeTemp('a.bin', [1, 2, 3, 4]);
      final imported = await store.importFile(src);

      expect(imported.size, 4);
      expect(imported.hash.length, 64);
      expect(store.has(imported.hash), isTrue);
    });

    test('同样的内容只占一份磁盘', () async {
      final a = await store.importFile(writeTemp('a.bin', [9, 9, 9]));
      final b = await store.importFile(writeTemp('b.bin', [9, 9, 9]));

      expect(a.hash, b.hash);
      expect(await store.cachedBytes, 3, reason: '不该按文件个数重复计算');
    });

    test('按文件名认出类型', () async {
      final png = await store.importFile(writeTemp('x.png', makeImage(10, 10)));
      expect(png.mime, 'image/png');
      expect(png.isImage, isTrue);
    });

    test('认不出类型的退回二进制流，不报错', () async {
      final f = await store.importFile(writeTemp('x.什么鬼', [0, 1, 2]));
      expect(f.mime, 'application/octet-stream');
      expect(f.isImage, isFalse);
    });

    test('新导入的文件进待传队列', () async {
      final imported = await store.importFile(writeTemp('a.bin', [1, 2]));
      expect(await store.pendingUploads(), contains(imported.hash));
    });
  });

  group('缩略图', () {
    test('大图会生成缩略图，且比原图小得多', () async {
      final src = writeTemp('big.png', makeImage(1600, 1200));
      final imported = await store.importFile(src);

      expect(imported.thumbHash, isNotNull);
      final thumb = await store.read(imported.thumbHash!);
      expect(thumb, isNotNull);
      expect(thumb!.length, lessThan(imported.size));

      final decoded = img.decodeImage(thumb)!;
      expect(decoded.width, AttachmentStore.thumbLongSide);
    });

    test('竖图按高度缩', () async {
      final imported = await store.importFile(
        writeTemp('tall.png', makeImage(600, 1600)),
      );
      final decoded = img.decodeImage((await store.read(imported.thumbHash!))!)!;
      expect(decoded.height, AttachmentStore.thumbLongSide);
    });

    test('本来就小的图不再生成缩略图', () async {
      // 存一份和原图差不多大的缩略图是纯浪费。
      final imported = await store.importFile(
        writeTemp('small.png', makeImage(100, 100)),
      );
      expect(imported.thumbHash, isNull);
    });

    test('非图片不生成缩略图', () async {
      final imported = await store.importFile(writeTemp('a.pdf', [1, 2, 3]));
      expect(imported.thumbHash, isNull);
    });

    test('损坏的图片文件不影响附件本身可用', () async {
      // 扩展名说是图片，内容却不是。
      final imported = await store.importFile(
        writeTemp('broken.png', [1, 2, 3, 4, 5]),
      );
      expect(imported.thumbHash, isNull, reason: '没有缩略图而已');
      expect(store.has(imported.hash), isTrue, reason: '文件本身照常存下来');
    });
  });

  group('缓存淘汰', () {
    test('超过上限时按最近最少使用删', () async {
      final a = await store.putBytes(List.filled(100, 1), uploaded: true);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final b = await store.putBytes(List.filled(100, 2), uploaded: true);

      final removed = await store.evict(maxBytes: 150);

      expect(removed, 1);
      expect(store.has(a), isFalse, reason: 'a 更久没用过');
      expect(store.has(b), isTrue);
    });

    test('绝不删还没传上去的文件', () async {
      // 那是本机唯一的副本，删了就真没了。
      final pending = await store.putBytes(List.filled(1000, 1));

      final removed = await store.evict(maxBytes: 10);

      expect(removed, 0);
      expect(store.has(pending), isTrue);
    });

    test('没超过上限时什么都不删', () async {
      await store.putBytes([1, 2, 3], uploaded: true);
      expect(await store.evict(maxBytes: 1000), 0);
    });

    test('用过一次会推后被淘汰的顺序', () async {
      final a = await store.putBytes(List.filled(100, 1), uploaded: true);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final b = await store.putBytes(List.filled(100, 2), uploaded: true);

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await store.read(a); // 用了一下 a

      await store.evict(maxBytes: 150);

      expect(store.has(a), isTrue, reason: '刚用过的该留着');
      expect(store.has(b), isFalse);
    });
  });

  group('临时文件', () {
    test('清理写到一半留下的', () async {
      await store.putBytes([1, 2, 3]);
      File('${dir.path}/ab/half.tmp')
        ..createSync(recursive: true)
        ..writeAsStringSync('半截');

      expect(await store.cleanTemp(), 1);
    });
  });

  group('和真服务端之间的上传下载', () {
    late Directory serverDir;
    late srv.Store serverStore;
    late FileStore serverFiles;
    late HttpServer http;
    late AttachmentSyncer syncer;
    late String token;

    setUp(() async {
      serverDir = Directory.systemTemp.createTempSync('kanban-attach-server');
      serverStore = srv.Store.memory();
      serverFiles = FileStore(serverDir.path);
      token = serverStore.pair('dev-1', 'A').token;

      http = await shelf_io.serve(
        (request) => handleFileRequest(request, serverStore, serverFiles),
        InternetAddress.loopbackIPv4,
        0,
      );

      syncer = AttachmentSyncer(
        store: store,
        endpoint: () => ServerEndpoint(
          host: 'localhost',
          port: http.port,
          token: token,
        ),
      );
    });

    tearDown(() async {
      syncer.dispose();
      await http.close(force: true);
      serverStore.close();
      serverDir.deleteSync(recursive: true);
    });

    test('待传队列里的文件被推上去', () async {
      final imported = await store.importFile(writeTemp('a.bin', [7, 7, 7]));
      expect(await store.pendingUploads(), isNotEmpty);

      await syncer.flush();

      expect(serverFiles.has(imported.hash), isTrue);
      expect(await store.pendingUploads(), isEmpty);
    });

    test('服务端已有的内容秒传，不重复上传', () async {
      // 别的设备传过同一张图的情形。
      final bytes = [5, 5, 5, 5];
      await serverFiles.put(bytes);

      await store.importFile(writeTemp('a.bin', bytes));
      await syncer.flush();

      expect(await store.pendingUploads(), isEmpty);
      expect(serverFiles.fileCount, 1, reason: '内容一样，磁盘上仍是一份');
    });

    test('本地没有的文件会从服务端下下来', () async {
      final hash = await serverFiles.put([3, 1, 4, 1, 5]);
      expect(store.has(hash), isFalse);

      final bytes = await syncer.fetch(hash);

      expect(bytes, [3, 1, 4, 1, 5]);
      expect(store.has(hash), isTrue, reason: '下下来的要进缓存');
    });

    test('下下来的文件不该再排进待传队列', () async {
      final hash = await serverFiles.put([1, 2, 3]);
      await syncer.fetch(hash);

      expect(await store.pendingUploads(), isEmpty, reason: '它本来就是从服务端来的');
    });

    test('本地有就直接用本地的，不走网络', () async {
      final imported = await store.importFile(writeTemp('a.bin', [8, 8]));
      // 服务端上根本没有这个文件
      expect(serverFiles.has(imported.hash), isFalse);

      expect(await syncer.fetch(imported.hash), [8, 8]);
    });

    test('服务端没有的文件返回 null，而不是抛异常', () async {
      // 调用方据此显示占位符。看不到别人的附件不该让界面报错。
      expect(await syncer.fetch('a' * 64), isNull);
    });

    test('令牌不对时安静失败，文件留在待传队列里', () async {
      final bad = AttachmentSyncer(
        store: store,
        endpoint: () => ServerEndpoint(
          host: 'localhost',
          port: http.port,
          token: '伪造的',
        ),
      );
      final imported = await store.importFile(writeTemp('a.bin', [1]));

      await bad.flush();

      expect(await store.pendingUploads(), contains(imported.hash));
      expect(serverFiles.has(imported.hash), isFalse);
      bad.dispose();
    });

    test('离线时不报错，文件留着等下次', () async {
      final offline = AttachmentSyncer(
        store: store,
        endpoint: () => null,
      );
      final imported = await store.importFile(writeTemp('a.bin', [2]));

      await offline.flush();

      expect(await store.pendingUploads(), contains(imported.hash));
      expect(await offline.fetch(imported.hash), [2], reason: '本地有的照常能读');
      offline.dispose();
    });

    test('同一个哈希被并发请求时只下载一次', () async {
      final hash = await serverFiles.put(List.generate(500, (i) => i % 256));

      // 详情页和画布缩略图会同时要同一张图。
      final results = await Future.wait([
        syncer.fetch(hash),
        syncer.fetch(hash),
        syncer.fetch(hash),
      ]);

      expect(results.every((r) => r != null && r.length == 500), isTrue);
    });
  });

  group('附件挂到卡片上', () {
    test('写进 op log，能查出来', () async {
      final repo = Repository(db);
      final boardId = await repo.createBoard(name: 'B');
      final cardId = await repo.createCard(boardId: boardId, x: 0, y: 0);
      final imported = await store.importFile(writeTemp('a.png', makeImage(20, 20)));

      await repo.addAttachment(
        boardId: boardId,
        cardId: cardId,
        hash: imported.hash,
        filename: imported.filename,
        size: imported.size,
        mime: imported.mime,
        thumbHash: imported.thumbHash,
      );

      final list = await repo.watchAttachments(cardId).first;
      expect(list.single.hash, imported.hash);
      expect(list.single.mime, 'image/png');
    });

    test('删除走墓碑，磁盘上的文件不动', () async {
      final repo = Repository(db);
      final boardId = await repo.createBoard(name: 'B');
      final cardId = await repo.createCard(boardId: boardId, x: 0, y: 0);
      final imported = await store.importFile(writeTemp('a.bin', [1, 2]));
      final id = await repo.addAttachment(
        boardId: boardId,
        cardId: cardId,
        hash: imported.hash,
        filename: 'a.bin',
        size: 2,
        mime: 'application/octet-stream',
      );

      await repo.deleteAttachment(boardId, id);

      expect(await repo.watchAttachments(cardId).first, isEmpty);
      expect(
        store.has(imported.hash),
        isTrue,
        reason: '同一份内容可能还挂在别的卡片上，而且服务端回收是延迟 30 天的',
      );
    });

    test('附件数按卡片归组', () async {
      final repo = Repository(db);
      final boardId = await repo.createBoard(name: 'B');
      final a = await repo.createCard(boardId: boardId, x: 0, y: 0);
      final b = await repo.createCard(boardId: boardId, x: 0, y: 0);

      for (final bytes in [
        [1],
        [2],
      ]) {
        final f = await store.importFile(writeTemp('${bytes.first}.bin', bytes));
        await repo.addAttachment(
          boardId: boardId,
          cardId: a,
          hash: f.hash,
          filename: 'x',
          size: 1,
          mime: 'application/octet-stream',
        );
      }

      final counts = await repo.watchAttachmentCounts(boardId).first;
      expect(counts[a], 2);
      expect(counts[b], isNull);
    });
  });
}
