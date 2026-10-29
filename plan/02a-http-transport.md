# 子任务 02A：vim.uv 原生 HTTP/1.1 transport

## 目标

实现独立、异步、可取消的本地 HTTP/1.1 transport，为 OpenCode API client、SSE 同步器提供普通响应和 chunk 流。不得实现 OpenCode endpoint、当前会话或 UI 逻辑。

## 文件所有权

允许修改：

```text
lua/opencode/net/http.lua
lua/opencode/net/parser.lua
tests/unit/net/**
tests/integration/net/**
```

禁止修改 `client.lua`、`init.lua`、`config.lua`、`plugin/` 和其他任务目录。

## 独立闭环

使用本地假 TCP server 发起普通及流式请求，验证半包、chunked、超时、取消和异常断开。无需安装或启动 OpenCode。

## 范围

- 使用 `vim.uv.tcp_*`，不依赖 curl、Node.js 或 LuaSocket。
- 支持 method、URL/query、headers、body 和 timeout。
- 解析状态行、响应头、`Content-Length`、chunked body。
- 普通请求返回完整 response；流式请求持续交付 body chunk。
- 每个请求返回幂等 cancel；结束后回调最多一次。
- 处理半包、连接失败、异常断开、无效响应和超时。
- 首版只支持 `http://`，HTTPS 返回明确 TLS 不支持错误。
- 不直接调用 window/buffer；需要 Neovim API 的回调由上层调度。

## 建议接口

```lua
http.request({
  method = "GET",
  url = "http://127.0.0.1:4096/api/info",
  headers = {},
  body = nil,
  timeout = 5000,
}, callback)

local cancel = http.stream({
  method = "GET",
  url = "...",
  headers = {},
}, {
  on_headers = function(response) end,
  on_chunk = function(chunk) end,
  on_done = function(err) end,
})
cancel()
```

可调整实现细节，但 02B 和 05B 不得依赖 parser 内部状态。

## 独立测试

- 请求行、Host、Content-Length 和自定义 header 正确。
- URL 中空格、Unicode 和特殊字符被正确编码。
- 响应头/body 在任意字节位置拆包均可解析。
- Content-Length 和 chunked 完整响应正确。
- chunked 流多次 on_chunk，结束后 on_done 恰好一次。
- 非 2xx 保留状态及 body，由 API 层决定错误映射。
- 无效状态行、错误 chunk size 和提前 EOF 返回统一错误。
- timeout、connect error 和 cancel 清理 socket/timer。
- cancel 幂等，取消后不再交付 chunk。
- HTTPS 不静默降级为 HTTP。

## 完成标准

- 所有 net 测试可单独运行并通过。
- 无外部 HTTP 进程依赖，无 OpenCode/UI 代码。
- transport 接口和错误结构满足 00 契约，可供 02B/05B 并行使用。
