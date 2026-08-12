import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../../sync/sync_client.dart';
import '../theme/app_theme.dart';
import 'sync_settings_dialog.dart';

/// 同步状态指示器。
///
/// 常驻在看板列表页顶栏——用户任何时候都该一眼看出自己现在是不是离线在用。
/// 但**离线不是错误**：本地优先架构下离线照常增删改查，所以离线态用中性色，
/// 不用警示色，免得把正常状态渲染成出事了。
class SyncStatusChip extends ConsumerWidget {
  const SyncStatusChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final k = theme.kanban;
    final state = ref.watch(syncStateProvider).value ?? const SyncState();

    final (color, label) = switch (state.status) {
      SyncStatus.disabled => (k.cardBody, '本地模式'),
      SyncStatus.offline => (k.cardBody, '离线'),
      SyncStatus.connecting => (k.cardBody, '连接中'),
      SyncStatus.online => (const Color(0xFF1F9D51), '已同步'),
      SyncStatus.syncing => (
        theme.colorScheme.primary,
        '同步中 ${state.pending}',
      ),
    };

    return Tooltip(
      message: switch (state.status) {
        SyncStatus.disabled => '还没连服务器。点这里设置',
        SyncStatus.offline => state.error ?? '连不上服务器。改动会攒着，连上自动补发',
        SyncStatus.connecting => '正在连接服务器',
        SyncStatus.online => '和服务器保持着连接',
        SyncStatus.syncing => '还有 ${state.pending} 条改动在路上',
      },
      child: InkWell(
        onTap: () => showSyncSettings(context),
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          decoration: BoxDecoration(
            color: k.hairline.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Dot(color: color, pulsing: state.status == SyncStatus.syncing),
              const SizedBox(width: 6),
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(color: k.cardBody),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 同步中时轻微脉动。不做转圈菊花——那个太吵，而且暗示用户得等着。
class _Dot extends StatefulWidget {
  final Color color;
  final bool pulsing;

  const _Dot({required this.color, required this.pulsing});

  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.pulsing) _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_Dot old) {
    super.didUpdateWidget(old);
    if (widget.pulsing && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.pulsing && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Opacity(
        opacity: widget.pulsing ? 0.45 + _controller.value * 0.55 : 1,
        child: Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: widget.color,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}
