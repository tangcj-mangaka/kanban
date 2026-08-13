import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// 把数据目录打包成一个 zip，放在同一个目录下。
///
/// 备份和数据放在一起看起来有点傻（磁盘坏了就一起没了），但它防的是另一类
/// 事故：误删看板、清空干草仓库、同步把内容覆盖掉。这些比磁盘故障常见得多。
/// 真要防硬件故障，把这个 zip 拷走就是了。
Future<File> createBackup(String dataDir) async {
  final dir = Directory(dataDir);
  if (!dir.existsSync()) {
    throw StateError('数据目录不存在：$dataDir');
  }

  final archive = Archive();
  await for (final entity in dir.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final name = p.relative(entity.path, from: dataDir);

    // 不要把旧备份套进新备份里——否则每备份一次体积就翻一倍。
    if (name.startsWith('backup-') && name.endsWith('.zip')) continue;
    // WAL 和临时文件属于运行时状态，恢复时不需要，带上反而可能不一致。
    if (name.endsWith('-wal') || name.endsWith('-shm') || name.endsWith('-journal')) {
      continue;
    }
    if (name.endsWith('.vbs')) continue;

    archive.addFile(ArchiveFile(name, entity.lengthSync(), entity.readAsBytesSync()));
  }

  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final stamp =
      '${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}';
  final out = File(p.join(dataDir, 'backup-$stamp.zip'));

  final bytes = ZipEncoder().encode(archive);
  await out.writeAsBytes(bytes);
  return out;
}

/// 只留最近 [keep] 份备份，其余删掉。
///
/// 不限量的话，每天一次的自动备份迟早把磁盘填满，而超过一定年份的备份
/// 对个人看板也没什么用。
Future<int> pruneBackups(String dataDir, {int keep = 7}) async {
  final dir = Directory(dataDir);
  if (!dir.existsSync()) return 0;

  final backups = dir
      .listSync()
      .whereType<File>()
      .where((f) {
        final name = p.basename(f.path);
        return name.startsWith('backup-') && name.endsWith('.zip');
      })
      .toList()
    ..sort((a, b) => b.path.compareTo(a.path)); // 文件名带时间戳，逆序即最新在前

  var removed = 0;
  for (final old in backups.skip(keep)) {
    await old.delete();
    removed++;
  }
  return removed;
}
