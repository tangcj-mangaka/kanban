import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:server/src/discovery.dart';
import 'package:server/src/store.dart';
import 'package:server/src/sync_server.dart';
import 'package:server/src/terminal_qr.dart';
import 'package:shared/shared.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;

/// 驴看板的局域网同步服务端。
///
/// `dart compile exe bin/server.dart -o kanban-server` 出单文件，
/// 目标机器不需要装任何运行时。
Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('port', abbr: 'p', defaultsTo: '8765', help: '监听端口')
    ..addOption('data-dir', abbr: 'd', help: '数据目录，默认在用户目录下')
    ..addOption('host', help: '手动指定对外公布的地址，多网卡自动挑选选错时用')
    ..addOption('name', help: '服务端名称，别的设备上会看到')
    ..addFlag('no-discovery', negatable: false, help: '关掉局域网自动广播')
    ..addFlag('help', abbr: 'h', negatable: false, help: '显示帮助');

  final opts = parser.parse(args);
  if (opts.flag('help')) {
    stdout.writeln('驴看板同步服务端\n\n${parser.usage}');
    return;
  }

  final port = int.tryParse(opts.option('port')!) ?? 8765;
  final dataDir = opts.option('data-dir') ?? _defaultDataDir();
  Directory(dataDir).createSync(recursive: true);

  final store = Store.open(p.join(dataDir, 'kanban-server.sqlite'));
  final sync = SyncServer(store, onLog: _log);

  final handler = const Pipeline()
      .addMiddleware(_cors)
      .addHandler(_router(sync, store));

  final server = await io.serve(handler, InternetAddress.anyIPv4, port);

  _log('数据目录 $dataDir');
  _log('已有 ${store.opCount} 条操作记录，最大序号 ${store.maxSeq}');
  _log('已配对设备 ${store.devices.length} 台');
  _log('监听 ${server.address.address}:${server.port}');

  final serverName = opts.option('name') ?? Platform.localHostname;
  DiscoveryBroadcaster? discovery;
  if (!opts.flag('no-discovery')) {
    discovery = DiscoveryBroadcaster(
      syncPort: port,
      serverName: serverName,
      overrideHost: opts.option('host'),
      onLog: _log,
    );
    try {
      await discovery.start();
    } catch (e) {
      // 发现不可用不影响同步，手动填地址那条路照常走。
      _log('局域网自动发现启动失败（不影响同步）：$e');
      discovery = null;
    }
  }

  final addresses = discovery != null
      ? await discovery.currentAddresses()
      : <String>[];
  final code = sync.newPairCode();
  _printConnectInfo(addresses, port, code);

  // 优雅停机：把连接都关掉再退出，客户端会立刻进离线模式而不是干等超时。
  ProcessSignal.sigint.watch().listen((_) async {
    _log('正在停止…');
    discovery?.stop();
    await sync.shutdown();
    await server.close(force: true);
    store.close();
    exit(0);
  });
}

Handler _router(SyncServer sync, Store store) {
  final ws = sync.handler;

  return (Request request) {
    switch (request.url.path) {
      case 'sync':
        return ws(request);
      case 'info':
        // 供发现和体检用：不需要配对就能看，但只暴露非敏感信息。
        return Response.ok(
          '{"app":"kanban","online":${sync.onlineCount},'
          '"devices":${store.devices.length},"seq":${store.maxSeq}}',
          headers: {'content-type': 'application/json'},
        );
      case 'pair-code':
        // 本机才能取新配对码——远端拿得到就等于没有配对这道门。
        if (!_isLocal(request)) {
          return Response.forbidden('只能在服务端本机获取配对码');
        }
        return Response.ok('{"code":"${sync.newPairCode()}"}',
            headers: {'content-type': 'application/json'});
      default:
        return Response.notFound('kanban server');
    }
  };
}

bool _isLocal(Request request) {
  final conn = request.context['shelf.io.connection_info'];
  if (conn is HttpConnectionInfo) {
    final addr = conn.remoteAddress;
    return addr.isLoopback;
  }
  return false;
}

Handler _cors(Handler inner) => (request) async {
  final response = await inner(request);
  return response.change(headers: {'access-control-allow-origin': '*'});
};

String _defaultDataDir() {
  final env = Platform.environment;
  if (Platform.isWindows) {
    final base = env['APPDATA'] ?? env['USERPROFILE'] ?? '.';
    return p.join(base, 'kanban-server');
  }
  final home = env['HOME'] ?? '.';
  return p.join(home, '.kanban-server');
}

void _log(String message) {
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  stdout.writeln(
    '[${two(now.hour)}:${two(now.minute)}:${two(now.second)}] $message',
  );
}

/// 把连接方式印出来：一个二维码 + 一行链接 + 手抄用的地址和配对码。
///
/// 三种都给，是因为三种场景都会遇到：手机扫码最快；台式机没摄像头就
/// 复制链接；万一都不行还能照着最后那两行手动填。
void _printConnectInfo(List<String> addresses, int port, String code) {
  final host = addresses.isEmpty ? 'localhost' : addresses.first;
  final link = ConnectLink(host: host, port: port, code: code);

  stdout.writeln('');
  stdout.writeln(renderQrToText(link.toUri()));
  stdout.writeln('  $link');
  stdout.writeln('');
  stdout.writeln('  手动填的话：地址 $host   端口 $port   配对码 $code');
  if (addresses.length > 1) {
    stdout.writeln('  这台机器还有别的地址：${addresses.skip(1).join('、')}');
  }
  stdout.writeln('  配对码 ${SyncServer.pairCodeTtl.inMinutes} 分钟内有效，只能用一次。');
  stdout.writeln('');
}
