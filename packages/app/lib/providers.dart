import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/database.dart';
import 'data/repository.dart';
import 'dart:io';

import 'sync/attachment_store.dart';
import 'sync/attachment_syncer.dart';
import 'sync/discovery_listener.dart';
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
  final client = SyncClient(
    ref.watch(databaseProvider),
    // 同步的问题几乎都是时序问题，靠事后推理很难对上，得看事情实际
    // 发生的顺序。只在调试构建里打，不打扰正式版。
    onLog: kDebugMode ? (m) => debugPrint('[同步] $m') : null,
  );
  ref.onDispose(client.dispose);
  // 不 await：同步永远不该挡住界面启动。连不上就安静排队。
  unawaited(client.start());
  return client;
});

final syncStateProvider = StreamProvider<SyncState>(
  (ref) => ref.watch(syncClientProvider).stateStream,
);

/// 局域网里发现的服务端。
///
/// 只在设置页打开时才监听——常驻监听一个 UDP 端口没必要，
/// 而且在有些系统上会触发防火墙询问。
final discoveredServersProvider =
    StreamProvider.autoDispose<List<DiscoveredServer>>((ref) {
      final listener = DiscoveryListener();
      ref.onDispose(listener.dispose);
      unawaited(listener.start());
      return listener.stream;
    });

/// 附件缓存目录。在 main() 里解析好后覆盖进来——路径要异步取，
/// 而 provider 得同步给出结果。
final attachmentCacheDirProvider = Provider<Directory>(
  (_) => throw UnimplementedError('要在 ProviderScope 里覆盖'),
);

final attachmentStoreProvider = Provider<AttachmentStore>(
  (ref) => AttachmentStore(
    ref.watch(databaseProvider),
    ref.watch(attachmentCacheDirProvider),
  ),
);

/// 附件的上传下载。
///
/// 走独立的 HTTP 通道，但用同一台服务器、同一个令牌。
final attachmentSyncerProvider = Provider<AttachmentSyncer>((ref) {
  final client = ref.watch(syncClientProvider);
  final syncer = AttachmentSyncer(
    store: ref.watch(attachmentStoreProvider),
    endpoint: () {
      final e = client.serverEndpoint;
      if (e == null) return null;
      return ServerEndpoint(host: e.host, port: e.port, token: e.token);
    },
    onLog: kDebugMode ? (m) => debugPrint('[附件] $m') : null,
  );
  ref.onDispose(syncer.dispose);

  // 一连上就把离线期间攒的附件补传出去。
  ref.listen(syncStateProvider, (previous, next) {
    final status = next.value?.status;
    if (status == SyncStatus.online || status == SyncStatus.syncing) {
      unawaited(syncer.flush());
    }
  }, fireImmediately: true);

  return syncer;
});

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

final attachmentsProvider =
    StreamProvider.family<List<AttachmentRow>, String>(
      (ref, cardId) => ref.watch(repositoryProvider).watchAttachments(cardId),
    );

/// 每张卡片的附件数，供画布上的角标用。
final attachmentCountsProvider =
    StreamProvider.family<Map<String, int>, String>(
      (ref, boardId) =>
          ref.watch(repositoryProvider).watchAttachmentCounts(boardId),
    );

/// 每张卡片的评论数，供画布上的角标用。
final commentCountsProvider = StreamProvider.family<Map<String, int>, String>(
  (ref, boardId) => ref.watch(repositoryProvider).watchCommentCounts(boardId),
);

/// 每张卡片的封面图（第一张图片附件），供画布和分组视图用。
final cardCoversProvider =
    StreamProvider.family<Map<String, AttachmentRow>, String>(
      (ref, boardId) => ref.watch(repositoryProvider).watchCardCovers(boardId),
    );

/// 全局搜索结果，key 是搜索词。
///
/// **必须 autoDispose**：用户每敲一个字就是一个新的 family key，不自动回收
/// 的话，搜一次「水管配件」会留下 4 个订阅着数据库的 provider 永不释放。
final searchProvider = StreamProvider.autoDispose.family<List<SearchHit>, String>(
  (ref, query) => ref.watch(repositoryProvider).searchCards(query),
);

/// 主题模式，存在 settings 表里。
///
/// 不用 shared_preferences：设置表已经在同一个 sqlite 里了，多引一个插件
/// 就多一处各平台文件位置不同的问题。
///
/// **不进 op 日志**，所以不会同步到别的设备——外观是「这台机器」的偏好。
/// 台式机开深色、手机跟随系统，是很正常的用法。
class ThemeModeNotifier extends Notifier<ThemeMode> {
  static const _key = 'theme_mode';

  /// 用户是否已经自己动过。
  ///
  /// 读盘是异步的：如果用户在读完之前就点了切换，读盘结果回来会把
  /// 他刚选的覆盖掉——按钮看着像失灵。有这个标记就让用户说了算。
  bool _touched = false;

  @override
  ThemeMode build() {
    // 读盘是异步的，而 build 必须同步返回。所以先给个跟随系统，
    // 读到了再覆盖——启动瞬间可能闪一下，比阻塞首帧强。
    _load();
    return ThemeMode.system;
  }

  Future<void> _load() async {
    final saved = await ref.read(databaseProvider).getSetting(_key);
    if (_touched) return;
    final mode = _parse(saved);
    if (mode != null) state = mode;
  }

  /// 在「跟随系统 → 浅色 → 深色」之间轮换。
  void cycle() {
    _touched = true;
    state = switch (state) {
      ThemeMode.system => ThemeMode.light,
      ThemeMode.light => ThemeMode.dark,
      ThemeMode.dark => ThemeMode.system,
    };
    // 存盘失败也不该拦着用户换主题，所以不 await。
    ref.read(databaseProvider).setSetting(_key, state.name);
  }

  static ThemeMode? _parse(String? name) => switch (name) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    'system' => ThemeMode.system,
    _ => null,
  };
}

final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(
  ThemeModeNotifier.new,
);
