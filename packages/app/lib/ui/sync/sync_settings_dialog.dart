import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import 'package:shared/shared.dart';

import '../../sync/discovery_listener.dart';
import '../../sync/sync_client.dart';
import '../responsive.dart';
import '../theme/app_theme.dart';

Future<void> showSyncSettings(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _SyncSettingsDialog(),
  );
}

class _SyncSettingsDialog extends ConsumerStatefulWidget {
  const _SyncSettingsDialog();

  @override
  ConsumerState<_SyncSettingsDialog> createState() =>
      _SyncSettingsDialogState();
}

class _SyncSettingsDialogState extends ConsumerState<_SyncSettingsDialog> {
  final _hostController = TextEditingController();
  final _portController = TextEditingController(text: '8765');
  final _codeController = TextEditingController();
  final _nameController = TextEditingController();
  final _linkController = TextEditingController();
  bool _loaded = false;
  bool _connecting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = ref.read(databaseProvider);
    _hostController.text = await db.getSetting(SyncKeys.host) ?? '';
    _portController.text = '${await db.getIntSetting(SyncKeys.port, fallback: 8765)}';
    _nameController.text =
        await db.getSetting(SyncKeys.deviceName) ?? defaultDeviceName();
    if (mounted) setState(() => _loaded = true);
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _codeController.dispose();
    _nameController.dispose();
    _linkController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final k = theme.kanban;
    final state = ref.watch(syncStateProvider).value ?? const SyncState();
    final paired =
        state.status != SyncStatus.disabled && _hostController.text.isNotEmpty;

    return AlertDialog(
      title: Row(
        children: [
          const Text('局域网同步'),
          const Spacer(),
          // 版本号：版本对不上是同步出问题的常见原因之一，而这个弹窗
          // 正是出问题时会打开的地方。
          //
          // **放在标题行而不是 actions 里。** actions 用的是 OverflowBar，
          // 不是 Flex，而 Spacer 本质是 Expanded——放进去调试版断言失败、
          // 发布版直接抛类型错误，整个弹窗内容会被换成一个灰色方块。
          // 这里的 Row 是货真价实的 Flex，Spacer 才合法。
          Text(
            '版本 $kAppVersion',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.kanban.cardBody.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: dialogWidth(context, 420),
        child: !_loaded
            ? const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              )
            // 内容比一屏高，尤其发现到多台服务端时。不给滚动就会溢出。
            : SingleChildScrollView(
                child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _StatusLine(state: state),
                  const SizedBox(height: 18),
                  _DiscoveredServers(onPick: _fill),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _linkController,
                          decoration: const InputDecoration(
                            hintText: '或粘贴连接链接 kanban://connect?...',
                            isDense: true,
                          ),
                          onChanged: _onLinkChanged,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Text(
                    '服务器地址',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: k.cardBody,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: TextField(
                          controller: _hostController,
                          decoration: const InputDecoration(
                            hintText: '192.168.1.23',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _portController,
                          keyboardType: TextInputType.number,
                          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                          decoration: const InputDecoration(hintText: '8765'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    paired ? '配对码（换服务器或重新配对时才需要）' : '配对码',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: k.cardBody,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _codeController,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      hintText: '服务端启动时会显示 6 位配对码',
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    '本机名称',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: k.cardBody,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      hintText: '别的设备上会看到这个名字',
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(11),
                    decoration: BoxDecoration(
                      color: k.hairline.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '连不上不影响使用。所有改动会先存在本机，'
                      '等服务器回来自动补发——离线是正常状态，不是故障。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: k.cardBody,
                        height: 1.55,
                      ),
                    ),
                  ),
                ],
              ),
              ),
      ),
      actions: [
        if (paired)
          TextButton(
            onPressed: _forget,
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
            ),
            child: const Text('断开并忘记'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        FilledButton(
          onPressed: _connecting ? null : _connect,
          child: Text(_connecting ? '连接中…' : '连接'),
        ),
      ],
    );
  }

  /// 用户选了一台发现到的服务端，或粘贴了链接。
  void _fill(String host, int port, {String? code}) {
    setState(() {
      _hostController.text = host;
      _portController.text = '$port';
      if (code != null) _codeController.text = code;
    });
  }

  /// 粘贴链接时即时解析。解析不出来就当没粘——用户可能只是粘错了东西，
  /// 不该弹错误框骂他。
  void _onLinkChanged(String raw) {
    final link = ConnectLink.parse(raw);
    if (link == null) return;
    _fill(link.host, link.port, code: link.code);
    _linkController.clear();
  }

  Future<void> _connect() async {
    final host = _hostController.text.trim();
    if (host.isEmpty) return;

    setState(() => _connecting = true);
    final client = ref.read(syncClientProvider);
    await client.setDeviceName(_nameController.text.trim());
    final code = _codeController.text.trim();
    await client.configure(
      host: host,
      port: int.tryParse(_portController.text.trim()) ?? 8765,
      pairCode: code.isEmpty ? null : code.toUpperCase(),
    );
    _codeController.clear();
    if (mounted) setState(() => _connecting = false);
  }

  Future<void> _forget() async {
    await ref.read(syncClientProvider).forgetServer();
    _hostController.clear();
    if (mounted) setState(() {});
  }
}

class _StatusLine extends StatelessWidget {
  final SyncState state;

  const _StatusLine({required this.state});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final k = theme.kanban;

    final detail = switch (state.status) {
      SyncStatus.disabled => '还没连服务器，改动只存在本机',
      SyncStatus.offline => state.error ?? '连不上，改动攒在本机等着补发',
      SyncStatus.connecting => '正在连接…',
      SyncStatus.online => '一切同步完毕',
      SyncStatus.syncing => '还有 ${state.pending} 条改动在路上',
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      decoration: BoxDecoration(
        color: k.hairline.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: switch (state.status) {
                SyncStatus.online => const Color(0xFF1F9D51),
                SyncStatus.syncing => theme.colorScheme.primary,
                _ => k.cardBody,
              },
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  state.status.label,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  detail,
                  style: theme.textTheme.bodySmall?.copyWith(color: k.cardBody),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}


/// 局域网里自动发现的服务端。
class _DiscoveredServers extends ConsumerWidget {
  final void Function(String host, int port) onPick;

  const _DiscoveredServers({required this.onPick});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final k = theme.kanban;
    final async = ref.watch(discoveredServersProvider);
    final servers = async.value ?? const <DiscoveredServer>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              '局域网里的服务端',
              style: theme.textTheme.labelLarge?.copyWith(color: k.cardBody),
            ),
            const SizedBox(width: 8),
            if (servers.isEmpty)
              SizedBox(
                width: 11,
                height: 11,
                child: CircularProgressIndicator(
                  strokeWidth: 1.6,
                  color: k.cardBody.withValues(alpha: 0.6),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (servers.isEmpty)
          Text(
            '正在搜索。找不到也没关系，下面手动填地址一样能连。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: k.cardBody.withValues(alpha: 0.8),
            ),
          )
        else
          for (final server in servers)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Material(
                color: k.hairline.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  onTap: () => onPick(server.host, server.port),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 9,
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.dns_outlined, size: 16, color: k.cardBody),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                server.name,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              Text(
                                '${server.host}:${server.port}',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: k.cardBody,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          '选它',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
      ],
    );
  }
}
