# 子任务 07A：Neovim 异步补全引擎

## 目标

实现可附着到 OpenCode 输入 buffer/浮窗的异步补全引擎，负责触发上下文、原生 pum、防抖、取消和过期响应，不实现具体 OpenCode 补全源或提交 API。

## 文件所有权

允许修改：

```text
lua/opencode/completion/core.lua
tests/unit/completion/core/**
tests/headless/completion/core/**
```

禁止修改 `completion/sources/`、`client.lua`、`session.lua`、`ui/` 和公共装配文件。

## 独立闭环

使用假 source 在 headless Neovim 中触发、选择、取消补全，验证连续输入和 detach 后迟到结果不会污染草稿。无需 OpenCode 服务。

## 范围

- 使用 completefunc/omnifunc 与原生 pum。
- source.query 统一异步接口，候选带 kind/text/metadata。
- 查询序号、cancellation、防抖和光标上下文校验。
- buffer/session 切换及 detach 后忽略旧响应。
- 自动/手动触发和最小字符数可配置。
- 不默认占用 Tab、S-Tab、CR、C-n、C-p。
- 所有映射 buffer-local，不实现全局 pum 按键分发。
- 查询失败静默降级，不逐键通知。

## 建议接口

```lua
completion.attach(buffer, { source = source, context = context })
completion.trigger(buffer)
completion.cancel(buffer)
completion.refresh_context(buffer, context)
completion.detach(buffer)
```

## 独立测试

- 触发位置、before_cursor 和候选 start col 正确。
- pum 展示、选择、取消及多行输入行为正确。
- 连续查询只接受最新结果。
- source 慢响应、失败和 cancel 不阻塞编辑。
- detach 后响应和 timer 不再访问 buffer。
- 普通代码 buffer 无 OpenCode 映射。
- 不覆盖默认常用补全键。
- source candidate 原样传递 metadata 给插入/提交层。

## 完成标准

- 假 source 单元和 headless 测试全部通过。
- 无 OpenCode endpoint、session 或 UI 窗口创建逻辑。
- source 契约可供 07B 独立实现。
