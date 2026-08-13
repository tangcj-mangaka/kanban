import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'attachment_store.dart';

/// 服务端的连接信息。没配服务器或没配对时为 null。
class ServerEndpoint {
  final String host;
  final int port;
  final String token;

  const ServerEndpoint({
    required this.host,
    required this.port,
    required this.token,
  });

  Uri get uploadUri => Uri.parse('http://$host:$port/files');

  Uri fileUri(String hash) => Uri.parse('http://$host:$port/files/$hash');

  Map<String, String> get authHeader => {'authorization': 'Bearer $token'};
}

/// 附件的上传下载。
///
/// 和 op 的同步分开走：文件不能塞进 WebSocket 的 JSON 消息里，所以有独立的
/// HTTP 通道。但行为上遵守同一条原则——**从不阻塞本地操作**：加附件时只写
/// 本地，传是后台的事；看不到别人的附件时显示占位符，不报错也不卡住。
class AttachmentSyncer {
  final AttachmentStore store;

  /// 当前的服务端信息。离线或没配对时返回 null。
  final ServerEndpoint? Function() endpoint;

  final void Function(String message)? onLog;

  AttachmentSyncer({
    required this.store,
    required this.endpoint,
    this.onLog,
  });

  final _client = HttpClient();
  bool _flushing = false;

  /// 正在下载的哈希，避免同一个文件被并发下载多次
  /// （详情页和画布缩略图会同时要同一张图）。
  final Map<String, Future<Uint8List?>> _inFlight = {};

  /// 把待传队列里的文件推上去。
  ///
  /// 连不上就安静返回——文件还在本地，下次连上再传。
  Future<void> flush() async {
    if (_flushing) return;
    final server = endpoint();
    if (server == null) return;

    _flushing = true;
    try {
      final pending = await store.pendingUploads();
      if (pending.isEmpty) return;

      var done = 0;
      for (final hash in pending) {
        if (await _upload(server, hash)) done++;
      }
      if (done > 0) onLog?.call('上传了 $done 个附件');
    } finally {
      _flushing = false;
    }
  }

  Future<bool> _upload(ServerEndpoint server, String hash) async {
    final file = store.fileFor(hash);
    if (!file.existsSync()) return false;

    try {
      // 先问一句有没有。服务端按内容哈希存，别的设备传过同一张图的话
      // 这里就是秒传——省掉一整个文件的传输。
      final head = await _client.headUrl(server.fileUri(hash));
      server.authHeader.forEach(head.headers.set);
      final headResponse = await head.close();
      await headResponse.drain<void>();

      if (headResponse.statusCode == 200) {
        await store.markUploaded(hash);
        return true;
      }

      final request = await _client.postUrl(server.uploadUri);
      server.authHeader.forEach(request.headers.set);
      request.headers.contentType = ContentType.binary;
      request.add(await file.readAsBytes());

      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        onLog?.call('上传失败（${response.statusCode}）：$body');
        return false;
      }

      // 服务端算出来的哈希必须和本地一致，否则说明传输中出了问题。
      final returned = (jsonDecode(body) as Map<String, Object?>)['hash'];
      if (returned != hash) {
        onLog?.call('上传后哈希对不上，丢弃这次结果');
        return false;
      }

      await store.markUploaded(hash);
      return true;
    } catch (_) {
      // 连不上很正常。文件还在本地，下次再传。
      return false;
    }
  }

  /// 拿到文件内容：本地有就用本地的，没有就下载。
  ///
  /// 服务端不在线时返回 null，调用方显示占位符即可——**不该报错，
  /// 更不该卡住界面**。
  Future<Uint8List?> fetch(String hash) {
    final cached = store.has(hash);
    if (cached) return store.read(hash);

    // 同一张图可能被详情页和画布缩略图同时请求，合并成一次下载。
    return _inFlight.putIfAbsent(hash, () async {
      try {
        return await _download(hash);
      } finally {
        _inFlight.remove(hash);
      }
    });
  }

  Future<Uint8List?> _download(String hash) async {
    final server = endpoint();
    if (server == null) return null;

    try {
      final request = await _client.getUrl(server.fileUri(hash));
      server.authHeader.forEach(request.headers.set);
      final response = await request.close();
      if (response.statusCode != 200) {
        await response.drain<void>();
        return null;
      }

      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();

      // 下下来的东西存进缓存，并且直接标成已上传——它本来就是从服务端
      // 来的，不该再排进待传队列。
      await store.putBytes(bytes, uploaded: true);
      return bytes;
    } catch (_) {
      return null;
    }
  }

  void dispose() => _client.close(force: true);
}
