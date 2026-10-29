# 子任务 09A：Neovim 工具 HTTP server 与实例注册

## 目标

实现仅供 OpenCode 工具调用的 Neovim 本地 HTTP server、认证、请求分发和实例注册，不实现 open/notify/diff action，也不实现 TypeScript 工具插件。

## 文件所有权

允许修改：

```text
lua/opencode/tools/server.lua
lua/opencode/tools/registry.lua
lua/opencode/tools/protocol.lua
tests/unit/tools/server/**
tests/unit/tools/registry/**
tests/integration/tools/server/**
```

禁止修改 `tools/open.lua`、`notify.lua`、`diff.lua`、`opencode-plugin/` 和公共装配文件。

## 独立闭环

启动随机端口 server，通过假 action handler 和 HTTP client 验证认证、JSON envelope、请求限制、注册及 stale 清理，无需真实 OpenCode。

可选性要求：Neovim 主插件不得 require 或探测 npm 包才能启动。companion 未安装时不应产生启动错误；工具 server 可保持未启动或由配置启用，health 仅以 info 说明主动工具不可用。

## Server 范围

- vim.uv 监听 127.0.0.1 随机端口。
- 包括 /health 在内全部接口默认认证。
- 限制 header/body 大小、读取超时和慢连接。
- 解析半包、JSON 和固定 RPC envelope，返回结构化错误。
- action handler 通过依赖注入注册，server 不直接操作 buffer。
- Neovim API 调用由 action 层 schedule；server 不在 libuv 回调中直接编辑。
- start/stop 幂等，退出关闭 socket/timer。

建议路由：GET /health，POST /tools/open、/tools/notify、/tools/diff。

## Registry 范围

注册 instance_id、project_root、url、token、pid；目录 0700、文件 0600、原子写入。规范化项目路径，健康检查识别 stale entry。token 不写日志或响应。

## 独立测试

- 随机端口、start/stop 和并发请求正确。
- 缺失/错误 token（含 health）被拒绝。
- 半包、重复/冲突 header、无效 JSON、超大 body、慢连接和异常断开正确。
- handler 成功/失败映射统一 envelope，不泄露 token。
- registry 权限、原子写入、路径规范化和 stale 清理正确。
- 多实例注册不互相覆盖。

## 完成标准

- server/registry 独立测试全部通过。
- RPC/registry schema 可供 09B/09C/09D 并行使用。
- 不包含具体 action 或 TypeScript 代码。
