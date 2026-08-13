import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:server/src/file_store.dart';
import 'package:server/src/store.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

var _n = 0;

Op attachmentOp(String entityId, String field, Object? value) => Op(
  opId: 'op-${_n++}',
  boardId: 'b1',
  entity: Entity.attachment,
  entityId: entityId,
  field: field,
  value: value,
  deviceId: 'dev',
  wallTs: 0,
);

void main() {
  late Directory dir;
  late FileStore files;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('kanban-files-test');
    files = FileStore(dir.path);
    _n = 0;
  });
  tearDown(() => dir.deleteSync(recursive: true));

  group('按内容哈希存储', () {
    test('返回的就是内容的 SHA-256', () async {
      final bytes = [1, 2, 3, 4, 5];
      final hash = await files.put(bytes);
      expect(hash, sha256.convert(bytes).toString());
    });

    test('同样的内容只占一份磁盘', () async {
      final a = await files.put([1, 2, 3]);
      final b = await files.put([1, 2, 3]);

      expect(a, b);
      expect(files.fileCount, 1, reason: '同一张图在多张卡片里用不该存两份');
    });

    test('不同内容存成不同文件', () async {
      await files.put([1, 2, 3]);
      await files.put([4, 5, 6]);
      expect(files.fileCount, 2);
    });

    test('分两级目录，避免单目录塞几万个文件', () async {
      final hash = await files.put([1, 2, 3]);
      final path = files.fileFor(hash).path;
      expect(p.basename(p.dirname(path)), hash.substring(0, 2));
    });

    test('读回来的内容和存进去的一致', () async {
      final bytes = List.generate(1000, (i) => i % 256);
      final hash = await files.put(bytes);
      expect(await files.read(hash), bytes);
    });

    test('超过上限直接拒绝', () async {
      expect(
        () => files.put(List.filled(FileStore.maxFileBytes + 1, 0)),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('不存在的哈希读出 null 而不是抛异常', () async {
      expect(await files.read('a' * 64), isNull);
      expect(files.has('a' * 64), isFalse);
    });
  });

  group('哈希格式校验', () {
    test('只接受 64 位十六进制', () {
      expect(FileStore.isValidHash('a' * 64), isTrue);
      expect(FileStore.isValidHash('A' * 64), isFalse, reason: '大写不接受，避免同内容两条路径');
      expect(FileStore.isValidHash('a' * 63), isFalse);
      expect(FileStore.isValidHash('z' * 64), isFalse);
    });

    test('挡住路径穿越', () {
      // 哈希是从请求路径里来的，不校验的话就能读到文件目录之外。
      expect(FileStore.isValidHash('../../etc/passwd'), isFalse);
      expect(files.has('../../etc/passwd'), isFalse);
    });
  });

  group('临时文件', () {
    test('清理写到一半留下的临时文件', () async {
      await files.put([1, 2, 3]);
      File(p.join(dir.path, 'files', 'ab', 'something.tmp'))
        ..createSync(recursive: true)
        ..writeAsStringSync('半截');

      expect(await files.cleanTemp(), 1);
      expect(files.fileCount, 1, reason: '正常文件不该被误删');
    });

    test('临时文件不算进哈希列表', () async {
      File(p.join(dir.path, 'files', 'ab', 'x.tmp'))
        ..createSync(recursive: true)
        ..writeAsStringSync('半截');
      expect(files.allHashes(), isEmpty);
    });
  });

  group('Range 解析', () {
    // 这段曾经把行尾锚点 $ 写成了转义的 \$（字面量美元符号），任何真实的
    // Range 头都匹配不上——断点续传**静默失效**，下载照常能用，只是永远
    // 从头开始。没有测试根本发现不了。
    test('普通区间', () {
      expect(parseRange('bytes=0-99', 1000), (0, 99));
      expect(parseRange('bytes=100-199', 1000), (100, 199));
    });

    test('只给起点表示到末尾', () {
      expect(parseRange('bytes=500-', 1000), (500, 999));
    });

    test('只给终点表示最后 N 字节', () {
      expect(parseRange('bytes=-200', 1000), (800, 999));
    });

    test('要的比总长还多时夹到末尾', () {
      expect(parseRange('bytes=900-2000', 1000), (900, 999));
      expect(parseRange('bytes=-5000', 1000), (0, 999));
    });

    test('两端空白容忍', () {
      expect(parseRange('  bytes=0-9  ', 100), (0, 9));
    });

    test('畸形的头退回整份发，而不是让下载失败', () {
      expect(parseRange(null, 100), isNull);
      expect(parseRange('', 100), isNull);
      expect(parseRange('bytes=', 100), isNull);
      expect(parseRange('bytes=-', 100), isNull);
      expect(parseRange('items=0-9', 100), isNull);
      expect(parseRange('bytes=abc-def', 100), isNull);
      expect(parseRange('bytes=0-9, 20-29', 100), isNull, reason: '多区间暂不支持');
    });

    test('越界的区间也退回整份发', () {
      expect(parseRange('bytes=1000-1099', 1000), isNull, reason: '起点超出长度');
      expect(parseRange('bytes=99-50', 1000), isNull, reason: '终点小于起点');
      expect(parseRange('bytes=-0', 1000), isNull);
    });

    test('空文件不做部分传输', () {
      expect(parseRange('bytes=0-0', 0), isNull);
    });

    test('单字节区间', () {
      expect(parseRange('bytes=0-0', 1), (0, 0));
    });
  });

  group('引用关系与延迟回收', () {
    late Store store;

    setUp(() => store = Store.memory());
    tearDown(() => store.close());

    test('从 op log 算出还在用的哈希', () {
      store.append([
        attachmentOp('a1', AttachmentF.hash, 'hash-1'),
        attachmentOp('a1', AttachmentF.thumbHash, 'thumb-1'),
        attachmentOp('a2', AttachmentF.hash, 'hash-2'),
      ]);

      expect(store.referencedHashes(), {'hash-1', 'thumb-1', 'hash-2'});
    });

    test('被标删的附件不再算引用', () {
      store.append([
        attachmentOp('a1', AttachmentF.hash, 'hash-1'),
        attachmentOp('a2', AttachmentF.hash, 'hash-2'),
        attachmentOp('a1', AttachmentF.deleted, true),
      ]);

      expect(store.referencedHashes(), {'hash-2'});
    });

    test('删了又恢复的算引用', () {
      store.append([
        attachmentOp('a1', AttachmentF.hash, 'hash-1'),
        attachmentOp('a1', AttachmentF.deleted, true),
        attachmentOp('a1', AttachmentF.deleted, false),
      ]);

      expect(store.referencedHashes(), {'hash-1'});
    });

    test('取的是每个字段最新那条 op', () {
      store.append([
        attachmentOp('a1', AttachmentF.hash, '旧哈希'),
        attachmentOp('a1', AttachmentF.hash, '新哈希'),
      ]);

      expect(store.referencedHashes(), {'新哈希'});
    });

    test('没人引用的文件不立刻删，先记成孤儿', () {
      // 卡片删了三十天内还能后悔，那时文件还在。
      final due = store.sweepOrphans({'x', 'y'}, {'x'});

      expect(due, isEmpty, reason: '刚变成孤儿，还不到删的时候');
      expect(store.orphanCount, 1);
    });

    test('超过期限的孤儿才该删', () {
      store.sweepOrphans({'x'}, {});
      final due = store.sweepOrphans({'x'}, {}, after: Duration.zero);

      expect(due, ['x']);
    });

    test('孤儿又被引用上就撤销标记', () {
      store.sweepOrphans({'x'}, {});
      expect(store.orphanCount, 1);

      // 比如卡片被从干草仓库捞回来了
      store.sweepOrphans({'x'}, {'x'});

      expect(store.orphanCount, 0);
      expect(store.sweepOrphans({'x'}, {'x'}, after: Duration.zero), isEmpty);
    });

    test('重复扫描不会把孤儿时间刷新', () async {
      store.sweepOrphans({'x'}, {});
      await Future<void>.delayed(const Duration(milliseconds: 5));
      store.sweepOrphans({'x'}, {});

      // 时间没被刷新的话，零延迟扫描立刻就到期
      expect(store.sweepOrphans({'x'}, {}, after: Duration.zero), ['x']);
    });
  });

  group('按令牌鉴权', () {
    late Store store;

    setUp(() => store = Store.memory());
    tearDown(() => store.close());

    test('找得到已配对的设备', () {
      final device = store.pair('dev-1', 'A');
      expect(store.deviceByToken(device.token)?.id, 'dev-1');
    });

    test('伪造的令牌找不到', () {
      store.pair('dev-1', 'A');
      expect(store.deviceByToken('伪造的'), isNull);
      expect(store.deviceByToken(''), isNull);
    });
  });
}
