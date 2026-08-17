import 'dart:convert';
import 'dart:math';

import 'package:shared/shared.dart';
import 'package:sqlite3/sqlite3.dart';

/// 一台已配对的设备。
class Device {
  final String id;
  final String name;
  final String token;
  final int pairedAt;
  final int lastSeen;

  const Device({
    required this.id,
    required this.name,
    required this.token,
    required this.pairedAt,
    required this.lastSeen,
  });
}

/// 服务端的存储。
///
/// **服务端不理解数据模型。** 它只存 op log、分配全局序号、记住配对过的
/// 设备——什么是卡片、什么是标签、字段之间怎么互相覆盖，全是客户端的事。
///
/// 这不是偷懒，是刻意的：物化逻辑只有一份（在客户端），两边不会跑偏；
/// 以后加新字段、新实体类型，服务端一行都不用改。
class Store {
  final Database _db;

  Store(this._db) {
    _migrate();
  }

  factory Store.open(String path) => Store(sqlite3.open(path));

  factory Store.memory() => Store(sqlite3.openInMemory());

  /// 这张表有没有这一列。用来给已存在的库补列。
  bool _hasColumn(String table, String column) {
    final rows = _db.select('PRAGMA table_info($table)');
    return rows.any((r) => r['name'] == column);
  }

  void _migrate() {
    _db.execute('PRAGMA journal_mode = WAL');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS ops (
        seq       INTEGER PRIMARY KEY AUTOINCREMENT,
        op_id     TEXT NOT NULL UNIQUE,
        board_id  TEXT NOT NULL,
        entity    TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        field     TEXT NOT NULL,
        value_json TEXT NOT NULL,
        device_id TEXT NOT NULL,
        wall_ts   INTEGER NOT NULL
      )
    ''');
    // base_seq 是后加的：产生 op 时那台设备已知的最大序号，客户端用它
    // 判断两条改动是不是真并发。
    //
    // **服务端必须原样存下来再广播出去**。它不理解这个字段的含义，但如果
    // 存都不存，客户端收到的就是 null，并发检测会永远判不出来——而且不报
    // 任何错，功能悄悄失效。
    //
    // `CREATE TABLE IF NOT EXISTS` 对已存在的库不会加列，所以这里补一次
    // ALTER。旧库里已有的 op 这一列是 null，那些 op 判不了并发，可以接受。
    if (!_hasColumn('ops', 'base_seq')) {
      _db.execute('ALTER TABLE ops ADD COLUMN base_seq INTEGER');
    }

    _db.execute('CREATE INDEX IF NOT EXISTS idx_ops_field ON ops(entity_id, field, seq)');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_ops_board ON ops(board_id, seq)');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS devices (
        id        TEXT PRIMARY KEY,
        name      TEXT NOT NULL,
        token     TEXT NOT NULL,
        paired_at INTEGER NOT NULL,
        last_seen INTEGER NOT NULL
      )
    ''');

