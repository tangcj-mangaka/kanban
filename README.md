# 驴看板

一个个人用的看板应用，Windows 桌面端 + Android 手机端，数据在设备间实时互通。

和常见的看板不一样：**没有列**。每个看板是一块自由画布，卡片随意摆放拖动，分类完全靠标签。另有一个按标签自动分列的分组视图用来俯瞰。归档区叫**干草仓库**。

数据**本地优先**——每台设备存一份完整数据，离线照样能完整增删改查。同步只是有网时的后台行为，服务端不在线不影响任何设备使用。

## 文档

| 文件 | 内容 |
|---|---|
| [docs/DESIGN.md](docs/DESIGN.md) | 完整设计文档：数据模型、同步机制、视图交互、UI 规范、开发路线 |
| [design/palette.html](design/palette.html) | 色板与图标方案对比页（浏览器打开） |

## 开发环境

**在 Mac 上开发，Windows 的 `.exe` 由 GitHub Actions 云端构建。** 不需要任何 Windows 开发环境。

Flutter 无法在 macOS 上编译 Windows 桌面应用（依赖 MSVC 工具链，且不存在交叉编译方案）。但这只是**出包**的限制——P1 的全部内容都是平台无关的，在 macOS 桌面版上开发和验证即可。

### 日常开发（Mac）

```bash
cd packages/app && flutter run -d macos
```

```bash
cd packages/app && flutter analyze
```

### 拿 Windows 版

push 到 `main` 后，GitHub Actions 自动构建。到仓库的 **Actions** 页面下载 `kanban-windows` 产物，解压双击 `kanban.exe` 即可运行，目标机器不需要装任何东西。

也可以在 Actions 页面手动触发（`Run workflow`）。

### 已知的平台差异

在 macOS 上开发、最终跑在 Windows，以下地方需要在出包后实机确认一次：

- 中文默认字体不同（苹方 vs 微软雅黑），行高与字重观感有差异
- 滚动惯性、触控板手势
- 快捷键 `Cmd` / `Ctrl`
- 窗口标题栏样式、应用数据目录位置
- **P2 的托盘常驻和开机自启是 Windows 专属能力，Mac 上无法验证**，到那个阶段需要在 Windows 机器上实测

## 工程结构

```
kanban/
├── packages/
│   ├── shared/     # 数据模型 + 同步协议定义（客户端服务端共用）
│   ├── app/        # Flutter 客户端（Windows + Android）
│   └── server/     # Dart 服务端（局域网同步，P2 阶段）
├── design/         # 设计资产
└── docs/           # 设计文档
```

## 进度

| 阶段 | 内容 | 状态 |
|---|---|---|
| P1 | 单机版：看板、画布、卡片、标签、分组视图、干草仓库。纯本地 SQLite | 进行中 |
| P2 | 服务端 + 局域网实时同步 | — |
| P3 | 附件系统 | — |
| P4 | Android 客户端 | — |
| P5 | 搜索、备份、UI 打磨 | — |
