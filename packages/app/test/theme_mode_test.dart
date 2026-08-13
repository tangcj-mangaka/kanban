import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanban/data/database.dart';
import 'package:kanban/providers.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  ProviderContainer makeContainer() {
    final c = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('没存过时是跟随系统', () async {
    final c = makeContainer();
    expect(c.read(themeModeProvider), ThemeMode.system);
  });

  test('切换会写进设置表', () async {
    final c = makeContainer();
    c.read(themeModeProvider.notifier).cycle();

    expect(c.read(themeModeProvider), ThemeMode.light);
    expect(await db.getSetting('theme_mode'), 'light');
  });

  test('轮换顺序是 系统 → 浅色 → 深色 → 系统', () async {
    final c = makeContainer();
    final n = c.read(themeModeProvider.notifier);

    n.cycle();
    expect(c.read(themeModeProvider), ThemeMode.light);
    n.cycle();
    expect(c.read(themeModeProvider), ThemeMode.dark);
    n.cycle();
    expect(c.read(themeModeProvider), ThemeMode.system);
  });

  test('重开一次会读回上次选的', () async {
    // 这条就是这次改动要解决的问题本身：以前每次启动都退回跟随系统。
    final first = makeContainer();
    first.read(themeModeProvider.notifier).cycle();
    first.read(themeModeProvider.notifier).cycle();
    expect(await db.getSetting('theme_mode'), 'dark');

    final second = makeContainer();
    second.read(themeModeProvider); // 触发 build，开始读盘
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(second.read(themeModeProvider), ThemeMode.dark);
  });

  test('读盘慢的时候，用户先点的选择不会被覆盖', () async {
    await db.setSetting('theme_mode', 'dark');

    final c = makeContainer();
    expect(c.read(themeModeProvider), ThemeMode.system, reason: '首帧还没读到');
    // 读盘还没回来就切换。
    c.read(themeModeProvider.notifier).cycle();
    expect(c.read(themeModeProvider), ThemeMode.light);

    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      c.read(themeModeProvider),
      ThemeMode.light,
      reason: '存的是 dark，但用户刚亲手选了 light，不该被读盘结果盖掉',
    );
  });

  test('设置表里是垃圾值时退回跟随系统而不是崩', () async {
    await db.setSetting('theme_mode', '天知道是什么');

    final c = makeContainer();
    c.read(themeModeProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(c.read(themeModeProvider), ThemeMode.system);
  });
}
