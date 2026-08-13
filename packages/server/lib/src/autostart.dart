import 'dart:io';

import 'package:path/path.dart' as p;

/// 开机自启。
///
/// Windows 上走当前用户的 Run 注册表项——不需要管理员权限，也不用装服务。
///
/// 直接把 exe 写进 Run 项会在每次开机时弹一个控制台窗口，所以中间垫一个
/// VBScript：`WScript.Shell.Run` 的第二个参数传 0 就是隐藏窗口启动。
/// 这是 Windows 上最省事又不需要额外依赖的隐藏启动方式。
abstract final class Autostart {
  static const registryKey =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

  /// 注册表里的值名。改它等于换一个自启项，会留下旧的，所以别随便改。
  static const valueName = 'DonkeyKanbanServer';

  static bool get supported => Platform.isWindows;

  /// 生成隐藏启动用的 VBScript。
  ///
  /// 抽成纯函数是因为引号转义最容易出错：VBScript 字符串里的引号要写成
  /// 两个双引号，路径带空格时少一层引号就整个跑不起来。
  static String buildLauncherScript(String exePath, List<String> args) {
    final quoted = [
      '""$exePath""',
      for (final a in args) if (a.contains(' ')) '""$a""' else a,
    ].join(' ');
    return 'CreateObject("WScript.Shell").Run "$quoted", 0, False\n';
  }

  static String launcherPath(String dataDir) =>
      p.join(dataDir, 'start-hidden.vbs');

  /// 写进注册表的那行命令。
  static String registryCommand(String launcherPath) =>
      'wscript.exe "$launcherPath"';

  static Future<bool> isEnabled() async {
    if (!supported) return false;
    final result = await Process.run('reg', [
      'query',
      registryKey,
      '/v',
      valueName,
    ]);
    return result.exitCode == 0;
  }

  /// 打开开机自启。[exePath] 传当前可执行文件的绝对路径。
  static Future<void> enable({
    required String exePath,
    required String dataDir,
    required List<String> args,
  }) async {
    if (!supported) {
      throw UnsupportedError('开机自启目前只支持 Windows');
    }

    final launcher = File(launcherPath(dataDir));
    await launcher.parent.create(recursive: true);
    await launcher.writeAsString(buildLauncherScript(exePath, args));

    final result = await Process.run('reg', [
      'add',
      registryKey,
      '/v',
      valueName,
      '/t',
      'REG_SZ',
      '/d',
      registryCommand(launcher.path),
      '/f',
    ]);
    if (result.exitCode != 0) {
      throw StateError('写注册表失败：${result.stderr}');
    }
  }

  static Future<void> disable({String? dataDir}) async {
    if (!supported) return;
    await Process.run('reg', [
      'delete',
      registryKey,
      '/v',
      valueName,
      '/f',
    ]);
    if (dataDir != null) {
      final launcher = File(launcherPath(dataDir));
      if (launcher.existsSync()) await launcher.delete();
    }
  }
}
