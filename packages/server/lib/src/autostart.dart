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

  /// 自启脚本指向的 exe 路径，脚本不存在或读不懂时返回 null。
  ///
  /// 只认 [buildLauncherScript] 自己写出来的那一行；别人手改过的脚本
  /// 解析不出来就当作「不知道」，宁可不动也不要瞎改用户的文件。
  static String? launcherTarget(String dataDir) {
    final file = File(launcherPath(dataDir));
    if (!file.existsSync()) return null;

    final text = file.readAsStringSync();
    // 整行长这样（注意带不带参数，路径右边的引号数不一样）：
    //   无参数：.Run """C:\路径\xxx.exe""", 0, False
    //   带参数：.Run """C:\路径\xxx.exe"" --port 8765", 0, False
    //
    // 所以只能按「左边三个引号、右边两个引号」来框——右边第三个引号在
    // 整串参数的末尾，不在路径旁边。按三个找的话，真实的自启脚本（一定
    // 带 --port 和 --data-dir）一条都匹配不上。
    final match = RegExp(r'\.Run\s+"""(.+?)""').firstMatch(text);
    return match?.group(1);
  }

  /// 开机自启开着的话，确保它指向**当前这个** exe。
  ///
  /// 为什么必须有这一步：开启自启时记的是那一刻的绝对路径，写死进 VBS。
  /// 而这个服务端是以 zip 分发的——用户每次更新都会把 exe 解压到别处或
  /// 覆盖掉旧的。路径一变，开机时 Windows 就弹「找不到指定的文件」
  /// （错误码 80070002），而自启项看上去还是「已开启」。
  ///
  /// 所以每次启动都核一遍，对不上就悄悄重写。用户不该为了升级去记得
  /// 重做一次自启设置。
  ///
  /// 返回是否真的改了，调用方据此决定要不要打日志。
  static Future<bool> refresh({
    required String exePath,
    required String dataDir,
    required List<String> args,
  }) async {
    if (!supported) return false;
    if (!await isEnabled()) return false;

    final current = launcherTarget(dataDir);
    if (current == exePath) return false;

    await enable(exePath: exePath, dataDir: dataDir, args: args);
    return true;
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
