# 子任务 02B：无状态 OpenCode V2 API client

## 目标

基于 02A transport 契约实现无状态 OpenCode API client，封装 endpoint、JSON、API 错误和流式事件 chunk，不选择当前会话，不解析 SSE，不操作 UI。

## 文件所有权

允许修改：

```text
lua/opencode/client.lua
lua/opencode/api/**
tests/unit/client/**
tests/integration/client/**
```

禁止修改 `net/`、`session.lua`、`events.lua`、`init.lua` 和其他任务目录。通过依赖注入使用 transport。

## 独立闭环

使用假 transport 验证全部请求和错误映射；再用测试单独启动的隔离 OpenCode 服务完成 session 创建、prompt、command、消息读取的冒烟测试。无需 UI、SSE parser 或 session controller。禁止连接用户默认 service，隔离要求遵循 00。

## API 范围

| 端点 | 能力 |
| --- | --- |
| `GET /api/info` | 服务信息 |
| `GET /api/session` | 按 directory 等条件列出会话，不自动选择 |
| `POST /api/session` | 在指定位置创建会话 |
| `GET /api/session/{sessionID}/message` | 获取消息 |
| `POST /api/session/{sessionID}/prompt` | 提交 prompt |
| `POST /api/session/{sessionID}/command` | 执行 command |
| `POST /api/session/{sessionID}/interrupt` | 中断当前执行，支持可选 resume |
| `GET /api/event` | 返回流式 chunk 与 cancel |

07B 可在独立 source 模块调用 filesystem、command、agent、skill API；如需扩展 client，应只修改本任务明确分配的文件，并提前冻结方法签名。

## 建议接口

```lua
client.info(callback)
client.list_sessions({ directory = root }, callback)
client.create_session({ directory = root }, callback)
client.list_messages(session_id, callback)
client.prompt(session_id, { text = text }, callback)
client.command(session_id, { name = name, text = arguments }, callback)
client.interrupt(session_id, { resume = false }, callback)
client.stream_events({ types = types }, handlers)
```

要求：

- 需要 session ID 的方法必须显式传入。
- 项目位置随请求传递，不保存隐式当前项目。
- 支持额外认证 header 和请求取消。
- 非 2xx、无效 JSON 和 transport error 转为统一 API error。
- stream_events 只交付原始 SSE bytes/chunks，不解析事件。

## 独立测试

- 每个 endpoint 的 method、path、query、header、body 正确。
- session ID 和 directory 被正确编码。
- client 不缓存或自动选择 session ID。
- prompt 和 command 命中不同端点。
- 非 2xx、错误 JSON 和 transport error 映射正确。
- 取消向下传递到假 transport。
- stream_events 原样交付 chunk，不在 client 内归并事件。
- 真实 OpenCode 冒烟覆盖 create/prompt/messages/command。

## 完成标准

- 假 transport 测试与真实服务冒烟均通过。
- 无 session controller、SSE parser、window/buffer 逻辑。
- 不修改 02A；transport 接口不足时返回协调者。
