import 'dart:convert';

import 'package:shelf/shelf.dart';

import 'file_store.dart';
import 'store.dart';

// ---------------------------------------------------------------------------
// 附件
// ---------------------------------------------------------------------------

Future<Response> handleFileRequest(
  Request request,
  Store store,
  FileStore files,
) async {
  // 附件接口跟 WebSocket 用同一套令牌鉴权。没有这道门，同一局域网里
  // 任何人都能把文件读走。
  final token = bearerToken(request);
  if (token == null || store.deviceByToken(token) == null) {
    return Response.unauthorized('需要有效的设备令牌');
  }

  final segments = request.url.pathSegments;

  // POST /files —— 上传，返回哈希
  if (segments.length == 1 && request.method == 'POST') {
    final bytes = await request.read().expand((chunk) => chunk).toList();
    if (bytes.isEmpty) return Response.badRequest(body: '空文件');
    if (bytes.length > FileStore.maxFileBytes) {
      return Response(
        413,
        body: '文件超过 ${FileStore.maxFileBytes ~/ (1024 * 1024)}MB 上限',
      );
    }
    final hash = await files.put(bytes);
    return jsonResponse({'hash': hash, 'size': bytes.length});
  }

  if (segments.length != 2) return Response.notFound('');
  final hash = segments[1];
  if (!FileStore.isValidHash(hash)) {
    return Response.badRequest(body: '哈希格式不对');
  }

  // HEAD /files/<hash> —— 探测有没有，上传前问一句就能秒传
  if (request.method == 'HEAD') {
    if (!files.has(hash)) return Response.notFound('');
    return Response.ok(
      null,
      headers: {'content-length': '${files.sizeOf(hash)}'},
    );
  }

  if (request.method != 'GET') return Response.notFound('');
  final data = await files.read(hash);
  if (data == null) return Response.notFound('');

  // 断点续传：大图在慢网络下断了不用从头再来
  final range = parseRange(request.headers['range'], data.length);
  if (range == null) {
    return Response.ok(
      data,
      headers: {
        'content-type': 'application/octet-stream',
        'accept-ranges': 'bytes',
        // 内容寻址：同一个哈希的内容永远不会变，可以放心长期缓存
        'cache-control': 'public, max-age=31536000, immutable',
      },
    );
  }

  final (start, end) = range;
  return Response(
    206,
    body: data.sublist(start, end + 1),
    headers: {
      'content-type': 'application/octet-stream',
      'accept-ranges': 'bytes',
      'content-range': 'bytes $start-$end/${data.length}',
    },
  );
}

String? bearerToken(Request request) {
  final header = request.headers['authorization'];
  if (header == null) return null;
  const prefix = 'Bearer ';
  if (!header.startsWith(prefix)) return null;
  final token = header.substring(prefix.length).trim();
  return token.isEmpty ? null : token;
}


Response jsonResponse(Map<String, Object?> data) => Response.ok(
  jsonEncode(data),
  headers: {'content-type': 'application/json; charset=utf-8'},
);
