import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repository.dart';
import '../../providers.dart';
import '../responsive.dart';
import '../theme/app_theme.dart';
import 'board_cover.dart';
import 'board_dialogs.dart';
import 'board_list_page.dart';

/// 「改封面」：颜色和背景图在同一个对话框里调。
///
/// 合在一起是因为这两样本来就是叠着看的——面色在底下，图盖在上面。
/// 分成两个入口的话，每调一次都得来回开两次才知道配出来什么样。
///
/// 中间那块是**一块真的看板方块**（[BoardTile]，同一个组件），带着这块板
/// 真实的名字、标签、张数和超时角标。所以这里看清楚了，列表页就看得清楚；
/// 字会不会被图吃掉，当场就知道，不用我替用户定一个「安全」的浓度。
Future<void> showBoardCoverDialog(
  BuildContext context,
  WidgetRef ref,
  BoardSummary summary,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => _BoardCoverDialog(summary: summary),
  );
}

class _BoardCoverDialog extends ConsumerStatefulWidget {
  final BoardSummary summary;

  const _BoardCoverDialog({required this.summary});

  @override
  ConsumerState<_BoardCoverDialog> createState() => _BoardCoverDialogState();
}

class _BoardCoverDialogState extends ConsumerState<_BoardCoverDialog> {
  /// 预览方块的尺寸。和列表页网格里的一块对齐（260 宽、1.75 比例）。
  static const double _previewWidth = 260;
  static const double _previewHeight = _previewWidth / 1.75;

  late String? _color = widget.summary.board.color;
  late BoardCoverSpec _cover = BoardCoverSpec.fromBoard(widget.summary.board);

  bool _busy = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final k = Theme.of(context).kanban;

