import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// 附件的存储。
///
/// **按内容的 SHA-256 存盘**，文件名就是哈希：
///
/// ```
/// <数据目录>/files/<哈希前2位>/<哈希>
/// ```
///
/// 好处有三个：同一张图在多张卡片里用只占一份磁盘；上传前先问一句
/// "有没有这个哈希"就能实现秒传；文件内容和文件名一一对应，永远不会
/// 出现"名字对上了内容却不对"的情况。
///
/// 分两级目录是因为单个目录塞几万个文件时，很多文件系统的目录查找会变慢。
class FileStore {
  final String root;

  FileStore(this.root);

  /// 单文件上限。超了在客户端就该拦下并提示，服务端这里是最后一道。
  static const int maxFileBytes = 100 * 1024 * 1024;

  Directory get _dir => Directory(p.join(root, 'files'));

  /// 哈希对应的文件路径。**不保证存在。**
  File fileFor(String hash) =>
      File(p.join(root, 'files', hash.substring(0, 2), hash));

  bool has(String hash) => _isValidHash(hash) && fileFor(hash).existsSync();

  int sizeOf(String hash) {
    final f = fileFor(hash);
    return f.existsSync() ? f.lengthSync() : 0;
  }

  /// 存一份内容，返回它的哈希。
  ///
  /// 内容已经存在就直接返回哈希，不重复写盘——这就是秒传。
  Future<String> put(List<int> bytes) async {
    if (bytes.length > maxFileBytes) {
      throw ArgumentError('文件超过 ${maxFileBytes ~/ (1024 * 1024)}MB 上限');
    }
    final hash = sha256.convert(bytes).toString();
    final file = fileFor(hash);
    if (file.existsSync()) return hash;

    await file.parent.create(recursive: true);
    // 先写临时文件再改名：写到一半断电的话，留下的是个临时文件，
    // 而不是一个哈希对不上内容的坏文件。
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
    return hash;
  }

  Future<Uint8List?> read(String hash) async {
    if (!has(hash)) return null;
    return fileFor(hash).readAsBytes();
  }

  /// 磁盘上所有文件的哈希。
  Set<String> allHashes() {
    if (!_dir.existsSync()) return {};
    return {
      for (final f in _dir.listSync(recursive: true).whereType<File>())
        if (!f.path.endsWith('.tmp')) p.basename(f.path),
    };
  }

  int get totalBytes {
    if (!_dir.existsSync()) return 0;
    var sum = 0;
    for (final f in _dir.listSync(recursive: true).whereType<File>()) {
      sum += f.lengthSync();
    }
    return sum;
  }

  int get fileCount => allHashes().length;

  /// 删掉一个文件。调用方要自己确认它已经没人引用了。
  Future<bool> delete(String hash) async {
    final f = fileFor(hash);
    if (!f.existsSync()) return false;
    await f.delete();
    return true;
  }

  /// 清理写到一半留下的临时文件。启动时跑一次。
  Future<int> cleanTemp() async {
    if (!_dir.existsSync()) return 0;
    var removed = 0;
    for (final f in _dir.listSync(recursive: true).whereType<File>()) {
      if (f.path.endsWith('.tmp')) {
        await f.delete();
        removed++;
      }
    }
    return removed;
  }

  /// 哈希必须是 64 位十六进制。
  ///
  /// 这同时是一道安全检查：哈希是从请求路径里来的，不校验的话
  /// `../../` 这种就能读到文件目录之外去。
  static bool _isValidHash(String hash) =>
      RegExp(r'^[0-9a-f]{64}$').hasMatch(hash);

  static bool isValidHash(String hash) => _isValidHash(hash);
}

/// 解析 HTTP 的 `Range: bytes=start-end` 头，返回闭区间 `[start, end]`。
///
/// 解析不了、或范围越界，就返回 null——调用方按整份发。断点续传是优化，
/// 不该因为一个畸形的头就让下载失败。
///
/// 放在 lib 里而不是留在 bin，是因为这里的边界条件多到必须测：曾经把
/// 行尾锚点 `$` 写成了转义的 `\$`（字面量美元符号），结果任何真实的 Range
/// 头都匹配不上，断点续传**静默失效**——下载照常能用，只是永远从头开始。
(int, int)? parseRange(String? header, int length) {
  if (header == null || length <= 0) return null;
  final m = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header.trim());
  if (m == null) return null;

  final startText = m.group(1)!;
  final endText = m.group(2)!;
  if (startText.isEmpty && endText.isEmpty) return null;

  int start;
  int end;
  if (startText.isEmpty) {
    // `bytes=-500` 表示最后 500 字节
    final tail = int.parse(endText);
    if (tail <= 0) return null;
    start = length - tail < 0 ? 0 : length - tail;
    end = length - 1;
  } else {
    start = int.parse(startText);
    end = endText.isEmpty ? length - 1 : int.parse(endText);
  }

  if (start < 0 || start >= length || end < start) return null;
  if (end >= length) end = length - 1;
  return (start, end);
}
