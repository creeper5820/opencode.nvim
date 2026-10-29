# opencode.nvim 功能总览与并行开发契约

## 项目目标

开发一个原生 Neovim UI 的 OpenCode 客户端：

- Neovim 通过 HTTP 端口连接 OpenCode，不向终端或 TUI 注入按键。
- 使用真实 Neovim buffer 提供对话、输入、选择和翻页体验。
- OpenCode 可以通过自定义工具主动操作当前 Neovim 会话，例如打开文件、发送通知和展示 diff。

`opencode-plugin/` 是**可选 companion 插件**，不是 Neovim 主插件的安装或运行依赖。未安装、未加载或版本不兼容时，聊天、选择、补全和状态等核心功能必须正常工作；仅 OpenCode → Neovim 主动工具不可用，并通过 health/状态给出非阻塞提示。

## 状态说明

- ✅ 已完成：实现、独立测试和闭环验证均已完成。
- 🚧 进行中：已有部分实现，但尚未满足全部完成标准。
- ⬜ 未开始：只有计划，尚未开始实现。

状态表示实现进度，不表示计划文档是否已经撰写。

## 独立子任务

| 编号 | 功能 | 状态 | 独立闭环 | 详细计划 |
| --- | --- | --- | --- | --- |
| 01 | 插件骨架、配置与测试基础 | ✅ 已完成 | 干净 Neovim 加载、配置校验、health 和测试 runner。 | [01-plugin-foundation.md](01-plugin-foundation.md) |
| 02A | 原生 HTTP transport | ✅ 已完成 | 假 TCP server 验证 HTTP/1.1、chunked、流式响应、超时和取消。 | [02a-http-transport.md](02a-http-transport.md) |
| 02B | 无状态 OpenCode API client | ✅ 已完成 | 假 transport 验证 endpoint、JSON 和错误；隔离真实服务冒烟验证通过。 | [02b-opencode-api-client.md](02b-opencode-api-client.md) |
| 03 | 双窗口侧边栏与 Vim 原生交互 | ✅ 已完成 | 假提交回调验证 window、buffer、草稿和快捷键边界。 | [03-sidebar-and-input.md](03-sidebar-and-input.md) |
| 04 | Visual 选择上下文与两种提问 | ✅ 已完成 | 假 UI + 假 session 验证草稿和直接提问；真实 session 冒烟由 10 验证。 | [04-selection-actions.md](04-selection-actions.md) |
| 05A | Session controller 与提交路由 | ✅ 已完成 | 假 client 验证项目固定、会话创建/恢复及 prompt/command 路由。 | [05a-session-controller.md](05a-session-controller.md) |
| 05B | SSE 解析与无竞态同步 | ✅ 已完成 | 假 stream + 假历史 API 验证暂存、合并、重连和 location 过滤。 | [05b-sse-sync.md](05b-sse-sync.md) |
| 05C | 结构化 block 投影与状态归并 | ✅ 已完成 | 纯 fixtures 验证 block 树、父子关系、去重、revision 和权限状态。 | [05c-block-model.md](05c-block-model.md) |
| 06 | TUI 对齐的结构化对话渲染器 | ✅ 已完成 | 假 block 树验证 folds、extmarks、内联 diff 和滚动。 | [06-conversation-renderer.md](06-conversation-renderer.md) |
| 07A | 异步补全引擎 | ✅ 已完成 | 假 source 验证 pum、防抖、取消和过期响应。 | [07a-completion-engine.md](07a-completion-engine.md) |
| 07B | OpenCode 补全源 | ✅ 已完成 | 假 client/session 验证文件、命令、Agent、Skill 候选及提交语义。 | [07b-completion-sources.md](07b-completion-sources.md) |
| 08 | 会话与执行状态显示 | ✅ 已完成 | 假状态快照验证 winbar、权限等待和 window 生命周期。 | [08-session-status.md](08-session-status.md) |
| 08A | OpenCode 语义快捷键兼容层 | ✅ 已完成 | 将 CLI command ID/keybind 配置映射为 buffer-local Neovim action；支持单击或自定义双击 Escape 调用 interrupt API。 | [08a-opencode-keybindings.md](08a-opencode-keybindings.md) |
| 09A | Neovim 工具 server 与实例注册 | ✅ 已完成 | 假 HTTP 客户端验证认证、解析、限制、注册文件和生命周期。 | [09a-tool-server.md](09a-tool-server.md) |
| 09B | OpenCode TypeScript 工具插件（可选 companion） | ✅ 已完成 | 假 Neovim server 验证工具注册、实例路由和请求取消；隔离真实 OpenCode 加载验证通过。 | [09b-opencode-tool-plugin.md](09b-opencode-tool-plugin.md) |
| 09C | Open 与 Notify actions | ✅ 已完成 | 直接调用 handler 验证 buffer 导航和通知，不启动网络。 | [09c-open-notify-actions.md](09c-open-notify-actions.md) |
| 09D | Diff view | ✅ 已完成 | headless Neovim 验证当前 buffer 基准、折叠 diff 和 window 状态恢复。 | [09d-diff-view.md](09d-diff-view.md) |
| 10 | 公共装配与端到端集成 | ⬜ 未开始 | 统一 wiring、快捷键、文档及真实 OpenCode/Neovim 端到端验证。 | [10-integration.md](10-integration.md) |

## 核心交互

| 快捷键 | 模式 | 行为 |
| --- | --- | --- |
| `<leader>oo` | Normal | 打开或隐藏 OpenCode 侧边栏 |
| `<leader>os` | Visual | 将选择代码追加到输入草稿，不执行 |
| `<leader>oq` | Visual | 基于选择代码打开悬浮提问框 |
| `<C-s>` | Insert、Normal | 提交当前输入框或浮窗内容 |
| `<C-d>` / `<C-u>` | Normal | 在对话历史中向下、向上翻半页 |
| `<C-f>` / `<C-b>` | Normal | 在对话历史中向下、向上翻整页 |

