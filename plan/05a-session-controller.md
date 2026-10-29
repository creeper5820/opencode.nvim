# 子任务 05A：Session controller 与提交路由

## 目标

作为当前 Neovim 项目会话的唯一所有者，负责项目固定、会话创建/恢复、prompt/command 路由和提交状态。不得解析 SSE、生成 block 或操作 UI。

## 文件所有权

允许修改：

```text
lua/opencode/session.lua
lua/opencode/session_store.lua
tests/unit/session/**
tests/integration/session/**
```

禁止修改 `client.lua`、`state.lua`、`blocks.lua`、`events.lua` 和公共装配文件。

## 独立闭环

使用假 client 验证项目根目录、会话记录恢复、创建、prompt/command/submit 和异步状态；真实 OpenCode 冒烟可在 10 统一完成。

## 职责

- 首次使用时确定并固定项目根目录，后续 cwd/文件变化不改变当前会话位置。
- 优先恢复插件为该 Neovim 项目记录的 session ID，并验证存在及位置匹配。
- 无有效记录时创建新会话，不从多个历史会话中任意选择最近一个。
- 对外提供 ensure/get_snapshot/prompt/command/submit。
- 普通文本走 prompt；识别为 OpenCode 命令的输入走 command。
- Agent/Skill 等结构化输入使用对应字段，不仅拼接文本。
- 成功表示服务端接纳，不表示 Agent 执行完成。
- 会话切换或销毁后，旧异步结果不得提交给新会话调用者。

## 建议接口

```lua
session.ensure(callback)
session.get_snapshot()
session.prompt(text, callback)
session.command(name, arguments, callback)
session.submit(input, callback)
session.interrupt({ resume = false }, callback)
```

`submit` 可接收带 kind 的结构化输入；普通字符串默认 prompt。命令识别规则必须与 07B 的候选及 TUI fixtures 一致。

## 独立测试

- 项目根目录首次确定后保持稳定。
- 有效 session 记录恢复；失效/位置不匹配时创建。
- 多历史会话存在时不任意选择。
- prompt、command 和结构化 submit 调用正确 client 方法。
- ensure 并发调用只创建一个会话。
- 提交中、已接纳、失败状态明确，不能等待 Agent 完成才返回接纳结果。
- 旧会话异步响应被忽略。
- client 错误原样映射为统一错误，不操作 vim.notify。

## 完成标准

- 假 client 测试全部通过。
- 当前 session ID 不出现在 02B、04 或其他模块的私有状态中。
- 不依赖 SSE、block、renderer 或 UI。
