import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/database.dart';
import 'data/repository.dart';
import 'sync/sync_client.dart';

/// 数据库单例。整个进程只开一个连接。
final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final repositoryProvider = Provider<Repository>(
  (ref) => Repository(ref.watch(databaseProvider)),
);

/// 同步客户端。进程内单例，随应用启动。
final syncClientProvider = Provider<SyncClient>((ref) {
  final client = SyncClient(ref.watch(databaseProvider));
  ref.onDispose(client.dispose);
  // 不 await：同步永远不该挡住界面启动。连不上就安静排队。
  unawaited(client.start());
  return client;
});

final syncStateProvider = StreamProvider<SyncState>(
  (ref) => ref.watch(syncClientProvider).stateStream,
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

final boardProvider = StreamProvider.family<BoardRow?, String>(
  (ref, boardId) => ref.watch(repositoryProvider).watchBoard(boardId),
);

/// 画布上的卡片（没删、没归档），按 z 排。
final canvasCardsProvider = StreamProvider.family<List<CardRow>, String>(
  (ref, boardId) => ref.watch(repositoryProvider).watchCanvasCards(boardId),
);

/// 板内所有生效的卡片-标签关系，按卡片 ID 归好组。
///
/// 一次查完再分组，比每张卡片各查一次省得多。
final cardTagMapProvider = StreamProvider.family<Map<String, List<String>>, String>(
  (ref, boardId) => ref.watch(repositoryProvider).watchCardTags(boardId).map((
    rows,
  ) {
    final map = <String, List<String>>{};
    for (final r in rows) {
      map.putIfAbsent(r.cardId, () => []).add(r.tagId);
    }
    return map;
  }),
);

/// 干草仓库里的卡片。
final archivedCardsProvider = StreamProvider.family<List<CardRow>, String>(
  (ref, boardId) => ref.watch(repositoryProvider).watchArchivedCards(boardId),
);

final cardProvider = StreamProvider.family<CardRow?, String>(
  (ref, cardId) => ref.watch(repositoryProvider).watchCard(cardId),
);

final commentsProvider = StreamProvider.family<List<CommentRow>, String>(
  (ref, cardId) => ref.watch(repositoryProvider).watchComments(cardId),
);

/// 每张卡片的评论数，供画布上的角标用。
final commentCountsProvider = StreamProvider.family<Map<String, int>, String>(
  (ref, boardId) => ref.watch(repositoryProvider).watchCommentCounts(boardId),
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
