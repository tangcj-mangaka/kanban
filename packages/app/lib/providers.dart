import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/database.dart';
import 'data/repository.dart';

/// 数据库单例。整个进程只开一个连接。
final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final repositoryProvider = Provider<Repository>(
  (ref) => Repository(ref.watch(databaseProvider)),
);

/// 看板列表。drift 的响应式查询——底层数据一变，这里自动重新发出。
final boardSummariesProvider = StreamProvider<List<BoardSummary>>(
  (ref) => ref.watch(repositoryProvider).watchBoardSummaries(),
);

/// 某个看板的标签。
///
/// 按板取而不是一次全取：每块看板方块各自订阅自己的那份，
/// 不需要在外面把两条流合起来。
final boardTagsProvider = StreamProvider.family<List<TagRow>, String>(
  (ref, boardId) => ref.watch(repositoryProvider).watchTags(boardId),
);

/// 主题模式。P5 会持久化到设置里，现在每次启动都从跟随系统开始。
class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() => ThemeMode.system;

  /// 在「跟随系统 → 浅色 → 深色」之间轮换。
  void cycle() {
    state = switch (state) {
      ThemeMode.system => ThemeMode.light,
      ThemeMode.light => ThemeMode.dark,
      ThemeMode.dark => ThemeMode.system,
    };
  }
}

final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(
  ThemeModeNotifier.new,
);
