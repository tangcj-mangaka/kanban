import 'dart:convert';

import 'package:shared/shared.dart';
import 'package:test/test.dart';

void main() {
  group('连接链接的生成与解析', () {
    test('带配对码的链接往返一致', () {
      const link = ConnectLink(host: '192.168.1.23', port: 8765, code: 'A1B2C3');
      expect(ConnectLink.parse(link.toUri()), link);
    });

    test('不带配对码的链接往返一致', () {
      const link = ConnectLink(host: '10.0.0.5', port: 9000);
      final back = ConnectLink.parse(link.toUri())!;
      expect(back.host, '10.0.0.5');
      expect(back.port, 9000);
      expect(back.code, isNull);
    });

    test('生成的格式就是文档里写的那个', () {
      const link = ConnectLink(host: '192.168.1.23', port: 8765, code: 'A1B2C3');
      expect(
        link.toUri(),
        'kanban://connect?host=192.168.1.23&port=8765&code=A1B2C3',
      );
    });

    test('省略端口时用默认值', () {
      final link = ConnectLink.parse('kanban://connect?host=192.168.1.23')!;
      expect(link.port, ConnectLink.defaultPort);
    });

    test('配对码统一转成大写', () {
      // 用户手打的时候大小写随意，服务端那边比的是大写。
      final link = ConnectLink.parse(
        'kanban://connect?host=1.2.3.4&code=a1b2c3',
      )!;
      expect(link.code, 'A1B2C3');
    });

    test('两端的空白被忽略', () {
      final link = ConnectLink.parse(
        '  kanban://connect?host=1.2.3.4&port=8765  ',
      );
      expect(link?.host, '1.2.3.4');
    });
  });

  group('解析失败时返回 null 而不抛异常', () {
    // 用户手动粘贴时粘错东西是常事，那不该让程序崩。
    test('空字符串', () {
      expect(ConnectLink.parse(''), isNull);
      expect(ConnectLink.parse('   '), isNull);
    });

    test('不是 kanban 协议', () {
      expect(ConnectLink.parse('https://example.com?host=1.2.3.4'), isNull);
      expect(ConnectLink.parse('随便一段文字'), isNull);
    });

    test('协议对但路径不对', () {
      expect(ConnectLink.parse('kanban://something?host=1.2.3.4'), isNull);
    });

    test('缺 host', () {
      expect(ConnectLink.parse('kanban://connect?port=8765'), isNull);
      expect(ConnectLink.parse('kanban://connect?host='), isNull);
    });

    test('端口越界', () {
      expect(ConnectLink.parse('kanban://connect?host=1.2.3.4&port=0'), isNull);
      expect(
        ConnectLink.parse('kanban://connect?host=1.2.3.4&port=70000'),
        isNull,
      );
    });

    test('端口不是数字时退回默认值而不是失败', () {
      final link = ConnectLink.parse('kanban://connect?host=1.2.3.4&port=abc');
      expect(link?.port, ConnectLink.defaultPort);
    });
  });

  group('发现广播', () {
    test('往返一致', () {
      const beacon = DiscoveryBeacon(
        host: '192.168.1.23',
        port: 8765,
        name: '工作笔记本',
      );
      final back = DiscoveryBeacon.fromJson(
        jsonDecode(jsonEncode(beacon.toJson())) as Map<String, Object?>,
      )!;
      expect(back.host, '192.168.1.23');
      expect(back.port, 8765);
      expect(back.name, '工作笔记本');
    });

    test('没有 magic 的包被忽略', () {
      // 局域网里什么广播都有，得能认出哪些是自己的。
      expect(
        DiscoveryBeacon.fromJson({'host': '1.2.3.4', 'port': 8765}),
        isNull,
      );
      expect(
        DiscoveryBeacon.fromJson({
          'magic': '别的应用',
          'host': '1.2.3.4',
          'port': 8765,
        }),
        isNull,
      );
    });

    test('缺字段的包被忽略', () {
      expect(
        DiscoveryBeacon.fromJson({'magic': DiscoveryBeacon.magic}),
        isNull,
      );
      expect(
        DiscoveryBeacon.fromJson({
          'magic': DiscoveryBeacon.magic,
          'host': '',
          'port': 8765,
        }),
        isNull,
      );
    });

    test('缺名字时给个占位，不算失败', () {
      final beacon = DiscoveryBeacon.fromJson({
        'magic': DiscoveryBeacon.magic,
        'host': '1.2.3.4',
        'port': 8765,
      })!;
      expect(beacon.name, isNotEmpty);
    });

    test('同一地址端口的广播视为同一台服务端', () {
      // 一台机器有多张网卡时会从多个地址广播，去重靠这个。
      const a = DiscoveryBeacon(host: '1.2.3.4', port: 8765, name: 'A');
      const b = DiscoveryBeacon(host: '1.2.3.4', port: 8765, name: '改了名');
      expect({a, b}.length, 1);
    });
  });
}
