/// 色板的 key。
///
/// 只有 key 属于领域层——数据库里 `card.color` 和 `tag.color` 存的是这些
/// 字符串，服务端同步时传的也是它们。具体是哪个十六进制值是 UI 的事，
/// 放在客户端的主题里。
///
/// 这样分层还有个好处：以后想换整套配色，改 UI 那一处即可，
/// 已有数据一条都不用迁移。
library;

const List<String> kSwatchKeys = [
  'red',
  'orange',
  'yellow',
  'lime',
  'green',
  'teal',
  'blue',
  'indigo',
  'purple',
  'pink',
  'brown',
  'gray',
];

/// 卡片可以没有颜色（[kSwatchKeys] 之外的第 13 种状态），此时 color 字段为 null。
/// 标签则必须有颜色，默认给灰。
const String kDefaultTagSwatch = 'gray';
