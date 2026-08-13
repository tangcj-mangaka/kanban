import 'dart:convert';

import 'package:qr/qr.dart';
import 'package:shared/shared.dart';

import 'store.dart';

/// 服务端的本机控制页。
///
/// Dart 的控制台程序没有可用的系统托盘库（tray_manager、system_tray 都只
/// 支持 Flutter），自己写 Win32 托盘要两百来行 FFI，而且只能在 Windows 上
/// 验证。所以托盘菜单该有的东西改成一个本机网页：状态、二维码、已配对
/// 设备、备份、开机自启，浏览器打开就是。
///
/// 顺带的好处是它在三个系统上都一样能用。
String renderControlPage({
  required List<String> addresses,
  required int port,
  required String pairCode,
  required List<Device> devices,
  required List<String> onlineDevices,
  required int opCount,
  required int maxSeq,
  required String dataDir,
  required bool autostartSupported,
  required bool autostartEnabled,
}) {
  final host = addresses.isEmpty ? 'localhost' : addresses.first;
  final link = ConnectLink(host: host, port: port, code: pairCode);
  final online = onlineDevices.toSet();

  return '''
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>驴看板服务端</title>
<style>
  :root {
    --paper: #FAF8F4; --raised: #FFFFFF; --ink: #23221E; --ink2: #4A4740;
    --muted: #7C786E; --hair: #DFDAD0; --brand: #4A4FD0; --ok: #1F9D51;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --paper: #1A1917; --raised: #221F1C; --ink: #EDEAE3; --ink2: #C2BCB1;
      --muted: #918B80; --hair: #383430; --brand: #A9ACF9; --ok: #6EDB99;
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 0 20px 64px; background: var(--paper); color: var(--ink);
    font-family: -apple-system, "Segoe UI", "Microsoft YaHei", "PingFang SC", sans-serif;
    line-height: 1.7;
  }
  .wrap { max-width: 720px; margin: 0 auto; }
  header { padding: 40px 0 24px; border-bottom: 1px solid var(--hair); }
  h1 { margin: 0; font-size: 26px; font-weight: 600; }
  .sub { color: var(--muted); font-size: 14px; margin-top: 4px; }
  section { padding: 28px 0; border-bottom: 1px solid var(--hair); }
  h2 { font-size: 15px; margin: 0 0 14px; color: var(--muted); font-weight: 600; }
  .pair { display: flex; gap: 24px; align-items: center; flex-wrap: wrap; }
  .qr { background: #fff; padding: 12px; border-radius: 10px; line-height: 0; }
  .code {
    font-family: ui-monospace, "SF Mono", Consolas, monospace;
    font-size: 30px; letter-spacing: .18em; font-weight: 600;
  }
  .link {
    font-family: ui-monospace, "SF Mono", Consolas, monospace;
    font-size: 12px; color: var(--muted); word-break: break-all; margin-top: 6px;
  }
  .row {
    display: flex; align-items: center; gap: 12px; padding: 11px 14px;
    background: var(--raised); border: 1px solid var(--hair);
    border-radius: 9px; margin-bottom: 8px;
  }
  .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--muted); flex: none; }
  .dot.on { background: var(--ok); }
  .grow { flex: 1; min-width: 0; }
  .meta { color: var(--muted); font-size: 12.5px; }
  .stats { display: flex; gap: 28px; flex-wrap: wrap; }
  .stat b { display: block; font-size: 21px; font-weight: 600; }
  .stat span { color: var(--muted); font-size: 12.5px; }
  button, .btn {
    font: inherit; font-size: 14px; cursor: pointer; border-radius: 8px;
    border: 1px solid var(--hair); background: var(--raised); color: var(--ink);
    padding: 7px 14px;
  }
  button.primary { background: var(--brand); border-color: var(--brand); color: #fff; }
  button.danger { color: #D93A2B; }
  button:hover { filter: brightness(0.97); }
  .actions { display: flex; gap: 10px; flex-wrap: wrap; }
  code.path {
    font-family: ui-monospace, Consolas, monospace; font-size: 12.5px;
    color: var(--ink2); word-break: break-all;
  }
  .note { color: var(--muted); font-size: 13px; margin-top: 10px; }
</style>
</head>
<body>
<div class="wrap">
  <header>
    <h1>驴看板服务端</h1>
    <div class="sub">这台机器上的同步服务。关掉这个网页不影响它运行。</div>
  </header>

  <section>
    <h2>连接新设备</h2>
    <div class="pair">
      <div class="qr">${_qrSvg(link.toUri())}</div>
      <div>
        <div class="code">$pairCode</div>
        <div class="meta">地址 $host　端口 $port</div>
        <div class="link">${_escape(link.toUri())}</div>
        <div style="margin-top:12px">
          <button class="primary" onclick="post('/api/pair-code')">换一个配对码</button>
        </div>
        <div class="note">配对码只能用一次，${SyncServerLimits.pairCodeMinutes} 分钟后过期。</div>
      </div>
    </div>
    ${addresses.length > 1 ? '<div class="note">这台机器还有别的地址：${addresses.skip(1).map(_escape).join('、')}。上面二维码用的是第一个，连不上就换一个试试。</div>' : ''}
  </section>

  <section>
    <h2>已配对的设备</h2>
    ${devices.isEmpty ? '<div class="meta">还没有设备连过来。</div>' : devices.map((d) => '''
    <div class="row">
      <span class="dot${online.contains(d.name) ? ' on' : ''}"></span>
      <span class="grow">
        ${_escape(d.name)}
        <span class="meta">· ${online.contains(d.name) ? '在线' : '离线'}</span>
      </span>
      <button class="danger" onclick="unpair('${_escape(d.id)}')">踢掉</button>
    </div>''').join()}
  </section>

  <section>
    <h2>数据</h2>
    <div class="stats">
      <div class="stat"><b>$opCount</b><span>操作记录</span></div>
      <div class="stat"><b>$maxSeq</b><span>当前序号</span></div>
      <div class="stat"><b>${devices.length}</b><span>已配对设备</span></div>
    </div>
    <div style="margin-top:14px">
      <code class="path">${_escape(dataDir)}</code>
    </div>
    <div class="actions" style="margin-top:14px">
      <button onclick="post('/api/backup')">立即备份</button>
    </div>
    <div class="note">备份是数据目录的一份 zip 拷贝，放在同一个目录下。</div>
  </section>

  <section>
    <h2>开机自启</h2>
    ${autostartSupported ? '''
    <div class="row">
      <span class="dot${autostartEnabled ? ' on' : ''}"></span>
      <span class="grow">${autostartEnabled ? '已开启，开机时会在后台静默启动' : '未开启'}</span>
      <button onclick="post('/api/autostart', {enabled: ${!autostartEnabled}})">
        ${autostartEnabled ? '关闭' : '开启'}
      </button>
    </div>''' : '<div class="meta">开机自启目前只支持 Windows。</div>'}
  </section>
</div>

<script>
async function post(url, body) {
  const r = await fetch(url, {
    method: 'POST',
    headers: {'content-type': 'application/json'},
    body: JSON.stringify(body || {}),
  });
  const data = await r.json().catch(() => ({}));
  if (data.message) alert(data.message);
  location.reload();
}
function unpair(id) {
  if (confirm('踢掉这台设备？它需要重新配对才能再同步。')) {
    post('/api/unpair', {device_id: id});
  }
}
// 页面停留时定时刷新，好让在线状态是准的
setTimeout(() => location.reload(), 15000);
</script>
</body>
</html>
''';
}

