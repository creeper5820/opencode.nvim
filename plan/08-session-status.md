# 子任务 08：会话与执行状态显示

## 目标

在 OpenCode 双窗口侧边栏中提供 window-local 状态显示，展示会话、项目、Agent、Model、连接、提交和执行状态，同时不修改用户全局 statusline，也不把详细工具输出塞进状态栏。

本任务消费假状态模型即可独立开发和测试，不依赖真实 SSE、补全或 OpenCode 主动工具。

## 文件所有权

允许修改 `lua/opencode/status.lua`、`tests/unit/status/**` 和 `tests/headless/status/**`。禁止修改 UI、session、blocks/state、events 和公共装配文件。

## 独立闭环

完成后，状态模块可以接收一组状态快照和增量事件，在输出及输入 window 中实时显示正确状态；窗口隐藏、重建和会话切换后仍能正确恢复。全部行为可在 headless Neovim 中独立验证。

## 状态区域

```text
┌─ Messages ────────────────────────────────┐
│ Session · Project       Agent / Model     │ ← 输出 window-local winbar
│ 对话内容                                  │
├─ Input ───────────────────────────────────┤
│ 输入 buffer                               │
│ Draft · Session             Submit <C-s>  │ ← 输入 window-local winbar
└───────────────────────────────────────────┘
```

具体字段和排列可配置，但首版至少区分：

- 会话标题或 ID。
- 当前项目。
- Agent 和 Model（服务提供时）。
- 连接状态。
- 提交状态。
- 执行状态，包括首版的 `waiting_permission` 提示；没有权限回复 UI 时也必须明确说明正在等待权限，而不是表现为卡死。

## 状态模型

建议统一状态快照：

```lua
{
  session = { id = "...", title = "..." },
  project = { root = "..." },
  agent = { id = "...", name = "..." },
  model = { provider_id = "...", id = "..." },
  connection = "connecting|connected|reconnecting|offline",
  submission = "idle|submitting|failed",
  execution = "idle|streaming|tool_running|retrying|compacting|waiting_permission|interrupted|failed",
}
```

- 字段不可用时省略，不显示误导性的默认值。
- 连接、提交和执行是不同维度，不能合并成一个不可靠的 `busy` 布尔值。
- 详细工具调用、错误正文和 diff 仍由对话渲染器展示。
- 状态栏只显示摘要及必要错误状态。

## 显示与通知边界

- 使用 window-local `winbar`；如确需第二行信息，可使用 window-local statusline。
- 不修改用户全局 `statusline`、`winbar` 或其他 window 的配置。
- `vim.notify()` 只用于需要用户注意且可操作的错误。
- 流式 delta、普通连接状态变化和工具进度不逐条发送通知。
- 状态更新由模型事件驱动，不在每次重绘时重新请求服务。
- spinner 使用低频定时器，窗口隐藏、状态停止或模块销毁时停止。
- 状态文本需要转义，避免会话标题中的特殊字符破坏 winbar 表达式。

## 生命周期与集成

- 从子任务 05C 的会话状态模型订阅状态，不直接解析 SSE chunk。
- 从子任务 03 获取输出和输入 window，不自行创建侧边栏。
- window 被手动关闭后停止无效刷新；重建后重新附着。
- 切换会话时取消旧会话订阅，避免旧事件覆盖新状态。
- 输出或输入 window 任一不可用时，另一区域仍可安全更新。

## 建议接口

```lua
status.attach({
  message_window = message_window,
  input_window = input_window,
})
status.update(snapshot)
status.set_connection(state)
status.set_submission(state)
status.set_execution(state)
status.detach()
```

具体实现可以只保留统一的 `update()`，但必须支持局部状态合并，避免一个维度更新时覆盖其他字段。

## 独立测试

### 单元测试

- 各状态快照生成正确、可读的显示文本。
- 缺失会话、Agent 或 Model 字段时安全降级。
- 局部更新不会清除其他状态维度。
- 特殊字符和超长会话标题不会破坏 winbar。
- `idle`、`streaming`、`tool_running`、`reconnecting`、`waiting_permission` 和 `failed` 展示明确且互不混淆。
- 等待权限时有持久、可见提示，不会被后续普通工具进度静默清除。
- 旧会话事件不会覆盖当前会话状态。

### Headless Neovim 测试

- 输出和输入 window 使用各自的 window-local 状态。
- 普通代码 window 的 statusline/winbar 不受影响。
- window 隐藏后 spinner 停止，重建后状态恢复。
- 输入 window 被关闭时输出状态仍能更新，反之亦然。
- `detach()` 后不再刷新或访问无效 window。
- 普通状态变化不会调用 `vim.notify()`，关键错误按约定通知。

### 集成验证

使用子任务 05C 的假模型事件模拟提交、流式输出、工具执行、等待权限、断线重连、失败和会话切换，验证完整状态变化；再与子任务 03 集成验证双窗口显示。

## 完成标准

- 状态模块可使用假模型独立开发和测试。
- 状态显示不影响全局或其他 window 配置。
- 会话切换、window 重建和 detach 测试全部通过。
- 连接、提交和执行状态准确，详细内容仍由对话 block 承担。
- 不包含补全、HTTP、SSE 或全局快捷键逻辑。
