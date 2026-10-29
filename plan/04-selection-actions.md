# 子任务 04：Visual 选择上下文与两种提问方式

## 目标

统一实现 Visual 选择提取、文件上下文格式化，以及基于同一份选择上下文的两种用户操作：

- `<leader>os`：将代码及上下文追加到侧边栏输入草稿，但不提交。
- `<leader>oq`：打开悬浮输入框，填写问题后直接提交到 OpenCode。

两种入口共享同一套选择上下文实现，避免重复逻辑和不同的格式行为。

## 文件所有权

允许修改 `lua/opencode/context.lua`、`lua/opencode/actions/selection.lua`、`tests/unit/selection/**` 和 `tests/headless/selection/**`。禁止修改 UI、session、client 和公共装配文件；通过假 UI 与假 05A session controller 独立开发。

## 独立闭环

完成后，用户可以：

1. 选择代码并追加到草稿，继续编辑且不触发执行。
2. 选择代码并通过浮窗提问，使 OpenCode 在正确会话中收到完整 prompt。
3. 使用假 UI 和假客户端独立验证全部流程，不依赖 SSE 或流式渲染。

## 共享选择上下文

### 提取内容

- Visual 选择的文本和范围。
- 文件相对路径、起止行号和 filetype。
- 未命名 buffer 的可识别备用名称。
- 触发操作时的选择快照；后续选择变化不影响已打开浮窗。

### 建议格式

````markdown
`path/to/file.lua:10-20`

```lua
selected code
```
````

选中内容包含反引号或 Markdown 代码围栏时，应选择安全围栏，避免上下文提前闭合。

### 共享模块接口

```lua
context.from_selection(buffer, selection)
context.format(selection_context)
actions.send_selection()
actions.question_selection()
```

- `context.lua` 保持为易测试的纯逻辑。
- `send_selection()` 和 `question_selection()` 只组合共享上下文、UI 和客户端接口。
- 两种入口不得各自实现一套选择提取或 Markdown 格式化。

## 入口一：追加到输入草稿

Visual 模式触发 `<leader>os` 后：

1. 获取并格式化选择上下文。
2. 追加到已有草稿之后，不覆盖用户输入。
3. 打开侧边栏并聚焦输入框。
4. 不调用提交回调、prompt API 或其他执行接口。

连续转发多个选择时，按触发顺序追加。

## 入口二：悬浮提问并直接提交

Visual 模式触发 `<leader>oq` 后：

1. 保存同一份选择上下文快照。
2. 在选择附近创建真实可编辑浮动输入框。
3. 用户填写问题并按 `<C-s>`。
4. 将问题和格式化上下文组合后调用 `session.prompt()`。
5. 提交成功后关闭浮窗、打开侧边栏并记录本次用户问题。
6. Normal 模式 `<Esc>` 取消浮窗，不发送请求。

提交文本：

```text
<用户问题>

<由 context.format() 生成的文件与代码上下文>
```

行为约束：

- 问题为空时不提交。
- 防止同一个浮窗重复提交。
- 提交失败时保留浮窗内容并显示错误，允许重试。
- “提交成功”仅表示 prompt 已被服务端接纳，不表示 Agent 执行完毕；不能等待整个执行过程才关闭浮窗。
- 浮窗取消、成功或失败均不修改侧边栏已有草稿。
- 流式回答展示由后续对话任务负责，本任务只需确认 prompt 已成功提交。

## 依赖边界

- 使用子任务 03 的侧边栏草稿和焦点接口。
- 使用子任务 05A 的 `session.prompt()` 完成直接提问，由 session controller 唯一管理 session ID 和项目位置。
- 本任务不调用无状态 client 来另行创建或猜测当前会话，真实服务闭环依赖 05A。
- 自动化测试中 UI 和 session controller 均替换为假实现。
- 不直接消费 SSE，不实现历史渲染或 OpenCode 主动工具。

## 独立测试

### 共享上下文测试

- charwise、linewise、blockwise 以及反向选择的范围和内容正确。
- `selection=exclusive`、多字节字符及字节/字符列位置转换正确。
- 单行和多行选择的行号、相对路径及 filetype 正确。
- 无文件路径、无 filetype、路径包含空格或反引号的 buffer 能正常处理。
- 未保存 buffer 使用当前内存文本，不重新读取磁盘旧内容。
- 特殊字符、反引号和代码围栏不会破坏格式。
- 两种入口生成完全一致的选择上下文。
- 浮窗打开后，原选择变化不会改变已保存快照。

### 草稿入口测试

- 连续选择按顺序追加，已有草稿不被覆盖。
- 触发后侧边栏打开且焦点进入输入框。
- 整个流程的提交回调和网络调用次数均为零。

### 浮窗入口测试

- 空问题不调用客户端。
- 明确提交只调用一次 `session.prompt()`，文本包含问题和代码上下文。
- 取消操作的网络调用次数为零。
- 提交失败保留内容并允许重试。
- prompt 被服务端接纳后浮窗立即关闭且侧边栏打开，不等待 Agent 执行完成。
- 连续打开浮窗不遗留旧 keymap、autocmd 或无效 buffer。
- 浮窗操作不修改侧边栏已有草稿。

### 真实服务验证

在测试单独拉起的隔离 Neovim 与 OpenCode 实例中，针对临时项目的选中代码块执行 `<leader>oq` 并提交问题，通过客户端读取消息，确认 prompt 已进入正确会话；随后验证 `<leader>os` 只生成草稿而不产生新消息。不得使用用户实例或真实项目。

## 完成标准

- 两种选择操作共用同一份上下文实现。
- 草稿与直接提问的独立自动化测试全部通过。
- 直接提问完成真实 OpenCode 服务闭环验证。
- 快捷键统一为 `<leader>os` 和 `<leader>oq`，配置名分别为 `send_selection` 和 `question_selection`。
- 不包含 SSE、流式回答渲染或 OpenCode 主动工具逻辑。
