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
          (op_id, board_id, entity, entity_id, field, value_json, device_id, wall_ts)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
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
  // 设备
  // -------------------------------------------------------------------------

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
