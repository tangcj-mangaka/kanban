import 'dart:convert';
import 'dart:io';

import 'package:server/src/file_endpoints.dart';
import 'package:server/src/file_store.dart';
import 'package:server/src/store.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late Store store;
  late FileStore files;
  late String token;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('kanban-endpoints-test');
    store = Store.memory();
    files = FileStore(dir.path);
    token = store.pair('dev-1', '我的 Mac').token;
  });
  tearDown(() {
    store.close();
    dir.deleteSync(recursive: true);
  });

  Future<Response> call(
    String method,
    String path, {
    List<int>? body,
    String? auth,
    Map<String, String> headers = const {},
  }) {
    return handleFileRequest(
      Request(
        method,
        Uri.parse('http://localhost/$path'),
        headers: {
          if (auth != null) 'authorization': 'Bearer $auth',
          ...headers,
        },
        body: body,
      ),
      store,
      files,
    );
  }

  group('鉴权', () {
    test('没有令牌一律拒绝', () async {
      // 没有这道门，同一局域网里任何人都能把文件读走。
      final r = await call('POST', 'files', body: [1, 2, 3]);
      expect(r.statusCode, 401);
    });

    test('伪造的令牌也拒绝', () async {
      final r = await call('POST', 'files', body: [1, 2, 3], auth: '伪造的');
      expect(r.statusCode, 401);
    });

    test('被踢掉的设备立刻失效', () async {
      store.unpair('dev-1');
      final r = await call('POST', 'files', body: [1, 2, 3], auth: token);
      expect(r.statusCode, 401);
    });
  });

  group('上传', () {
    test('返回内容哈希', () async {
      final r = await call('POST', 'files', body: [1, 2, 3], auth: token);
      expect(r.statusCode, 200);

      final data = jsonDecode(await r.readAsString()) as Map<String, Object?>;
      expect(data['hash'], isA<String>());
      expect(data['size'], 3);
      expect(files.has(data['hash']! as String), isTrue);
    });

    test('同样的内容传两次是同一个哈希，只占一份磁盘', () async {
      final a = jsonDecode(
        await (await call('POST', 'files', body: [9, 9], auth: token))
            .readAsString(),
      );
      final b = jsonDecode(
        await (await call('POST', 'files', body: [9, 9], auth: token))
            .readAsString(),
      );

      expect(a['hash'], b['hash']);
      expect(files.fileCount, 1);
    });

    test('空文件拒绝', () async {
      final r = await call('POST', 'files', body: <int>[], auth: token);
      expect(r.statusCode, 400);
    });

    test('超过上限返回 413', () async {
      final r = await call(
        'POST',
        'files',
        body: List.filled(FileStore.maxFileBytes + 1, 0),
        auth: token,
      );
      expect(r.statusCode, 413);
    });
  });

  group('下载', () {
    late String hash;

    setUp(() async {
      hash = await files.put(List.generate(1000, (i) => i % 256));
    });

    test('取回完整内容', () async {
      final r = await call('GET', 'files/$hash', auth: token);
      expect(r.statusCode, 200);
      expect((await r.read().expand((c) => c).toList()).length, 1000);
    });

    test('内容寻址可以长期缓存', () async {
      // 同一个哈希的内容永远不会变。
      final r = await call('GET', 'files/$hash', auth: token);
      expect(r.headers['cache-control'], contains('immutable'));
    });

    test('不存在的哈希返回 404', () async {
      final r = await call('GET', 'files/${'a' * 64}', auth: token);
      expect(r.statusCode, 404);
    });

    test('哈希格式不对返回 400', () async {
      expect((await call('GET', 'files/短', auth: token)).statusCode, 400);
    });

    test('挡住路径穿越', () async {
      final r = await call('GET', 'files/..%2F..%2Fetc%2Fpasswd', auth: token);
      expect(r.statusCode, anyOf(400, 404));
    });
  });

  group('断点续传', () {
    late String hash;

    setUp(() async {
      hash = await files.put(List.generate(1000, (i) => i % 256));
    });

    test('部分请求返回 206 和正确的片段', () async {
      final r = await call(
        'GET',
        'files/$hash',
        auth: token,
        headers: {'range': 'bytes=100-199'},
      );

      expect(r.statusCode, 206);
      expect(r.headers['content-range'], 'bytes 100-199/1000');
      final bytes = await r.read().expand((c) => c).toList();
      expect(bytes.length, 100);
      expect(bytes.first, 100 % 256);
    });

    test('声明支持断点续传', () async {
      final r = await call('GET', 'files/$hash', auth: token);
      expect(r.headers['accept-ranges'], 'bytes');
    });

    test('畸形的 Range 退回整份发，而不是报错', () async {
      final r = await call(
        'GET',
        'files/$hash',
        auth: token,
        headers: {'range': '乱七八糟'},
      );
      expect(r.statusCode, 200);
    });
  });

  group('探测（秒传用）', () {
    test('已有的返回 200 和大小', () async {
      final hash = await files.put([1, 2, 3, 4]);
      final r = await call('HEAD', 'files/$hash', auth: token);

      expect(r.statusCode, 200);
      expect(r.headers['content-length'], '4');
    });

    test('没有的返回 404，客户端据此决定要不要真传', () async {
      final r = await call('HEAD', 'files/${'b' * 64}', auth: token);
      expect(r.statusCode, 404);
    });
  });
}
