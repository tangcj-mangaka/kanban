import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:server/src/backup.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('kanban-backup-test'));
  tearDown(() => dir.deleteSync(recursive: true));

  File write(String name, String content) {
    final f = File(p.join(dir.path, name))
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
    return f;
  }

  List<String> namesIn(File zip) =>
      ZipDecoder().decodeBytes(zip.readAsBytesSync()).files.map((f) => f.name).toList();

  group('创建备份', () {
    test('把数据文件打包进去', () async {
      write('kanban-server.sqlite', '假装是数据库');
      write('files/ab/abcdef', '假装是附件');

      final zip = await createBackup(dir.path);

      final names = namesIn(zip);
      expect(names, contains('kanban-server.sqlite'));
      expect(names.any((n) => n.endsWith('abcdef')), isTrue);
    });

    test('不把旧备份套进新备份', () async {
      // 否则每备份一次体积就翻一倍。
      write('kanban-server.sqlite', 'x');
      write('backup-20260101-000000.zip', '旧备份');

      final zip = await createBackup(dir.path);

      expect(namesIn(zip), isNot(contains('backup-20260101-000000.zip')));
    });

    test('跳过 WAL 和临时文件', () async {
      // 运行时状态，恢复时不需要，带上反而可能不一致。
      write('kanban-server.sqlite', 'x');
      write('kanban-server.sqlite-wal', 'wal');
      write('kanban-server.sqlite-shm', 'shm');

      final names = namesIn(await createBackup(dir.path));

      expect(names, contains('kanban-server.sqlite'));
      expect(names.any((n) => n.endsWith('-wal')), isFalse);
      expect(names.any((n) => n.endsWith('-shm')), isFalse);
    });

    test('备份文件名带时间戳，放在数据目录下', () async {
      write('kanban-server.sqlite', 'x');
      final zip = await createBackup(dir.path);

      expect(p.dirname(zip.path), dir.path);
      expect(p.basename(zip.path), matches(RegExp(r'^backup-\d{8}-\d{6}\.zip$')));
    });

    test('数据目录不存在时报错而不是静默成功', () async {
      expect(
        () => createBackup(p.join(dir.path, '不存在')),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('清理旧备份', () {
    test('只留最近的若干份', () async {
      for (final stamp in [
        '20260101-000000',
        '20260102-000000',
        '20260103-000000',
        '20260104-000000',
      ]) {
        write('backup-$stamp.zip', 'x');
      }

      final removed = await pruneBackups(dir.path, keep: 2);

      expect(removed, 2);
      final left = dir
          .listSync()
          .map((f) => p.basename(f.path))
          .where((n) => n.startsWith('backup-'))
          .toList();
      expect(left, containsAll(['backup-20260104-000000.zip', 'backup-20260103-000000.zip']));
    });

    test('数量没超过上限时什么都不删', () async {
      write('backup-20260101-000000.zip', 'x');
      expect(await pruneBackups(dir.path, keep: 7), 0);
    });

    test('不碰非备份文件', () async {
      write('kanban-server.sqlite', 'x');
      write('backup-20260101-000000.zip', 'x');

      await pruneBackups(dir.path, keep: 0);

      expect(File(p.join(dir.path, 'kanban-server.sqlite')).existsSync(), isTrue);
    });
  });
}
