import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanban/data/database.dart';
import 'package:kanban/providers.dart';
import 'package:kanban/ui/board/board_view.dart';

/// 打开看板时停在哪个视图。
///
/// 用户要的是「每次打开先看到分组」。做成「记住上次用的那个」而不是把
/// 默认值改成分组：一样满足他，而且哪天他又想从画布开始，切一下就行，
/// 不用再改一次代码。
void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  /// 等异步读盘那一下走完。
  Future<void> loaded() => Future<void>.delayed(Duration.zero);

  test('没记录时不表态，由调用方按屏幕宽度决定', () async {
    container.read(boardViewProvider);
    await loaded();
    expect(container.read(boardViewProvider), isNull);
  });

  test('切到分组，下次就停在分组', () async {
    container.read(boardViewProvider.notifier).remember(BoardView.grouped);
    await loaded();
    expect(await db.getSetting('board_view'), 'grouped');

    // 换一个全新的容器，相当于重启应用。
    final fresh = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(fresh.dispose);
    fresh.read(boardViewProvider);
    await loaded();
    expect(fresh.read(boardViewProvider), BoardView.grouped);
  });

  test('干草仓库和时间轴不算落脚点，不记', () async {
    // 去仓库里翻一次东西，之后每块板打开都落在仓库里，那像是坏了。
    container.read(boardViewProvider.notifier).remember(BoardView.canvas);
    await loaded();

    container.read(boardViewProvider.notifier).remember(BoardView.haystack);
    container.read(boardViewProvider.notifier).remember(BoardView.timeline);
    await loaded();

    expect(container.read(boardViewProvider), BoardView.canvas);
    expect(await db.getSetting('board_view'), 'canvas');
  });

  test('存着的值要是不认识，当没记录处理', () async {
    // 比如以后删掉了某个视图，老机器上还留着它的名字。
    await db.setSetting('board_view', '不存在的视图');

    container.read(boardViewProvider);
    await loaded();
    expect(container.read(boardViewProvider), isNull);
  });

  test('存着的是非落脚点视图时，也当没记录', () async {
    // 旧版本写进去的、或者手改的库。落在干草仓库里比落在画布里更让人懵。
    await db.setSetting('board_view', 'haystack');

    container.read(boardViewProvider);
    await loaded();
    expect(container.read(boardViewProvider), isNull);
  });

  test('读盘回来得晚，也盖不掉用户刚选的', () async {
    // 读盘是异步的。用户在读完之前就切了视图的话，读回来的旧值要是
    // 盖上去，看着就像点了没反应。
    await db.setSetting('board_view', 'canvas');

    container.read(boardViewProvider); // 开始读，还没回来
    container.read(boardViewProvider.notifier).remember(BoardView.grouped);
    await loaded();

    expect(container.read(boardViewProvider), BoardView.grouped);
  });
}
