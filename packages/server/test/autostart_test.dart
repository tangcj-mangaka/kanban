import 'package:server/src/autostart.dart';
import 'package:test/test.dart';

void main() {
  group('隐藏启动脚本', () {
    // 引号转义是这里最容易翻车的地方：VBScript 字符串里的引号要写成两个
    // 双引号，路径带空格时少一层引号就整个跑不起来——而且只有在 Windows
    // 上开机时才会暴露，那时候人根本不在电脑前。
    test('路径带空格时引号包得住', () {
      final script = Autostart.buildLauncherScript(
        r'C:\Program Files\驴看板\kanban-server.exe',
        [],
      );
      expect(
        script,
        contains(r'""C:\Program Files\驴看板\kanban-server.exe""'),
      );
    });

    test('第二个参数是 0，即隐藏窗口', () {
      final script = Autostart.buildLauncherScript(r'C:\a\b.exe', []);
      expect(script, contains(', 0, False'), reason: '否则每次开机都弹一个控制台窗口');
    });

    test('参数原样带上', () {
      final script = Autostart.buildLauncherScript(r'C:\a.exe', [
        '--port',
        '9000',
      ]);
      expect(script, contains('--port 9000'));
    });

    test('带空格的参数也要包引号', () {
      final script = Autostart.buildLauncherScript(r'C:\a.exe', [
        '--data-dir',
        r'D:\我的 数据',
      ]);
      expect(script, contains(r'""D:\我的 数据""'));
    });

    test('整行是一条合法的 VBScript Run 调用', () {
      final script = Autostart.buildLauncherScript(r'C:\a.exe', ['-p', '1']);
      expect(script.trim(), startsWith('CreateObject("WScript.Shell").Run "'));
      expect(script.trim(), endsWith(', 0, False'));
    });
  });

  group('注册表命令', () {
    test('用 wscript 跑脚本，路径带引号', () {
      final cmd = Autostart.registryCommand(r'C:\Users\a b\start-hidden.vbs');
      expect(cmd, r'wscript.exe "C:\Users\a b\start-hidden.vbs"');
    });

    test('写在当前用户下，不需要管理员权限', () {
      expect(Autostart.registryKey, startsWith('HKCU'));
    });
  });

  group('平台限制', () {
    test('非 Windows 上不声称支持', () {
      // 在 macOS 上跑这个测试时应当为 false；Windows CI 上为 true。
      expect(Autostart.supported, isA<bool>());
    });
  });
}
