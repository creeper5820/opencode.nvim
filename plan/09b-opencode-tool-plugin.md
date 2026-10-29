# 子任务 09B：OpenCode TypeScript 工具插件

## 目标

作为可选 companion，使用 @opencode/plugin 注册 neovim_open、neovim_notify、neovim_diff，按 09A registry/RPC 契约发现正确 Neovim 实例并发送可取消请求，不实现 Neovim action。

该包不得成为 Neovim 主插件安装、setup、health 或核心聊天的硬依赖；主插件在包不存在时必须正常工作。companion 自身也不得要求 Neovim 必须在线才能被 OpenCode 加载，只有实际工具调用时才返回无可用实例错误。

## 文件所有权

允许修改：

```text
opencode-plugin/**
tests/opencode-plugin/**
```

禁止修改 `lua/`、Neovim 测试和其他计划文件。

## 独立闭环

使用假 Neovim HTTP server 和临时 registry 验证三个工具注册、schema、实例路由、认证、错误及取消；真实 OpenCode 加载验证由 10 集成。

## 范围

- Plugin.define + ctx.tool.transform 注册三个工具及输入 schema。
- 优先使用 ctx.location.project.canonical，规范化符号链接和路径。
- 无实例返回错误；同项目多实例首版返回明确多实例错误。
- 调用前健康检查并处理 stale registry。
- 所有请求带 token，使用 context.signal 取消 fetch。
- 工具描述明确 diff 只展示不写盘。
- 提供 opencode.json(c) 本地目录/发布包加载示例；测试只在隔离 OpenCode 实例的测试专用配置中加载，禁止修改用户配置。

## 独立测试

- 三个工具名称、description、input schema 注册正确。
- subdirectory/canonical/符号链接路由正确。
- 无实例、多实例、stale、认证失败和超时错误可读。
- 不同项目不会误路由。
- context.signal 中止等待请求。
- 结果及日志不泄露 token。
- 假 server 验证 open/notify/diff envelope。

## 完成标准

- TypeScript 单元及假 server 集成测试通过。
- 包可被 opencode.json(c) 加载，工具 list 可验证。
- 不依赖聊天 UI 或真实 Neovim action 实现。
