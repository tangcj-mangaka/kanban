import 'package:flutter/material.dart';

import 'theme/app_theme.dart';

/// 卡片标题左边的完成勾。
///
/// 自己画而不是用 Material 的 [Checkbox]：那个自带 48×48 的触摸区和涟漪，
/// 塞进卡片标题行会把整行撑高一大截——而卡片在画布上是按内容收紧的，
/// 多出来的空白很显眼。
///
/// 画布和分组视图共用这一个，两边的勾必须长得一模一样：同一张卡片在两个
/// 视图里换个样子，会让人怀疑是不是两个不同的状态。
class DoneBox extends StatelessWidget {
  final bool done;
  final VoidCallback onTap;

  const DoneBox({super.key, required this.done, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final k = Theme.of(context).kanban;

    return GestureDetector(
      onTap: onTap,
      // opaque：连同四周的 padding 一起接收点击，手机上才点得中。
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.only(top: 2, right: 2, bottom: 4),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 130),
          width: 15,
          height: 15,
          decoration: BoxDecoration(
            color: done ? k.doneBorder.withValues(alpha: 1.0) : null,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: done
                  ? Colors.transparent
                  : k.cardBody.withValues(alpha: 0.45),
              width: 1.5,
            ),
          ),
          child: done
              ? Icon(
                  Icons.check,
                  size: 11,
                  color: k.isDark ? Colors.black87 : Colors.white,
                )
              : null,
        ),
      ),
    );
  }
}
