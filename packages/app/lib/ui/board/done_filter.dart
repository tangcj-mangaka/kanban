import 'package:collection/collection.dart';

/// 按「完成」状态筛选卡片。
///
/// 和排序是**两个维度**：排序决定顺序，筛选决定看不看得见。所以它是独立的
/// 一个开关，不是塞进排序菜单里的第五个选项——那样选了「已完成」就等于
/// 放弃了排序方式。
enum DoneFilter {
  all('全部'),
  todo('未完成'),
  done('已完成');

  final String label;

  const DoneFilter(this.label);

  /// 这张卡片过不过得了这道筛选。
  bool accepts({required bool cardIsDone}) => switch (this) {
    DoneFilter.all => true,
    DoneFilter.todo => !cardIsDone,
    DoneFilter.done => cardIsDone,
  };

  /// 点一下切到下一个状态：全部 → 未完成 → 已完成 → 全部。
  DoneFilter get next => switch (this) {
    DoneFilter.all => DoneFilter.todo,
    DoneFilter.todo => DoneFilter.done,
    DoneFilter.done => DoneFilter.all,
  };

  static DoneFilter parse(String? name) =>
      DoneFilter.values.where((f) => f.name == name).firstOrNull ??
      DoneFilter.all;
}
