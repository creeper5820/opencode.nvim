# 子任务 06：TUI 对齐的结构化对话渲染器

## 目标

将子任务 05C 的结构化 block 模型渲染到子任务 03 的只读输出 buffer，使用 Neovim 原生 folds、extmarks 和 window 行为展示文本、工具调用、diff 及状态，并对齐 OpenCode TUI 的对话展示语义。

本任务不实现 SSE、会话恢复或 prompt 网络请求。开发时使用假 block 模型即可独立完成渲染闭环。

## 文件所有权

允许修改 `lua/opencode/render/**`、`tests/unit/render/**` 和 `tests/headless/render/**`。禁止修改 UI、blocks/state、events 和公共装配文件；通过假 block 树及 03 已冻结的 buffer/window 契约开发。

## 独立闭环

完成后，可以向渲染器输入一组静态或持续变化的 block，在真实 Neovim 输出 window 中查看和折叠消息、工具输入输出及内联 diff；增量更新不会重置用户折叠状态或抢回滚动位置。全部行为可使用脱敏 TUI fixtures 独立测试。

## 核心原则

- 渲染结构化 block，不解析终端 ANSI，也不把 SSE 原始文本直接打印到 buffer。
- 聊天时间线中内联展示工具调用及其结果，不用摘要加外部窗口替代。
- Diff 默认仍是工具结果 block 的一部分，保留文件头、hunk、上下文和增删行。
- 原生分屏 diff 只允许作为用户主动触发的附加操作，或 `neovim_diff` 主动工具自身的行为，不能替代聊天内 diff。
- 不静默丢弃或截断内容；存在显示限制时必须提供明确的完整内容展开入口。
- 首版不追求像素级复刻 TUI，但消息结构、内容完整性和交互语义必须对齐。

## Block 展示规则

| Block | 展示方式 |
| --- | --- |
| 用户消息 | 展开的普通文本 |
| Assistant 文本 | Markdown 风格文本与代码块 |
| Reasoning | 可折叠，默认状态根据 TUI 对齐 fixtures 确定 |
| 工具调用 | 标题显示工具、状态和参数摘要；输入、输出位于同一时间线并可折叠 |
| 工具错误 | 错误摘要可见，完整详情可展开 |
| Diff | 在工具结果内联展示完整文件头、hunk、上下文和增删行，可折叠 |
| Retry / Compaction | 与 TUI 语义一致的状态块 |
| 未知事件 | 通用可折叠详情，保留原始结构供检查 |

示例：

```text
▼ edit  src/example.lua                         ✓
  ▼ Diff
    @@ -10,4 +10,5 @@
       local value = get_value()
    -  return value
    +  return value or default
    +end
```

该示例说明 diff 必须留在聊天 block 中，不要求固定字符样式与 TUI 完全相同。

## Neovim 原生渲染机制

- 使用 extmarks 管理高亮和需要的虚拟文本。
- Diff 的 `+`、`-`、`@@`、文件头和上下文分别设置高亮。
- 使用原生 folds 折叠工具输入、输出、reasoning 和 diff。
- `za`、`zo`、`zc`、`zR`、`zM` 等操作遵循 Neovim Normal 模式行为。
- 输出 buffer 保持只读，Visual 选择和复制始终可用。
- folds 和 view 属于 window，按 `(window, block_id)` 保存用户折叠状态；同一 buffer 出现在多个 window 时不共享折叠状态。
- 增量替换行后显式重建受影响 window 的 fold，不假设修改 buffer 会保留正确 fold 范围。
- 渲染时维护 block 与 buffer 行区间的映射，只重建受影响区域。
- 在上方插入或删除行时使用锚点/extmark 恢复正在查看的 block；不能只依赖 `winsaveview()` 的行号。
- 不在每次文本 delta 时重绘整个对话。

## 滚动行为

- 用户位于历史底部时，新内容触发自动滚动。
- 用户向上翻页后，流式更新不得抢回滚动位置。
- 用户重新回到底部后恢复自动滚动。
- 展开、折叠和历史重载尽量保持合理的浏览位置。
- 大 block 更新不能让用户正在查看的另一 block 突然移位。

## 长内容策略

- 完整内容始终保留在模型中。
- 长工具输出或 diff 默认可折叠，而不是移出聊天时间线。
- 如需首屏行数限制，必须显示明确的“展开完整内容”状态，且不能静默截断。
- 可提供在独立 scratch buffer 查看完整内容的附加命令，但聊天内原始 block 仍然存在。
- 原生分屏 diff 是附加查看方式，不是默认替代展示。

## TUI 行为对齐验证

从子任务 05C 的真实会话记录建立脱敏 fixtures，至少覆盖：

- 普通文本流式输出。
- Reasoning。
- 工具输入流、执行中、成功和失败。
- 内联 diff 的多个文件和多个 hunk。
- 长输出与折叠。
- Retry 和 Compaction。
- 未知新事件。

比较 Neovim 渲染结果与 OpenCode TUI 的消息结构、内容完整性和交互语义。像素、空格和主题差异不属于首版对齐目标。

## 建议接口

```lua
renderer.attach({
  buffer = message_buffer,
  window = message_window,
})
renderer.reset(blocks)
renderer.apply_change(change)
renderer.open_block(block_id)
renderer.close_block(block_id)
renderer.toggle_block(block_id)
renderer.detach()
```

- 输入为模型及增量变更，不接收原始 SSE chunk。
- fold 状态、行区间和 extmark 命名空间由渲染器自己维护。
- `detach()` 清理订阅和 UI 状态，不销毁会话模型。

## 独立测试

### 渲染单元与 headless 测试

- 各类 block 生成正确文本、行区间和高亮。
- Diff 的增删行、上下文和 hunk 完整内联显示。
- 工具结果不会只剩摘要或被默认转移到分屏 window。
- 展开、折叠和批量折叠可用。
- 增量更新保持各 window 独立的用户折叠状态。
- 同一 buffer 的两个 window 可以分别折叠，互不影响。
- 在查看位置上方增删行后，锚点仍能恢复正在查看的 block。
- 更新一个 block 不重写无关 block。
- 长内容限制可见且能展开，不发生静默截断。
- 用户向上浏览时增量更新不自动跳到底部。
- Visual 选择和复制不受只读渲染影响。
- 未知事件渲染为可检查的通用详情。

### 集成验证

将子任务 05C 的 fixtures 依次输入渲染器，模拟流式更新、历史重置和工具状态变化，验证最终视图及中间状态。再与子任务 03 集成，验证双 window 下快捷键互不干扰。

## 完成标准

- 渲染器可只依赖假 block 模型独立开发和测试。
- 工具调用、diff、reasoning 和错误均在聊天时间线中正确展示。
- 折叠状态、增量更新和滚动行为测试全部通过。
- 真实 TUI fixtures 的结构化行为对齐验证通过。
- 不包含 HTTP、SSE、会话恢复或全局快捷键逻辑。