/// 服务端的一些常量，控制页要显示给用户。
abstract final class SyncServerLimits {
  static const pairCodeMinutes = 5;
}

/// 把二维码画成内联 SVG。
///
/// 不用外链图片：控制页要在完全离线的局域网里打开，任何外部资源都加载不了。
String _qrSvg(String data, {int quietZone = 2, int scale = 4}) {
  final qr = QrCode(
    payload: QrPayload.fromString(data),
    errorCorrectLevel: QrErrorCorrectLevel.medium,
  );
  final image = QrImage(qr);
  final n = qr.moduleCount;
  final total = (n + quietZone * 2) * scale;

  final rects = StringBuffer();
  for (var r = 0; r < n; r++) {
    for (var c = 0; c < n; c++) {
      if (!image.isDark(r, c)) continue;
      final x = (c + quietZone) * scale;
      final y = (r + quietZone) * scale;
      rects.write('<rect x="$x" y="$y" width="$scale" height="$scale"/>');
    }
  }

  return '<svg xmlns="http://www.w3.org/2000/svg" width="$total" height="$total" '
      'viewBox="0 0 $total $total" shape-rendering="crispEdges">'
      '<rect width="$total" height="$total" fill="#fff"/>'
      '<g fill="#000">$rects</g></svg>';
}

String _escape(String s) => const HtmlEscape().convert(s);
