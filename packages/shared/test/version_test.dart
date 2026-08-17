import 'dart:io';

import 'package:shared/shared.dart';
import 'package:test/test.dart';

/// 版本号只有一个来源（[kAppVersion]），但 pubspec 里的 `version:` 是
/// Flutter 和 dart build 自己要读的，没法直接引用常量。所以只能各写一份，
/// 靠这个测试钉住它们一致——不然迟早会出现「应用里显示 0.2.0、
/// 安装包属性里写着 0.1.0」这种没法排查的情况。
void main() {
  String versionIn(String pubspecPath) {
    final file = File(pubspecPath);
    if (!file.existsSync()) {
      fail('找不到 $pubspecPath（这个测试要在仓库里跑）');
    }
    for (final line in file.readAsLinesSync()) {
      if (line.startsWith('version:')) {
        // app 的版本带构建号，形如 0.1.0+1，比较时去掉。
        return line.substring('version:'.length).trim().split('+').first;
      }
    }
    fail('$pubspecPath 里没有 version:');
  }

  test('客户端 pubspec 的版本和 kAppVersion 一致', () {
    expect(versionIn('../app/pubspec.yaml'), kAppVersion);
  });

  test('服务端 pubspec 的版本和 kAppVersion 一致', () {
    expect(versionIn('../server/pubspec.yaml'), kAppVersion);
  });

  test('版本号是三段数字', () {
    expect(RegExp(r'^\d+\.\d+\.\d+$').hasMatch(kAppVersion), isTrue);
  });
}
