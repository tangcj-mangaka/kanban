// 本地验证用的小工具：往桌面版的数据库里贴一张看板封面图。
//
// macOS 的文件选择面板跑在沙盒外的系统进程里，截图工具够不着，所以「选图」
// 那一步没法自动走。这个脚本走的是**和界面完全同一条路**（importCoverImage
// 压缩导入 + setBoardCover 写字段），只是把点按钮换成了命令行，用来把图
// 贴进去，再用截图看渲染对不对。
//
// 写成测试的样子是因为它要碰 drift_flutter，纯 dart 跑不起来。
//
// 用法（先退出应用，否则两边同时写一个 sqlite）：
//   flutter test tool/seed_cover.dart \
//     --dart-define=img=/路径/x.jpg --dart-define=board=看板名片段
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanban/data/database.dart';
import 'package:kanban/data/repository.dart';
import 'package:kanban/sync/attachment_store.dart';
import 'package:path/path.dart' as p;

const _img = String.fromEnvironment('img');
const _boardName = String.fromEnvironment('board');

void main() {
  test('贴一张封面图进桌面版的库', () async {
    expect(_img, isNotEmpty, reason: '要用 --dart-define=img=... 给图片路径');

    final home = Platform.environment['HOME']!;
    final container = p.join(home, 'Library/Containers/com.tangcj.kanban/Data');
    final db = AppDatabase(
      NativeDatabase(File(p.join(container, 'Documents/kanban.sqlite'))),
    );
    final repo = Repository(db);
    final store = AttachmentStore(
      db,
      Directory(
        p.join(
          container,
          'Library/Application Support/com.tangcj.kanban/attachments',
        ),
      ),
    );

    final boards = await repo.watchBoardSummaries().first;
    final board = _boardName.isEmpty
        ? boards.first
        : boards.firstWhere((b) => b.board.name.contains(_boardName));

    final imported = await store.importCoverImage(File(_img));
    expect(imported, isNotNull, reason: '这张图解不开');

    await repo.setBoardCover(
      board.board.id,
      hash: imported!.hash,
      thumbHash: imported.thumbHash,
    );

    // ignore: avoid_print
    print(
      '「${board.board.name}」← ${p.basename(_img)}  '
      '${imported.size ~/ 1024}KB  ${imported.mime}  '
      '缩略图=${imported.thumbHash != null}',
    );
    await db.close();
  });
}
