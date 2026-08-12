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

**app 在 Windows 笔记本上编译和运行。** Mac 这边只写代码和跑静态检查——Flutter 无法在 macOS 上编译 Windows 桌面应用，这是硬限制。

### Windows 笔记本首次准备

1. 装 [Flutter SDK](https://docs.flutter.dev/get-started/install/windows)
2. 装 Visual Studio 2022，勾选「使用 C++ 的桌面开发」工作负载（Windows 桌面构建必需）
3. 验证环境：

```bash
flutter doctor
```

### 跑起来

```bash
flutter run -d windows
```

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
