import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../theme/app_theme.dart';

/// 正文编辑器。
///
/// 存的是 Markdown 源文——就是一个字符串，同步时不需要任何特殊处理。
/// 不做富文本编辑器：那些包在 Flutter 上体验参差，而且存的是一大坨结构化
/// JSON，整个文档挤在一个字段里，和字段级 LWW 配合很差（覆盖粒度太粗）。
///
/// 工具栏点一下自动插标记，所以不会 Markdown 的人也能用。
class MarkdownEditor extends StatefulWidget {
  final String initialValue;

  /// 停止输入一段时间后、或失焦时回调，不是每敲一个字符都回调。
  final ValueChanged<String> onChanged;

  const MarkdownEditor({
    super.key,
    required this.initialValue,
    required this.onChanged,
  });

  @override
  State<MarkdownEditor> createState() => _MarkdownEditorState();
}

class _MarkdownEditorState extends State<MarkdownEditor> {
  late final TextEditingController _controller;
  final _focus = FocusNode();
  Timer? _debounce;
  bool _preview = false;

  /// 打字时不是每个字符都提交一次 op，停手 [_debounceDelay] 才提交。
  static const _debounceDelay = Duration(milliseconds: 500);

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
    _focus.addListener(() {
      if (!_focus.hasFocus) _flush();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    // 关闭时把还没提交的内容补上，否则最后 500ms 内敲的字会丢。
    if (_controller.text != widget.initialValue) {
      widget.onChanged(_controller.text);
    }
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onTextChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(_debounceDelay, () => widget.onChanged(value));
  }

  void _flush() {
    _debounce?.cancel();
    widget.onChanged(_controller.text);
  }

  /// 在选区两侧插标记；没选中内容就插一对标记并把光标放中间。
  void _wrap(String left, [String? right]) {
    final close = right ?? left;
    final sel = _controller.selection;
    final text = _controller.text;
    if (!sel.isValid) return;

    final selected = sel.textInside(text);
    final replaced = '$left$selected$close';
    _controller.value = _controller.value.copyWith(
      text: sel.textBefore(text) + replaced + sel.textAfter(text),
      selection: TextSelection(
        baseOffset: sel.start + left.length,
        extentOffset: sel.start + left.length + selected.length,
      ),
    );
    _onTextChanged(_controller.text);
    _focus.requestFocus();
  }

  /// 在当前行首插前缀，用于列表和引用。
  void _prefixLine(String prefix) {
    final sel = _controller.selection;
    final text = _controller.text;
    if (!sel.isValid) return;

    final lineStart = text.lastIndexOf('\n', sel.start - 1) + 1;
    _controller.value = _controller.value.copyWith(
      text: text.replaceRange(lineStart, lineStart, prefix),
      selection: TextSelection.collapsed(offset: sel.start + prefix.length),
    );
    _onTextChanged(_controller.text);
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final k = theme.kanban;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              '正文',
              style: theme.textTheme.labelLarge?.copyWith(color: k.cardBody),
            ),
            const SizedBox(width: 14),
            if (!_preview) ...[
              _ToolbarButton(
                icon: Icons.format_bold,
                tooltip: '加粗',
                onTap: () => _wrap('**'),
              ),
              _ToolbarButton(
                icon: Icons.format_italic,
                tooltip: '斜体',
                onTap: () => _wrap('*'),
              ),
              _ToolbarButton(
                icon: Icons.format_list_bulleted,
                tooltip: '列表',
                onTap: () => _prefixLine('- '),
              ),
              _ToolbarButton(
                icon: Icons.checklist,
                tooltip: '待办项',
                onTap: () => _prefixLine('- [ ] '),
              ),
              _ToolbarButton(
                icon: Icons.code,
                tooltip: '行内代码',
                onTap: () => _wrap('`'),
              ),
              _ToolbarButton(
                icon: Icons.format_quote,
                tooltip: '引用',
                onTap: () => _prefixLine('> '),
              ),
            ],
            const Spacer(),
            SegmentedButton<bool>(
              showSelectedIcon: false,
              style: SegmentedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                textStyle: theme.textTheme.labelSmall,
              ),
              segments: const [
                ButtonSegment(value: false, label: Text('编辑')),
                ButtonSegment(value: true, label: Text('预览')),
              ],
              selected: {_preview},
              onSelectionChanged: (s) {
                // 切到预览前先把内容提交，否则预览的是旧内容。
                if (s.first) _flush();
                setState(() => _preview = s.first);
              },
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: k.hairline),
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: _preview ? _buildPreview(theme, k) : _buildEditor(theme, k),
          ),
        ),
      ],
    );
  }

  Widget _buildEditor(ThemeData theme, KanbanColors k) {
    return TextField(
      controller: _controller,
      focusNode: _focus,
      maxLines: null,
      expands: true,
      textAlignVertical: TextAlignVertical.top,
      onChanged: _onTextChanged,
      style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
      decoration: InputDecoration(
        isDense: true,
        border: InputBorder.none,
        hintText: '写点什么。支持 Markdown——**加粗**、- 列表、`代码`',
        hintStyle: theme.textTheme.bodyMedium?.copyWith(
          color: k.cardBody.withValues(alpha: 0.6),
        ),
      ),
    );
  }

  Widget _buildPreview(ThemeData theme, KanbanColors k) {
    if (_controller.text.trim().isEmpty) {
      return Text(
        '还没有正文',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: k.cardBody.withValues(alpha: 0.6),
        ),
      );
    }
    return Markdown(
      data: _controller.text,
      padding: EdgeInsets.zero,
      selectable: true,
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        p: theme.textTheme.bodyMedium?.copyWith(height: 1.65),
        code: theme.textTheme.bodySmall?.copyWith(
          fontFamily: 'monospace',
          backgroundColor: k.hairline.withValues(alpha: 0.5),
        ),
        codeblockDecoration: BoxDecoration(
          color: k.hairline.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(6),
        ),
        blockquoteDecoration: BoxDecoration(
          border: Border(left: BorderSide(color: k.hairline, width: 3)),
        ),
      ),
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _ToolbarButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(5),
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Icon(
            icon,
            size: 17,
            color: Theme.of(context).kanban.cardBody,
          ),
        ),
      ),
    );
  }
}