快捷键均可配置或设为 `false` 禁用。输出和输入是两个真实 window：输出只读，仅 Normal/Visual；输入保留 Normal/Insert/Visual。使用原生窗口命令切换焦点，不实现全局模式分发。

聊天采用“历史/SSE → 同步器 → block 树 → 渲染器”。工具调用和完整 diff 保留在聊天时间线中；原生分屏 diff 只作为主动工具或显式请求的附加视图。

## 测试隔离硬限制

所有 coder 的自动化、集成、冒烟和手动验证都必须遵守：

- Neovim 测试使用测试进程单独拉起的 headless/专用实例，不连接、不控制用户正在运行的 Neovim。
- 测试 Neovim 使用独立 XDG_CONFIG_HOME、XDG_DATA_HOME、XDG_STATE_HOME、XDG_CACHE_HOME、shada 和临时项目目录，禁止加载或改写用户配置、插件数据及项目文件。
- OpenCode 集成测试使用测试 runner 单独启动的服务、独立数据/配置/注册位置、独立端口和临时项目；不得连接、重启、停止或清理用户默认 service。
- OpenCode 工具插件通过测试专用配置加载，禁止修改用户全局或项目 `opencode.json(c)`。
- 多实例测试中的全部 Neovim/OpenCode 进程都必须由测试创建并登记 PID；清理时只终止这些进程，禁止 `pkill nvim`、`pkill opencode` 或按端口猜测进程。
- 测试文件、fixture 原始采集项目和运行目录放在 `/tmp/opencode` 下的独立临时目录；进入仓库的 fixtures 必须脱敏。
- 测试失败或中断后也执行定向清理，不删除用户已有文件，不清理并非本测试创建的注册项。
- 未显式配置测试服务及必要凭据时，真实服务测试应明确 skip，不能回退到用户默认实例。

01 提供共享隔离测试 harness，10 的真实端到端测试必须复用。任何任务需要突破隔离才能验证时，应停止并返回协调者，而不是改用用户环境。

## 并行开发规则

### 文件所有权

- 每个 coder 只能修改任务声明的模块和对应测试。
- 公共 `init.lua`、`config.lua`、`plugin/opencode.lua` 由 01 和 10 的 owner 修改，其他 coder 不得顺手改动。
- 每个任务使用独立测试文件，避免多个 coder 共同编辑一个测试套件。
- 计划文档由协调者维护，coder 不修改其他子任务计划。

委托 coder 时，提示词必须明确：

1. 允许读写的精确路径。
2. 禁止修改的公共文件和其他任务目录。
3. 可依赖的接口及应使用的假实现。
4. 独立测试命令和完成标准。
5. 不通过扩大文件范围解决依赖问题；缺少契约时返回协调者确认。

### 冻结的公共契约

#### 异步结果与取消

所有网络及异步模块统一成功/错误结构；取消句柄幂等，回调最多完成一次。错误包含可展示 message 和机器可读 code，不直接操作 UI。

#### HTTP transport

普通请求返回完整 response；流式请求返回 chunk 回调与 cancel。02B 只依赖该接口，05B 只消费 chunk，不解析 TCP。

#### Session controller

```lua
session.ensure(callback)
session.prompt(text, callback)
session.command(name, arguments, callback)
session.submit(input, callback)
session.get_snapshot()
```

成功表示服务端接纳，不表示 Agent 执行完毕。当前 session ID 只能由 05A 管理。

#### 同步器与 block 模型

05B 输出“历史快照 + 有序原生事件”的有序批次；05C 将其归并为 block 树。block 至少具有 `id`、`message_id`、`parent_id`、`children`、`sequence`、`type`、`status`、`content`、`metadata`、`revision`。

#### UI

03 提供 buffers/windows、draft 和 on_submit。06 同时绑定 message buffer/window；fold 和 view 按 window 管理。07A 只附着输入 buffer；08 只附着 winbar/statusline。

#### 工具 RPC 与注册

09A 定义 JSON envelope、错误结构及 registry schema；09B/09C/09D 只依赖该契约。所有接口认证，禁止任意 Lua/Ex/shell 执行。

## 依赖与并行批次

```text
01
├─ 02A → 02B ─┬─ 05A ───────────┐
│             └─ 05B ─┐         │
│                     ├─ 05C ─┐ │
├─ 03 ────────────────┼───────┼─┼─ 04
│                     │       │ ├─ 06
│                     │       │ ├─ 07A → 07B
│                     │       │ └─ 08
└─ 09A ─┬─ 09B        │       │
        ├─ 09C        │       │
        └─ 09D        │       │
                              │
10：等待各独立闭环后统一装配与真实端到端验证
```

- 02B、05A、05B、05C、06、07A、07B、08 均可通过假依赖提前并行。
- 04 保持为一个任务，不再拆分共享选择逻辑。
- 09B、09C、09D 可依据 09A 的 RPC/registry 契约并行开发。
- 最终公共装配和跨模块行为只能由 10 修改。

## 首版边界

- 默认本地 `http://127.0.0.1:<port>`；HTTPS/TLS 后续支持。
- 首版显示等待权限状态，但不实现权限回复。
- 首版不从多个历史会话中任意选择；会话列表后续支持。
- 首版 diff 展示不自动写盘。

## 后续候选功能

- 会话列表、切换、新建和重命名。
- 模型与 Agent 选择。
- 中断执行和排队消息管理。
- 权限请求与表单回复。
- Diff 接受、拒绝和写回。
- 自动发现并启动 OpenCode 服务。
- 远程 HTTPS/TLS transport。
