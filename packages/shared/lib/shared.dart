/// 驴看板的共享层：数据模型、op log 定义与同步协议。
///
/// 客户端和服务端共用这一层，保证两边对「一次修改长什么样」的理解
/// 永远一致——协议改了，两边一起改，不会漏。
library;

export 'src/connect_link.dart';
export 'src/op.dart';
export 'src/protocol.dart';
export 'src/ordering.dart';
export 'src/swatches.dart';
export 'src/version.dart';
