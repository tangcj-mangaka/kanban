import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:server/src/autostart.dart';
import 'package:server/src/backup.dart';
import 'package:server/src/control_page.dart';
import 'package:server/src/discovery.dart';
import 'package:server/src/store.dart';
import 'package:server/src/sync_server.dart';
import 'package:server/src/terminal_qr.dart';
import 'package:shared/shared.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;

/// 驴看板的局域网同步服务端。
///
/// `dart build cli` 出一个自带依赖的目录，目标机器不需要装任何运行时。
Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('port', abbr: 'p', defaultsTo: '8765', help: '监听端口')
    ..addOption('data-dir', abbr: 'd', help: '数据目录，默认在用户目录下')
    ..addOption('host', help: '手动指定对外公布的地址，多网卡自动挑选选错时用')
    ..addOption('name', help: '服务端名称，别的设备上会看到')
    ..addFlag('no-discovery', negatable: false, help: '关掉局域网自动广播')
    ..addFlag('install-autostart', negatable: false, help: '开启开机自启后退出')
    ..addFlag('uninstall-autostart', negatable: false, help: '关闭开机自启后退出')
    ..addFlag('help', abbr: 'h', negatable: false, help: '显示帮助');

  final opts = parser.parse(args);
  if (opts.flag('help')) {
    stdout.writeln('驴看板同步服务端\n\n${parser.usage}');
    return;
  }

  final port = int.tryParse(opts.option('port')!) ?? 8765;
  final dataDir = opts.option('data-dir') ?? _defaultDataDir();
  Directory(dataDir).createSync(recursive: true);

  // 装/卸自启是一次性动作，做完就退出，不进主循环。
  if (opts.flag('install-autostart') || opts.flag('uninstall-autostart')) {
    await _handleAutostartFlags(opts, dataDir, port);
    return;
  }

  final store = Store.open(p.join(dataDir, 'kanban-server.sqlite'));
  final sync = SyncServer(store, onLog: _log);

  final server = await io.serve(
    const Pipeline().addHandler(_router(sync, store, dataDir, port)),
    InternetAddress.anyIPv4,
    port,
  );

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
  _printConnectInfo(addresses, port, sync.newPairCode());

  ProcessSignal.sigint.watch().listen((_) async {
    _log('正在停止…');
    discovery?.stop();
    await sync.shutdown();
    await server.close(force: true);
    store.close();
    exit(0);
  });
}

// ---------------------------------------------------------------------------
// 路由
// ---------------------------------------------------------------------------

Handler _router(SyncServer sync, Store store, String dataDir, int port) {
  final ws = sync.handler;

  return (Request request) async {
    final path = request.url.path;

    if (path == 'sync') return ws(request);

    if (path == 'info') {
      // 供体检用，不需要配对就能看，只暴露非敏感信息。
      return _json({
        'app': 'kanban',
        'online': sync.onlineCount,
        'devices': store.devices.length,
        'seq': store.maxSeq,
      });
    }

    // 以下都是控制操作，**只接受本机请求**。
    // 远端能调用就等于绕过了配对这道门。
    if (!_isLocal(request)) {
      return Response.forbidden('控制面板只能在服务端本机打开');
    }

    if (path.isEmpty) {
      return Response.ok(
        renderControlPage(
          addresses: await _currentAddresses(),
          port: port,
          pairCode: sync.currentPairCode ?? sync.newPairCode(),
          devices: store.devices,
          onlineDevices: sync.onlineDevices,
          opCount: store.opCount,
          maxSeq: store.maxSeq,
          dataDir: dataDir,
          autostartSupported: Autostart.supported,
          autostartEnabled: await Autostart.isEnabled(),
        ),
        headers: {'content-type': 'text/html; charset=utf-8'},
      );
    }

    if (request.method != 'POST') return Response.notFound('kanban server');

    switch (path) {
      case 'api/pair-code':
        return _json({'code': sync.newPairCode(), 'message': null});

      case 'api/backup':
        try {
          final file = await createBackup(dataDir);
          final pruned = await pruneBackups(dataDir);
          _log('已备份到 ${file.path}');
          return _json({
            'message': '已备份：${p.basename(file.path)}'
                '${pruned > 0 ? '（清理了 $pruned 份旧备份）' : ''}',
          });
        } catch (e) {
          return _json({'message': '备份失败：$e'});
        }

      case 'api/unpair':
        final body = await _body(request);
        final id = body['device_id'] as String?;
        if (id == null) return _json({'message': '缺少设备 ID'});
        store.unpair(id);
        _log('已踢掉设备 $id');
        return _json({'message': '已踢掉。它需要重新配对才能再同步。'});

      case 'api/autostart':
        final body = await _body(request);
        final enable = body['enabled'] == true;
        try {
          if (enable) {
            await Autostart.enable(
              exePath: Platform.resolvedExecutable,
              dataDir: dataDir,
              args: ['--port', '$port', '--data-dir', dataDir],
            );
            return _json({'message': '已开启开机自启，下次开机会在后台静默启动。'});
          }
          await Autostart.disable(dataDir: dataDir);
          return _json({'message': '已关闭开机自启。'});
        } catch (e) {
          return _json({'message': '$e'});
        }

      default:
        return Response.notFound('kanban server');
    }
  };
}

Future<Map<String, Object?>> _body(Request request) async {
  try {
    return jsonDecode(await request.readAsString()) as Map<String, Object?>;
  } catch (_) {
    return const {};
  }
}

Response _json(Map<String, Object?> data) => Response.ok(
  jsonEncode(data),
  headers: {'content-type': 'application/json; charset=utf-8'},
);

bool _isLocal(Request request) {
  final conn = request.context['shelf.io.connection_info'];
  return conn is HttpConnectionInfo && conn.remoteAddress.isLoopback;
}

Future<List<String>> _currentAddresses() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
  );
  return pickLanAddresses([
    for (final i in interfaces) NetInterfaceInfo.from(i),
  ]);
}

// ---------------------------------------------------------------------------

Future<void> _handleAutostartFlags(
  ArgResults opts,
  String dataDir,
  int port,
) async {
  if (!Autostart.supported) {
    stdout.writeln('开机自启目前只支持 Windows。');
    return;
  }
  if (opts.flag('uninstall-autostart')) {
    await Autostart.disable(dataDir: dataDir);
    stdout.writeln('已关闭开机自启。');
    return;
  }
  await Autostart.enable(
    exePath: Platform.resolvedExecutable,
    dataDir: dataDir,
    args: ['--port', '$port', '--data-dir', dataDir],
  );
  stdout.writeln('已开启开机自启，下次开机会在后台静默启动。');
}

/// 把连接方式印出来：二维码 + 链接 + 手抄用的地址和配对码。
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
  stdout.writeln('  控制面板：http://localhost:$port');
  stdout.writeln('  （查看设备、备份、开机自启都在那里）');
  stdout.writeln('');
}

String _defaultDataDir() {
  final env = Platform.environment;
  if (Platform.isWindows) {
    final base = env['APPDATA'] ?? env['USERPROFILE'] ?? '.';
    return p.join(base, 'kanban-server');
  }
  return p.join(env['HOME'] ?? '.', '.kanban-server');
}

void _log(String message) {
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  stdout.writeln(
    '[${two(now.hour)}:${two(now.minute)}:${two(now.second)}] $message',
  );
}
