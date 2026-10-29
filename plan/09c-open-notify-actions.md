# 子任务 09C：Neovim Open 与 Notify actions

## 目标

实现 neovim_open 和 neovim_notify 的编辑器 action handler，通过 09A protocol 契约接收已验证参数，不实现 HTTP server、registry、TypeScript 插件或 diff。

## 文件所有权

允许修改：

```text
lua/opencode/tools/open.lua
lua/opencode/tools/notify.lua
tests/headless/tools/open/**
tests/headless/tools/notify/**
```

禁止修改 server、registry、diff、opencode-plugin 和公共装配文件。

## 独立闭环

在 headless Neovim 中直接调用 handler，验证打开文件、复用 buffer、定位和通知。无需网络或 OpenCode。

## Open

- 相对路径按项目根解析并限制在项目内。
- 已打开复用 buffer，支持可选 line/column。
- 文件不存在、越界路径、无效位置返回结构化错误。
- 不修改文件内容。

## Notify

- 支持 info/warn/error，默认 info。
- 使用 vim.notify，限制空消息和消息大小。
- 返回成功结果，不泄露请求认证信息。

## 独立测试

- 相对/绝对路径、项目边界和不存在文件。
- 已加载 buffer 复用及正确行列。
- 多 window 情况下目标 window 策略确定。
- notify 级别、空消息、超长消息和 vim.notify 调用。
- 错误结构满足 09A，handler 不解析 HTTP。

## 完成标准

- 两个 action 的 headless 测试全部通过。
- 可注入 09A server，无网络/TypeScript 依赖。
