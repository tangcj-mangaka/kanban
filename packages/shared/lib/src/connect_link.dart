import 'package:meta/meta.dart';

/// 连接链接：`kanban://connect?host=192.168.1.23&port=8765&code=A1B2C3`
///
/// 服务端把它印成二维码和一行文本，客户端扫码或粘贴即可连上，不用手抄
/// IP 和端口。放在 shared 里是因为**两端必须对同一个格式**——一边生成
/// 一边解析，格式定义只能有一份。
@immutable
class ConnectLink {
  final String host;
  final int port;

  /// 一次性配对码。已经配对过的设备不需要它。
  final String? code;

  const ConnectLink({required this.host, required this.port, this.code});

  static const scheme = 'kanban';
  static const host_ = 'connect';
  static const defaultPort = 8765;

  String toUri() {
    final query = {
      'host': host,
      'port': '$port',
      if (code != null && code!.isNotEmpty) 'code': code!,
    };
    final pairs = query.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    return '$scheme://$host_?$pairs';
  }

  /// 解析一个连接链接。格式不对返回 null，不抛异常——用户手动粘贴时
  /// 粘错东西是常事，那不该让程序崩，只该提示"这不是连接链接"。
  static ConnectLink? parse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;

    final uri = Uri.tryParse(text);
    if (uri == null) return null;
    if (uri.scheme.toLowerCase() != scheme) return null;
    if (uri.host.toLowerCase() != host_) return null;

    final host = uri.queryParameters['host']?.trim();
    if (host == null || host.isEmpty) return null;

    final port = int.tryParse(uri.queryParameters['port'] ?? '') ?? defaultPort;
    if (port <= 0 || port > 65535) return null;

    final code = uri.queryParameters['code']?.trim().toUpperCase();

    return ConnectLink(
      host: host,
      port: port,
      code: (code == null || code.isEmpty) ? null : code,
    );
  }

  @override
  String toString() => toUri();

  @override
  bool operator ==(Object other) =>
      other is ConnectLink &&
      other.host == host &&
      other.port == port &&
      other.code == code;

  @override
  int get hashCode => Object.hash(host, port, code);
}

/// 局域网发现用的 UDP 端口。
///
/// 和同步用的 TCP 端口分开：TCP 端口用户可以改，发现端口是约定值，
/// 改了两边就找不到对方了。
const int kDiscoveryPort = 8766;

/// 一条发现广播的内容。
@immutable
class DiscoveryBeacon {
  /// 用来确认这个广播是驴看板发的，不是局域网里别的什么东西。
  static const magic = 'kanban-board';

  final String host;
  final int port;

  /// 服务端所在机器的名字，用户据此认出是哪台。
  final String name;

  const DiscoveryBeacon({
    required this.host,
    required this.port,
    required this.name,
  });

  Map<String, Object?> toJson() => {
    'magic': magic,
    'host': host,
    'port': port,
    'name': name,
  };

  static DiscoveryBeacon? fromJson(Map<String, Object?> json) {
    if (json['magic'] != magic) return null;
    final host = (json['host'] as String?)?.trim();
    final port = (json['port'] as num?)?.toInt();
    if (host == null || host.isEmpty || port == null) return null;
    return DiscoveryBeacon(
      host: host,
      port: port,
      name: (json['name'] as String?) ?? '未命名服务端',
    );
  }

  ConnectLink get link => ConnectLink(host: host, port: port);

  @override
  bool operator ==(Object other) =>
      other is DiscoveryBeacon && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);
}
