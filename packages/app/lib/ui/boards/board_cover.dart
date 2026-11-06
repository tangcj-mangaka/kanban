import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database.dart';
import '../../data/repository.dart';
import '../../providers.dart';
import '../theme/app_theme.dart';

/// 一块看板的封面图设置：图是哪张、盖多浓、裁哪一块。
///
/// 单拎出来是因为编辑对话框要拿着一份**还没落库**的草稿去预览——预览
/// 用的是和真方块完全同一个绘制组件，所见即所得靠的就是这个。
@immutable
class BoardCoverSpec {
  final String? hash;
  final String? thumbHash;
  final double opacity;
  final double focalX;
  final double focalY;
  final double scale;

  const BoardCoverSpec({
    this.hash,
    this.thumbHash,
    this.opacity = kCoverOpacityDefault,
    this.focalX = 0,
    this.focalY = 0,
    this.scale = 1,
  });

  static const none = BoardCoverSpec();

  factory BoardCoverSpec.fromBoard(BoardRow board) => BoardCoverSpec(
    hash: board.coverHash,
    thumbHash: board.coverThumbHash,
    opacity: board.coverOpacity,
    focalX: board.coverFocalX,
    focalY: board.coverFocalY,
    scale: board.coverScale,
  );

  bool get isEmpty => hash == null;

  BoardCoverSpec copyWith({
    String? hash,
    String? thumbHash,
    double? opacity,
    double? focalX,
    double? focalY,
    double? scale,
  }) => BoardCoverSpec(
    hash: hash ?? this.hash,
    thumbHash: thumbHash ?? this.thumbHash,
    opacity: opacity ?? this.opacity,
    focalX: focalX ?? this.focalX,
    focalY: focalY ?? this.focalY,
    scale: scale ?? this.scale,
  );
}

/// 封面图的字节。
///
/// 按哈希缓存，不用 `FutureBuilder`——方块每次悬停都会重建，用
/// `FutureBuilder` 的话每重建一次就重新取一次文件，鼠标扫过列表就是
/// 几十次磁盘读。这里一个哈希只取一次，九块看板就是九次。
///
/// 不加 autoDispose：数量上限就是看板数，常驻着比反复取划算。
final coverBytesProvider = FutureProvider.family<Uint8List?, String>(
  (ref, hash) => ref.read(attachmentSyncerProvider).fetch(hash),
);

/// 铺在看板方块底下的背景图。
///
/// 图还没下下来（手机上刚同步过来的看板）就什么都不画——方块照常是纯
/// 面色，不转圈、不占位、不报错。看不到一张装饰图不该惊动任何人。
class BoardCoverLayer extends ConsumerWidget {
  final BoardCoverSpec spec;

  const BoardCoverLayer({super.key, required this.spec});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hash = spec.hash;
    if (hash == null) return const SizedBox.shrink();

    // 大图和缩略图同时取：缩略图几乎总在本地，先顶上，大图到了再换。
    final full = ref.watch(coverBytesProvider(hash)).value;
    final thumb = spec.thumbHash == null
        ? null
        : ref.watch(coverBytesProvider(spec.thumbHash!)).value;

    final bytes = full ?? thumb;
    if (bytes == null) return const SizedBox.shrink();

    return BoardCoverPaint(bytes: bytes, spec: spec);
  }
}

/// 把一张图按 [BoardCoverSpec] 画进当前这块地方。
///
/// 独立于取字节这一步，所以编辑对话框可以拿着内存里的字节直接预览。
class BoardCoverPaint extends StatelessWidget {
  final Uint8List bytes;
  final BoardCoverSpec spec;

  const BoardCoverPaint({
    super.key,
    required this.bytes,
    required this.spec,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).kanban.isDark;

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        if (w <= 0 || h <= 0 || !w.isFinite || !h.isFinite) {
          return const SizedBox.shrink();
        }

        final z = spec.scale.clamp(kCoverScaleMin, kCoverScaleMax);
        final fx = spec.focalX.clamp(-1.0, 1.0);
        final fy = spec.focalY.clamp(-1.0, 1.0);

        // 两段裁切叠在一起，都由同一对焦点驱动：
        //
        // 1. `BoxFit.cover` + alignment —— 图的长宽比和方块不一样时，多出来
        //    的那条边裁掉，焦点决定留哪一段。这一段自带夹紧，焦点再怎么
        //    推也不会露出空边。
        // 2. 放大之后多出来的部分 —— 把放大的画布平移回来一点。
        //
        // 所以图和方块比例一模一样时，第一段没得可裁（横竖都不溢出），
        // 这时想挪就得先放大，第二段才有行程。这符合直觉：填满且比例相同，
        // 本来就没有「别的部分」可看。
        final dx = -fx * w * (z - 1) / 2;
        final dy = -fy * h * (z - 1) / 2;

        return ClipRect(
          child: Opacity(
            // 深色模式下再压一道：一张亮图哪怕只有两成，盖在深色方块上
            // 也足够把白字冲淡。
            opacity: (spec.opacity * (dark ? 0.6 : 1.0)).clamp(0.0, 1.0),
            child: ColorFiltered(
              // 去掉一半饱和度。用户挑的图往往比他以为的鲜艳，
              // 褪一道之后整页看板才不会花。
              colorFilter: const ColorFilter.matrix(_halfSaturation),
              child: OverflowBox(
                maxWidth: w * z,
                maxHeight: h * z,
                child: Transform.translate(
                  offset: Offset(dx, dy),
                  child: SizedBox(
                    width: w * z,
                    height: h * z,
                    child: Image.memory(
                      bytes,
                      fit: BoxFit.cover,
                      alignment: Alignment(fx, fy),
                      gaplessPlayback: true,
                      filterQuality: FilterQuality.medium,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 饱和度降到 50% 的颜色矩阵。
///
/// 系数是 Rec. 709 的亮度权重（0.2126 / 0.7152 / 0.0722）：保留亮度不变，
/// 只把颜色往灰里拉一半。
/// 直接写成常量而不是算出来，省得每帧构造一个 20 个元素的列表。
const List<double> _halfSaturation = <double>[
  0.6065, 0.3575, 0.0360, 0, 0, //
  0.1065, 0.8575, 0.0360, 0, 0, //
  0.1065, 0.3575, 0.5360, 0, 0, //
  0, 0, 0, 1, 0, //
];
