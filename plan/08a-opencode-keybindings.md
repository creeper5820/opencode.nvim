# 子任务 08A：OpenCode 语义快捷键兼容层

## 目标

将 OpenCode CLI 的语义 keybind command ID 映射为 Neovim buffer-local action，而不是向 TUI 转发原始按键。首版重点支持 `session.interrupt`，包括用户配置的单击、双击 `<Esc>` 或其他绑定，并为后续 session/navigation action 提供统一框架。

## 文件所有权

允许修改：

```text
lua/opencode/keybindings/**
lua/opencode/actions/session.lua
tests/unit/keybindings/**
tests/headless/keybindings/**
tests/unit/actions/session/**
```

禁止修改 `client.lua`、`api/v2.lua`、`session.lua`、UI、公共 init/config/plugin 和其他任务目录。client/session 的 interrupt 方法由对应 owner 补充，本任务通过注入 action 独立测试。

## 独立闭环

使用临时 `cli.json`、假 session action 和独立 headless Neovim，验证解析、映射、双击序列、模式隔离及 interrupt 调用，不需要真实 OpenCode。

## 设计原则

- 映射 command ID → action，不模拟终端键盘输入。
- 输入编辑 command（光标移动、删除、undo 等）继续由 Vim 原生能力承担，不机械导入 TUI 单键编辑规则。
- 滚动/折叠在本地 window/buffer 完成，不发送网络请求。
- `session.interrupt` 调用 05A 的 `session.interrupt()`，最终走 `POST /api/session/{sessionID}/interrupt`。
- 所有映射只附着 OpenCode messages/input buffer，不污染普通代码 buffer。

## Esc 与模式约束

- Insert 模式第一个 `<Esc>` 始终只退出 Insert，不直接中断执行。
- interrupt 映射只注册 Normal 模式；Visual 模式先由用户退出 Visual，再执行中断，避免破坏选择语义。
- 支持 `<Esc><Esc>` 等多键序列及 timeout；单击绑定与多键绑定由有效配置决定，不写死。
- 若单击 Escape 映射会造成不可接受的 Normal 模式等待或冲突，配置校验/文档必须明确，不通过全局 on_key hook 解决。

## 配置兼容

- 读取 OpenCode V2 `cli.json` 的 `keybinds` 和 leader 配置；测试只读取隔离临时配置。
- 支持字符串、alternatives、false/`none` 禁用，以及首版所需 key object 形式。
- 支持 OpenCode key syntax 到 Neovim lhs 的明确转换子集；无法转换的键给出非阻塞 health 信息，不猜键。
- 提供 Neovim 用户 overrides，优先级高于 CLI 配置。
- 当前 V2 文档默认 `session.interrupt=escape`；用户的双击 Escape 可能来自自定义配置，二者都必须能表达。

## 建议接口

```lua
keybindings.resolve({ cli_config = ..., overrides = ... })
keybindings.attach(buffer, {
  actions = {
    ["session.interrupt"] = function() end,
  },
})
keybindings.detach(buffer)

session_action.interrupt(controller, callback)
```

## 独立测试

- 默认单个 Escape、用户双击 Escape及其他 alternatives 解析正确。
- false/none 禁用，leader 和 override 优先级正确。
- Insert 第一个 Escape 不调用 interrupt。
- Normal 下单击/双击按有效配置恰好调用一次 action。
- Visual 和普通代码 buffer 不被意外中断。
- detach/window 重建后无重复映射或旧 action。
- 无活跃执行时 API 返回 idle no-op 不显示误导性错误。
- 不支持 command/key 有健康提示，不影响其他映射。

## 完成标准

- 假 action 的解析和 headless 测试全部通过。
- 不使用终端按键 hook、全局 on_key 或原始 TUI 输入转发。
- 与 02B/05A interrupt 扩展的接口清晰，由 10 完成真实服务验证。