    return AlertDialog(
      title: const Text('改封面'),
      content: SizedBox(
        width: dialogWidth(context, 380),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(child: _preview()),
              const SizedBox(height: 6),
              Center(
                child: Text(
                  _cover.isEmpty ? '还没有背景图' : '在图上拖动，挪到想要的位置',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: k.cardBody.withValues(alpha: 0.7),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // 背景图排在面色前面：面色是老功能，位置闭着眼都摸得到；
              // 「选一张图」是这次新加的，它要是落到一屏之外，这个功能
              // 就等于没做——色板有三行高，排在前面正好把它顶下去。
              _label('背景图'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _pickImage,
                    icon: const Icon(Icons.image_outlined, size: 17),
                    label: Text(_cover.isEmpty ? '选一张图' : '换一张'),
                  ),
                  if (!_cover.isEmpty)
                    TextButton.icon(
                      onPressed: _busy ? null : _removeImage,
                      icon: const Icon(Icons.format_color_reset_outlined,
                          size: 17),
                      label: const Text('去掉图片'),
                    ),
                ],
              ),

              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],

              if (!_cover.isEmpty) ...[
                const SizedBox(height: 12),
                _slider(
                  icon: Icons.opacity,
                  label: '浓淡',
                  value: _cover.opacity,
                  min: kCoverOpacityMin,
                  max: kCoverOpacityMax,
                  display: '${(_cover.opacity * 100).round()}%',
                  onChanged: (v) =>
                      setState(() => _cover = _cover.copyWith(opacity: v)),
                ),
                _slider(
                  icon: Icons.zoom_in,
                  label: '放大',
                  value: _cover.scale,
                  min: kCoverScaleMin,
                  max: kCoverScaleMax,
                  display: '${_cover.scale.toStringAsFixed(1)}×',
                  onChanged: (v) =>
                      setState(() => _cover = _cover.copyWith(scale: v)),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '拖不动说明这张图正好填满、没有多余的部分，放大一点就能挪了。'
                    '手机上方块更扁，裁出来的是另一块，这里存的是「对准哪个点」，'
                    '两边各自算。',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: k.cardBody.withValues(alpha: 0.65),
                      height: 1.4,
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 18),
              _label('面色'),
              const SizedBox(height: 8),
              SwatchGrid(
                current: _color,
                onPick: (key) => setState(() => _color = key),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: const Text('保存'),
        ),
      ],
    );
  }

  Widget _label(String text) => Text(
    text,
    style: Theme.of(context).textTheme.labelLarge?.copyWith(
      color: Theme.of(context).kanban.cardTitle,
      fontWeight: FontWeight.w600,
    ),
  );

  /// 中间那块真方块。拖它就是挪焦点。
  Widget _preview() {
    // 预览里的看板行拿草稿值替换掉真实值——同一个组件，喂的是还没落库的
    // 那份设置。
    final draft = widget.summary.board.copyWith(
      color: Value(_color),
      coverHash: Value(_cover.hash),
      coverThumbHash: Value(_cover.thumbHash),
      coverOpacity: _cover.opacity,
      coverFocalX: _cover.focalX,
      coverFocalY: _cover.focalY,
      coverScale: _cover.scale,
    );

    final tile = BoardTile(
      // 草稿一变就换 key，省得旧状态（悬停之类）粘在上面。
      key: ValueKey('${_color}_${_cover.hash}'),
      summary: BoardSummary(
        board: draft,
        cardCount: widget.summary.cardCount,
        lastUpdated: widget.summary.lastUpdated,
      ),
      preview: true,
    );

    return SizedBox(
      width: _previewWidth,
      height: _previewHeight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: _cover.isEmpty ? null : _dragFocal,
        child: MouseRegion(
          cursor: _cover.isEmpty
              ? MouseCursor.defer
              : SystemMouseCursors.move,
          child: tile,
        ),
      ),
    );
  }

  /// 拖动换焦点。半块方块的距离 = 从中间走到边。
  void _dragFocal(DragUpdateDetails d) {
    setState(() {
      _cover = _cover.copyWith(
        focalX: (_cover.focalX - 2 * d.delta.dx / _previewWidth)
            .clamp(-1.0, 1.0),
        focalY: (_cover.focalY - 2 * d.delta.dy / _previewHeight)
            .clamp(-1.0, 1.0),
      );
    });
  }

  Widget _slider({
    required IconData icon,
    required String label,
    required double value,
    required double min,
    required double max,
    required String display,
    required ValueChanged<double> onChanged,
  }) {
    final k = Theme.of(context).kanban;
    return Row(
      children: [
        Icon(icon, size: 17, color: k.cardBody),
        const SizedBox(width: 6),
        SizedBox(
          width: 32,
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: k.cardBody,
            ),
          ),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 40,
          child: Text(
            display,
            textAlign: TextAlign.right,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: k.cardBody,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _pickImage() async {
    final picked = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: '图片',
          extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'],
        ),
      ],
    );
    if (picked == null) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    // 导入会解码整张图再压缩，大图能卡住一帧以上，所以按钮先禁用。
    final imported = await ref
        .read(attachmentStoreProvider)
        .importCoverImage(File(picked.path), displayName: picked.name);

    if (!mounted) return;
    if (imported == null) {
      setState(() {
        _busy = false;
        _error = '这张图打不开，换一张试试（支持 PNG / JPG / GIF / WebP / BMP）';
      });
      return;
    }

    setState(() {
      _busy = false;
      // 换图就把位置重置：上一张图调好的焦点，换到新图上基本是乱的。
      _cover = BoardCoverSpec(
        hash: imported.hash,
        thumbHash: imported.thumbHash,
        opacity: _cover.opacity,
      );
    });
  }

  void _removeImage() => setState(() => _cover = BoardCoverSpec.none);

  Future<void> _save() async {
    setState(() => _busy = true);
    final repo = ref.read(repositoryProvider);
    final id = widget.summary.board.id;

    if (_color != widget.summary.board.color) {
      await repo.setBoardColor(id, _color);
    }
    await repo.setBoardCover(
      id,
      hash: _cover.hash,
      thumbHash: _cover.thumbHash,
      opacity: _cover.opacity,
      focalX: _cover.focalX,
      focalY: _cover.focalY,
      scale: _cover.scale,
    );

    // 顺手推一把，让别的设备早点看到这张图。连不上也无所谓，在队列里等着。
    unawaited(ref.read(attachmentSyncerProvider).flush());

    if (mounted) Navigator.pop(context);
  }
}
