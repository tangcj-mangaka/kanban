import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:image/image.dart' as img;
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

import '../data/database.dart';

/// 一个刚导入的附件，还没写进 op log。
class ImportedFile {
  final String hash;
  final String filename;
  final int size;
  final String mime;

  /// 缩略图的哈希。只有图片才有。
  final String? thumbHash;

  const ImportedFile({
    required this.hash,
    required this.filename,
    required this.size,
    required this.mime,
    required this.thumbHash,
  });

  bool get isImage => mime.startsWith('image/');
}

/// 本机的附件仓库。
///
/// 布局和服务端一样（`<缓存目录>/<哈希前2位>/<哈希>`），所以下载下来的
/// 文件直接落到同一个位置，不需要两套路径逻辑。
class AttachmentStore {
  final AppDatabase db;
  final Directory cacheDir;

  AttachmentStore(this.db, this.cacheDir);

  /// 本机缓存上限。超了按最近最少使用淘汰。
  ///
  /// 手机上尤其需要：几百张图全下下来既费流量又占空间，而绝大多数图
  /// 看过一次就不会再看。删掉的只是本地副本，服务端那份还在，
  /// 要看的时候再下。
  static const int defaultMaxBytes = 500 * 1024 * 1024;

  /// 缩略图的长边。够在画布卡片和详情列表里看清，又小到可以全都缓存着。
  static const int thumbLongSide = 400;

  File fileFor(String hash) =>
      File(p.join(cacheDir.path, hash.substring(0, 2), hash));

  bool has(String hash) =>
      hash.length >= 2 && fileFor(hash).existsSync();

  /// 把外部文件导入缓存，返回它的哈希等信息。
  ///
  /// 只做本地的事：算哈希、拷贝、生成缩略图。**不碰网络**——离线时加附件
  /// 必须立刻可用，上传是后台的事。
  Future<ImportedFile> importFile(File source, {String? displayName}) async {
    final bytes = await source.readAsBytes();
    final name = displayName ?? p.basename(source.path);
    final mime = lookupMimeType(name, headerBytes: _headerOf(bytes)) ??
        'application/octet-stream';

    final hash = await putBytes(bytes);

    String? thumbHash;
    if (mime.startsWith('image/')) {
      final thumb = await _makeThumbnail(bytes);
      if (thumb != null) thumbHash = await putBytes(thumb);
    }

    return ImportedFile(
      hash: hash,
      filename: name,
      size: bytes.length,
      mime: mime,
      thumbHash: thumbHash,
    );
  }

  /// 存一份内容，返回哈希。已经有了就不重复写盘。
  Future<String> putBytes(List<int> bytes, {bool uploaded = false}) async {
    final hash = sha256.convert(bytes).toString();
    final file = fileFor(hash);

    if (!file.existsSync()) {
      await file.parent.create(recursive: true);
      // 先写临时文件再改名：写到一半断电留下的是临时文件，
      // 而不是一个哈希对不上内容的坏文件。
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(file.path);
    }

    await db.into(db.fileCaches).insertOnConflictUpdate(
          FileCachesCompanion.insert(
            hash: hash,
            size: bytes.length,
            lastUsed: DateTime.now().millisecondsSinceEpoch,
            uploaded: Value(uploaded),
          ),
        );
    return hash;
  }

  Future<Uint8List?> read(String hash) async {
    if (!has(hash)) return null;
    await touch(hash);
    return fileFor(hash).readAsBytes();
  }

  /// 记一次使用，供缓存淘汰参考。
  Future<void> touch(String hash) async {
    await (db.update(db.fileCaches)..where((f) => f.hash.equals(hash))).write(
      FileCachesCompanion(
        lastUsed: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
  }

  /// 还没传上服务端的文件。
  ///
  /// 离线时加的附件停在这里，联网后自动补传——和 op 的待发队列是一回事，
  /// 只是走的通道不同。
  Future<List<String>> pendingUploads() async {
    final rows = await (db.select(db.fileCaches)
          ..where((f) => f.uploaded.equals(false))
          ..orderBy([(f) => OrderingTerm.asc(f.lastUsed)]))
        .get();
    // 只报还真的在本地的——文件被缓存淘汰掉了就没法传了。
    return [for (final r in rows) if (has(r.hash)) r.hash];
  }

  Future<void> markUploaded(String hash) async {
    await (db.update(db.fileCaches)..where((f) => f.hash.equals(hash)))
        .write(const FileCachesCompanion(uploaded: Value(true)));
  }

  Future<int> get cachedBytes async {
    final total = db.fileCaches.size.sum();
    final row = await (db.selectOnly(db.fileCaches)..addColumns([total]))
        .getSingle();
    return row.read(total) ?? 0;
  }

  /// 按最近最少使用淘汰，把缓存压到上限以内。返回删掉的文件数。
  ///
  /// **不会删还没传上去的文件**——那是本机唯一的副本，删了就真没了。
  Future<int> evict({int maxBytes = defaultMaxBytes}) async {
    var total = await cachedBytes;
    if (total <= maxBytes) return 0;

    final rows = await (db.select(db.fileCaches)
          ..where((f) => f.uploaded.equals(true))
          ..orderBy([(f) => OrderingTerm.asc(f.lastUsed)]))
        .get();

    var removed = 0;
    for (final row in rows) {
      if (total <= maxBytes) break;
      final file = fileFor(row.hash);
      if (file.existsSync()) await file.delete();
      await (db.delete(db.fileCaches)..where((f) => f.hash.equals(row.hash)))
          .go();
      total -= row.size;
      removed++;
    }
    return removed;
  }

  /// 清理写到一半留下的临时文件。
  Future<int> cleanTemp() async {
    if (!cacheDir.existsSync()) return 0;
    var removed = 0;
    for (final f in cacheDir.listSync(recursive: true).whereType<File>()) {
      if (f.path.endsWith('.tmp')) {
        await f.delete();
        removed++;
      }
    }
    return removed;
  }

  /// 生成缩略图。
  ///
  /// 在**客户端**生成而不是服务端，这样服务端不用装任何图像库——它只是
  /// 个存字节的地方。代价是每个客户端各算一次，但缩略图有哈希去重，
  /// 同一张图第二个客户端上传时会秒传。
  Future<Uint8List?> _makeThumbnail(Uint8List bytes) async {
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;
      // 本来就比缩略图还小的，不必再存一份。
      if (decoded.width <= thumbLongSide && decoded.height <= thumbLongSide) {
        return null;
      }
      final resized = decoded.width >= decoded.height
          ? img.copyResize(decoded, width: thumbLongSide)
          : img.copyResize(decoded, height: thumbLongSide);
      return img.encodeJpg(resized, quality: 82);
    } catch (_) {
      // 认不出的图片格式、损坏的文件——没有缩略图不影响附件本身可用。
      return null;
    }
  }

  static List<int>? _headerOf(Uint8List bytes) =>
      bytes.length >= defaultMagicNumbersMaxLength
          ? bytes.sublist(0, defaultMagicNumbersMaxLength)
          : bytes;
}