    // 已经没人引用、正在等待延迟删除的文件。
    _db.execute('''
      CREATE TABLE IF NOT EXISTS orphan_files (
        hash  TEXT PRIMARY KEY,
        since INTEGER NOT NULL
      )
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS meta (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
  }

  void close() => _db.close();

  // -------------------------------------------------------------------------
  // op log
  // -------------------------------------------------------------------------

  /// 当前最大的 seq。没有任何 op 时为 0。
  int get maxSeq {
    final row = _db.select('SELECT COALESCE(MAX(seq), 0) AS m FROM ops').first;
    return row['m'] as int;
  }

  /// 客户端 last_seq 早于这个点时，增量已经补不齐了，得走全量快照。
  int get compactionSeq {
    final rows = _db.select(
      "SELECT value FROM meta WHERE key = 'compaction_seq'",
    );
    if (rows.isEmpty) return 0;
    return int.tryParse(rows.first['value'] as String) ?? 0;
  }

  /// 收下一批 op，按到达顺序分配 seq。
  ///
  /// 返回 opId → seq 的映射，其中也包含**之前已经收过**的 op：客户端
  /// 重连补发时会把同一批 op 再发一次，这时要把它们原来的 seq 告诉它，
  /// 而不是分配新号，否则同一次修改会在 log 里出现两遍。
  Map<String, int> append(List<Op> ops) {
    final assigned = <String, int>{};
    if (ops.isEmpty) return assigned;

    _db.execute('BEGIN');
    try {
      final insert = _db.prepare('''
        INSERT OR IGNORE INTO ops
          (op_id, board_id, entity, entity_id, field, value_json, device_id, wall_ts,
           base_seq)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''');
      final lookup = _db.prepare('SELECT seq FROM ops WHERE op_id = ?');

      for (final op in ops) {
        insert.execute([
          op.opId,
          op.boardId,
          op.entity,
          op.entityId,
          op.field,
          jsonEncode(op.value),
          op.deviceId,
          op.wallTs,
          op.baseSeq,
        ]);
        final row = lookup.select([op.opId]);
        if (row.isNotEmpty) assigned[op.opId] = row.first['seq'] as int;
      }

      insert.close();
      lookup.close();
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    return assigned;
  }

  /// seq 大于 [since] 的所有 op，按 seq 升序。
  List<Op> opsSince(int since, {int limit = 100000}) {
    final rows = _db.select(
      'SELECT * FROM ops WHERE seq > ? ORDER BY seq ASC LIMIT ?',
      [since, limit],
    );
    return [for (final r in rows) _toOp(r)];
  }

  /// 取指定 opId 对应的 op（含服务端分配的 seq），用于广播。
  List<Op> opsByIds(Iterable<String> opIds) {
    final ids = opIds.toList();
    if (ids.isEmpty) return const [];
    final placeholders = List.filled(ids.length, '?').join(', ');
    final rows = _db.select(
      'SELECT * FROM ops WHERE op_id IN ($placeholders) ORDER BY seq ASC',
      ids,
    );
    return [for (final r in rows) _toOp(r)];
  }

  Op _toOp(Row r) => Op(
    seq: r['seq'] as int,
    opId: r['op_id'] as String,
    boardId: r['board_id'] as String,
    entity: r['entity'] as String,
    entityId: r['entity_id'] as String,
    field: r['field'] as String,
    value: jsonDecode(r['value_json'] as String),
    deviceId: r['device_id'] as String,
    wallTs: r['wall_ts'] as int,
    baseSeq: r['base_seq'] as int?,
  );

  int get opCount =>
      _db.select('SELECT COUNT(*) AS c FROM ops').first['c'] as int;

  /// 压缩：每个 (entity_id, field) 只保留 seq 最大的那条 op。
  ///
  /// op 表只增不减，个人使用量下一年也就几万条，SQLite 毫无压力，所以
  /// 这不是急事——但机制要留好。压缩后记下压缩点，此后 last_seq 早于
  /// 该点的客户端必须走全量快照，否则它补到的增量是残缺的。
  int compact() {
    final before = opCount;
    _db.execute('BEGIN');
    try {
      _db.execute('''
        DELETE FROM ops WHERE seq NOT IN (
          SELECT MAX(seq) FROM ops GROUP BY entity_id, field
        )
      ''');
      final point = maxSeq;
      _db.execute(
        "INSERT INTO meta (key, value) VALUES ('compaction_seq', ?) "
        "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        ['$point'],
      );
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    return before - opCount;
  }

  // -------------------------------------------------------------------------
  // 附件文件的引用关系
  // -------------------------------------------------------------------------

  /// 仍被引用的文件哈希。
  ///
  /// **这是服务端唯一一处需要看懂数据语义的地方。** 别处它只管分配序号和
  /// 广播，从不理解什么是卡片、什么是标签。这里破例，是因为磁盘回收是
  /// 服务端自己的职责——它得知道哪些文件还有人要，否则要么永远不删（磁盘
  /// 撑爆），要么删错（附件凭空消失）。
  ///
  /// 做法仍然只依赖 op log：对每个附件实体取每个字段最新的那条 op，
  /// 未被标删的实体，它的 hash 和 thumb_hash 就是还在用的。
  Set<String> referencedHashes() {
    final rows = _db.select('''
      WITH ranked AS (
        SELECT entity_id, field, value_json,
               ROW_NUMBER() OVER (
                 PARTITION BY entity_id, field ORDER BY seq DESC
               ) AS rn
        FROM ops WHERE entity = 'attachment'
      ),
      latest AS (
        SELECT entity_id, field, value_json FROM ranked WHERE rn = 1
      )
      SELECT l.value_json AS v FROM latest l
      WHERE l.field IN ('hash', 'thumb_hash')
        AND COALESCE(
              (SELECT d.value_json FROM latest d
               WHERE d.entity_id = l.entity_id AND d.field = 'deleted'),
              'false'
            ) != 'true'
    ''');

    final hashes = <String>{};
    for (final r in rows) {
      final decoded = jsonDecode(r['v'] as String);
      if (decoded is String && decoded.isNotEmpty) hashes.add(decoded);
    }
    return hashes;
  }

  /// 记录/更新孤儿文件，并返回该删的那些。
  ///
  /// **不立即删除**：卡片删了三十天内还能后悔，那时文件还在，恢复卡片就能
  /// 连附件一起回来。真正的删除延迟到 [after] 之后。
  List<String> sweepOrphans(
    Set<String> onDisk,
    Set<String> referenced, {
    Duration after = const Duration(days: 30),
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;

    _db.execute('BEGIN');
    try {
      // 又被引用上的，撤销孤儿标记（比如卡片被捞回来了）
      for (final hash in referenced) {
        _db.execute('DELETE FROM orphan_files WHERE hash = ?', [hash]);
      }
      // 新变成孤儿的，记下时间
      for (final hash in onDisk.difference(referenced)) {
        _db.execute(
          'INSERT INTO orphan_files (hash, since) VALUES (?, ?) '
          'ON CONFLICT(hash) DO NOTHING',
          [hash, now],
        );
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }

    final cutoff = now - after.inMilliseconds;
    final due = _db.select(
      'SELECT hash FROM orphan_files WHERE since <= ?',
      [cutoff],
    );
    return [for (final r in due) r['hash'] as String];
  }

  void forgetOrphan(String hash) {
    _db.execute('DELETE FROM orphan_files WHERE hash = ?', [hash]);
  }

  int get orphanCount =>
      _db.select('SELECT COUNT(*) AS c FROM orphan_files').first['c'] as int;

  // -------------------------------------------------------------------------
  // 设备
  // -------------------------------------------------------------------------

  /// 按令牌找设备。HTTP 接口（附件上传下载）用它鉴权。
  Device? deviceByToken(String token) {
    if (token.isEmpty) return null;
    final rows = _db.select('SELECT * FROM devices WHERE token = ?', [token]);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return Device(
      id: r['id'] as String,
      name: r['name'] as String,
      token: r['token'] as String,
      pairedAt: r['paired_at'] as int,
      lastSeen: r['last_seen'] as int,
    );
  }

  List<Device> get devices {
    final rows = _db.select('SELECT * FROM devices ORDER BY paired_at ASC');
    return [
      for (final r in rows)
        Device(
          id: r['id'] as String,
          name: r['name'] as String,
          token: r['token'] as String,
          pairedAt: r['paired_at'] as int,
          lastSeen: r['last_seen'] as int,
        ),
    ];
  }

  Device? deviceById(String id) {
    final rows = _db.select('SELECT * FROM devices WHERE id = ?', [id]);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return Device(
      id: r['id'] as String,
      name: r['name'] as String,
      token: r['token'] as String,
      pairedAt: r['paired_at'] as int,
      lastSeen: r['last_seen'] as int,
    );
  }

  /// 配对一台设备，签发长期令牌。
  Device pair(String deviceId, String name) {
    final token = _randomToken();
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute(
      'INSERT INTO devices (id, name, token, paired_at, last_seen) '
      'VALUES (?, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET name = excluded.name, token = excluded.token',
      [deviceId, name, token, now, now],
    );
    return deviceById(deviceId)!;
  }

  void touchDevice(String deviceId) {
    _db.execute('UPDATE devices SET last_seen = ? WHERE id = ?', [
      DateTime.now().millisecondsSinceEpoch,
      deviceId,
    ]);
  }

  /// 改设备名。设备在 HELLO 里报的名字变了就更新。
  void renameDevice(String deviceId, String name) {
    _db.execute('UPDATE devices SET name = ? WHERE id = ?', [name, deviceId]);
  }

  void unpair(String deviceId) {
    _db.execute('DELETE FROM devices WHERE id = ?', [deviceId]);
  }
}

final _random = Random.secure();

String _randomToken() {
  final bytes = List<int>.generate(24, (_) => _random.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// 一次性配对码：6 位，去掉了容易看错的 0/O、1/I。
///
/// 用户要从屏幕上抄到另一台设备，认错一个字符就得重来。
String generatePairCode() {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  return List.generate(
    6,
    (_) => alphabet[_random.nextInt(alphabet.length)],
  ).join();
}
