/// 应用版本号，**全项目唯一的来源**。
///
/// 客户端、服务端、发布标签都以它为准：
/// - `packages/app/pubspec.yaml` 和 `packages/server/pubspec.yaml` 的
///   `version:` 必须和它一致（有测试钉着，对不上就报错）
/// - 发布时打的标签必须是 `v$kAppVersion`（CI 会校验）
///
/// 放在 shared 里而不是用 package_info_plus 之类的插件读安装包信息：
/// 服务端是纯 Dart 命令行程序，用不了 Flutter 插件，而客户端和服务端
/// 报出来的版本必须是同一个口径，否则版本对不上时根本没法排查。
const String kAppVersion = '0.3.2';
