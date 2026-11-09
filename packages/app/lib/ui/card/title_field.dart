import 'dart:async';

import 'package:flutter/material.dart';

/// 标题输入框，自己负责存盘。
///
/// 和正文编辑器 [MarkdownEditor] 用的是同一套规矩：停手半秒提交一次、
/// 失焦提交、销毁时把没提交的补上。标题以前只在回车和 `onTapOutside`
/// 时提交，结果是**改完标题去点正文，改动就没了**。
///
/// 原因是 Flutter 的 `onTapOutside`：所有 TextField 默认都在同一个
/// `TapRegion` 组里（groupId 就是 `EditableText`），所以从一个输入框点进
/// 另一个输入框**不算点到了外面**，回调压根不触发。这个坑光看代码看不
/// 出来——`onTapOutside` 这个名字写着「点到外面」，而点正文确确实实是
/// 点到了标题外面。
///
/// 所以这里不靠那个回调，改成盯焦点：焦点一离开就提交，谁拿走的无所谓。
class TitleField extends StatefulWidget {
  /// 打开时的标题。只在第一次建这个组件时用，之后输入框自己拿着内容——
  /// 否则别处的改动触发重建时，光标会被弹回开头。
  final String initialValue;

  /// 停手一段时间后、失焦时、或关闭时回调。给的是 trim 过的文字。
  final ValueChanged<String> onChanged;

  final TextStyle? style;
  final String hintText;

  const TitleField({
    super.key,
    required this.initialValue,
    required this.onChanged,
    this.style,
    this.hintText = '卡片标题',
  });

  @override
  State<TitleField> createState() => _TitleFieldState();
}

class _TitleFieldState extends State<TitleField> {
  late final TextEditingController _controller;
  final _focus = FocusNode();
  Timer? _debounce;

  /// 最后一次真的写出去的标题。
  ///
  /// 拿它和当前文字比，而不是和 `widget.initialValue` 比：否则连着改两次
  /// 的第二次会被当成「和初始值不同」反复提交同样的内容。
  late String _saved;

  static const _debounceDelay = Duration(milliseconds: 500);

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
    _saved = widget.initialValue.trim();
    _focus.addListener(() {
      if (!_focus.hasFocus) _flush();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    // 兜底：点到弹窗外面时，遮罩会直接把弹窗弹掉，没有失焦这一步。
    _flush();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(_debounceDelay, _flush);
  }

  void _flush() {
    _debounce?.cancel();
    final text = _controller.text.trim();
    // 没动过就什么都不做。每开一次详情就写一条标题 op 的话，改动记录会被
    // 没改过的东西刷屏，还白白制造一次跨设备同步。
    if (text == _saved) return;
    _saved = text;
    widget.onChanged(text);
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: _focus,
      style: widget.style,
      decoration: InputDecoration(
        isDense: true,
        border: InputBorder.none,
        hintText: widget.hintText,
      ),
      onChanged: _onChanged,
      onSubmitted: (_) => _flush(),
    );
  }
}
