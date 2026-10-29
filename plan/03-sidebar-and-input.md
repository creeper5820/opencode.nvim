# 子任务 03：双窗口侧边栏与 Vim 原生交互

## 目标

实现类似 Explorer 的可开合侧边栏，以上下两个真实 Neovim window 分别承载只读对话输出和可编辑输入，完全使用 Neovim 的 window、buffer 和模式逻辑处理焦点及快捷键。

本任务通过注入 `on_submit` 回调验证提交行为，不依赖真实 OpenCode 服务；会话数据流和对话渲染分别由后续独立任务接入。

## 文件所有权

允许修改 `lua/opencode/ui/**`、`tests/headless/ui/**` 和 `tests/unit/ui/**`。禁止修改 `init.lua`、`config.lua`、`plugin/`、render、completion、status 和其他任务目录；公共装配由 10 完成。

## 独立闭环

完成后，用户可以打开和隐藏侧边栏，使用原生窗口快捷键在输出和输入之间切换，在输入框中使用完整 Vim 编辑能力，并在输出窗口中使用 Normal/Visual 导航。全部行为可在 headless Neovim 中使用假回调验证。

## 固定窗口布局

```text
┌─ OpenCode Messages ───────┐
│ Normal / Visual           │
│ 只读对话输出 buffer        │
│                           │
├─ OpenCode Input ──────────┤
│ Normal / Insert / Visual  │
│ 普通可编辑输入 buffer      │
└───────────────────────────┘
```

- 两个区域是两个独立 window，而不是在同一 buffer 中模拟输入区。
- 使用 `<C-w>w`、`<C-w>h`、`<C-w>l` 等 Neovim 原生操作切换焦点。
- 根据当前 window 和 buffer 决定快捷键是否生效，不实现全局模式分发器。
- 输出 buffer 不提供 Insert/Edit 输入体验。
- 输入 buffer 和悬浮提问框复用同一套编辑行为。

## Buffer 与快捷键边界

### 输出 buffer

- 使用 scratch buffer，设置 `nomodifiable`。
- 只注册 Normal/Visual 模式所需的 buffer-local 行为。
- `<C-d>`、`<C-u>`、`<C-f>`、`<C-b>` 只在该 buffer 中处理翻页。
- `gg`、`G`、Visual 选择和寄存器复制保持原生行为。
- `za`、`zo`、`zc`、`zR`、`zM` 等折叠操作由后续渲染任务使用，不在全局覆盖。
- 不注册 Insert 模式快捷键，不接收用户文本编辑。

### 输入 buffer

- 使用真实可编辑 buffer，保留 Normal、Insert、Visual、寄存器和撤销。
- `<CR>` 保留换行。
- 提交快捷键仅在输入 buffer 内注册，不影响输出 window 或普通代码 buffer。
- `<Esc>` 只执行 Vim 自身的模式切换，不关闭整个侧边栏。
- 除明确的提交快捷键外，不拦截其他编辑键。

## 范围

- `<leader>oo` 打开或隐藏侧边栏。
- 可配置宽度和输入框高度。
- 隐藏窗口保留输出内容、草稿和会话关联状态。
- 空输入不提交；服务端接纳输入后清空输入框，不等待 Agent 执行完成。
- 提交回调失败时保留草稿；回调必须区分“已接纳”和“执行完成”。
- 用户主动关闭某个 window 或 wipe buffer 后，再次打开能够安全重建。
- 不为聊天功能安装全局 Insert 模式映射。

## 建议 UI 接口

```lua
ui.toggle()
ui.open()
ui.close()
ui.is_open()
ui.focus_input()
ui.focus_messages()
ui.get_buffers()
ui.get_windows()
ui.get_draft()
ui.append_draft(text)
ui.set_draft(text)
ui.on_submit(callback)
```

- `get_buffers()` 和 `get_windows()` 为独立渲染器提供挂载点。
- `append_draft` 和 `on_submit` 是选择操作及真实对话集成的稳定边界。
- UI 容器不解析 SSE，也不决定工具调用或 diff 的展示格式。
- 补全引擎由子任务 07A 附着到输入 buffer，状态显示由子任务 08 附着到 window；本任务不内置这两套逻辑。

## 独立测试

### 自动化

- 侧边栏始终由上下两个独立 window 构成。
- 原生窗口切换可以在输入和输出之间移动焦点。
- 连续 toggle 不创建重复 buffer 或 window。
- 隐藏再打开后草稿和输出内容保持不变。
- 输入 buffer 的普通编辑、换行、Visual、寄存器和撤销可用。
- 提交快捷键只在输入 buffer 生效，并且只调用一次回调。
- 输出 buffer 不可编辑，翻页键不影响输入 buffer 或普通代码 buffer。
- 输出 buffer 中 Visual 选择和复制可用。
- 空草稿和回调失败时行为符合约束。
- 任一 window 被用户手动关闭后能够恢复布局。

### 手动验证

在测试单独拉起的专用 Neovim 实例中切换窗口，使用插入、选择、寄存器粘贴、撤销、翻页和折叠操作，确认没有模拟终端、全局模式分发或远程按键注入；不得操作用户正在运行的 Neovim。

## 完成标准

- 双窗口侧边栏和输入体验可以脱离网络及渲染器独立使用与测试。
- 输入和输出的快捷键严格限定在各自 buffer，不存在全局冲突。
- 所有 UI 自动化测试通过。
- 对选择操作、会话模型和渲染器暴露稳定接口。
- 不包含 Visual 选择提取、HTTP、SSE、消息格式渲染、补全源或会话状态显示逻辑。
