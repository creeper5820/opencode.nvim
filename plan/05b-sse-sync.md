# 子任务 05B：SSE 解析与无竞态历史同步

## 目标

将 OpenCode 事件 chunk 流解析为原生事件，并通过“先订阅、暂存、拉历史、合并”的流程输出不会丢失同步间隙事件的历史快照和有序事件批次。不得生成 UI block 或操作 buffer。

## 文件所有权

允许修改：

```text
lua/opencode/events.lua
lua/opencode/sync.lua
tests/unit/events/**
tests/unit/sync/**
tests/integration/sync/**
```

禁止修改 `net/`、`client.lua`、`session.lua`、`blocks.lua`、`state.lua` 和 UI 文件。

## 独立闭环

使用假 stream 和假历史 API 模拟初始同步、实时事件、断线及重连，验证间隙事件不丢失、重复事件可由 05C 识别、其他 location/session 被过滤。

## 范围

- 解析 SSE event/data/id 和空行，处理任意 chunk 边界。
- 建立流后暂存实时事件，再拉取历史，最后释放有序批次。
- 处理 server.connected，按契约触发校验或 resync。
- 过滤目标 session 及 location/project。
- 断线退避重连，重复 start 不创建多个订阅。
- stop/cancel 幂等，停止 timer、stream 和待处理历史回调。
- 输出历史快照和带同步代际 generation 的原生事件；去重及 block 归并由 05C 完成。

## 输出契约

```lua
{
  generation = 1,
  snapshot = { messages = {}, location = {}, session_id = "..." },
  events = {
    { id = "...", sequence = "...", type = "...", data = {} },
  },
}
```

若原生事件没有全局 sequence，不得伪造跨会话排序；保留到达顺序及可用事件 ID，由 05C 按消息树规则归并。

## 独立测试

- 单事件跨 chunk、多事件同 chunk、CRLF/LF 正确。
- 无效数据产生可处理错误，不崩溃。
- 订阅与历史之间的暂存事件最终全部输出。
- 重连创建新 generation，旧 generation 事件被忽略。
- server.connected 处理符合契约。
- 其他 session/location 事件被过滤。
- 重连退避、重复 start、stop 后迟到 chunk 均正确。
- 历史请求失败不会释放不完整批次。

## 完成标准

- 假 stream/历史集成测试全部通过。
- 不依赖 block、renderer、window 或 buffer。
- 输出契约足够 05C 做确定性归并。
