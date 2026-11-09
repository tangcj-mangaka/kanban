import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';

enum BoardView {
  canvas('画布', Icons.dashboard_outlined),
  grouped('分组', Icons.view_column_outlined),
  timeline('时间轴', Icons.view_timeline_outlined),
  haystack('干草仓库', Icons.inventory_2_outlined);

  final String label;
  final IconData icon;

  const BoardView(this.label, this.icon);

  /// 能当「落脚点」的视图。
  ///
  /// 只有画布和分组算。时间轴和干草仓库是去看一眼就回来的地方——把它们
  /// 也记下来的话，去仓库里翻一次东西，之后每块板打开都落在仓库里，
  /// 像是坏了。
  bool get isHome => this == BoardView.canvas || this == BoardView.grouped;
}

/// 上次用的那个视图，下次打开看板就停在这儿。
///
/// 存在本机的设置表里，**不进 op 日志**，所以不会同步到别的设备——
/// 和主题一样，这是「这台机器」的习惯。手机上几乎只用分组，电脑上
/// 可能更常用画布，各记各的正好。
///
/// 和主题那边一个毛病、一个解法：读盘是异步的，而 build 必须同步返回。
/// 所以先给 null（让调用方按屏幕宽度走老规矩），读到了再覆盖。为了不让
/// 用户点进看板的那一刻才开始读，启动时就 watch 一次（见 bootstrap）。
class BoardViewNotifier extends Notifier<BoardView?> {
  static const _key = 'board_view';

  /// 用户是否已经自己切过视图。
  ///
  /// 读盘回来得晚的话，会把用户刚选的那个覆盖掉——看着就像点了没反应。
  bool _touched = false;

  @override
  BoardView? build() {
    _load();
    return null;
  }

  Future<void> _load() async {
    final saved = await ref.read(databaseProvider).getSetting(_key);
    if (_touched) return;
    final view = BoardView.values.asNameMap()[saved];
    if (view != null && view.isHome) state = view;
  }

  /// 记下用户刚切到的视图。非落脚点的视图直接忽略。
  void remember(BoardView view) {
    if (!view.isHome) return;
    _touched = true;
    if (state == view) return;
    state = view;
    // 存盘失败不该拦着用户切视图，所以不 await。
    ref.read(databaseProvider).setSetting(_key, view.name);
  }
}

final boardViewProvider = NotifierProvider<BoardViewNotifier, BoardView?>(
  BoardViewNotifier.new,
);
