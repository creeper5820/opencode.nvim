# 子任务 05C：结构化 block 投影与状态归并

## 目标

将 05B 的历史快照和有序原生事件归并为稳定 block 树及会话状态快照，为 06 渲染器和 08 状态显示提供纯数据接口。不得解析 SSE、发起网络或操作 UI。

## 文件所有权

允许修改：

```text
lua/opencode/blocks.lua
lua/opencode/state.lua
tests/unit/blocks/**
tests/unit/state/**
tests/fixtures/conversation/**
```

禁止修改 `events.lua`、`sync.lua`、`session.lua`、`client.lua` 和 render/UI 文件。

## 独立闭环

使用纯 fixtures 重放历史及事件，验证文本、工具、diff、权限、重连代际和未知事件最终形成完整、有序、无重复的 block 树。

## Block 契约

```lua
{
  id = "稳定 ID",
  message_id = "所属消息",
  parent_id = "父 block 或 nil",
  children = {},
  sequence = 1,
  type = "user|assistant|reasoning|tool|diff|status|unknown",
  status = "streaming|completed|failed|...",
  content = "完整文本或结构化内容",
  metadata = {},
  revision = 1,
}
```

- 工具输入、输出和 diff 归属工具 block，工具归属 assistant message。
- 历史与实时重叠按稳定原生 ID 去重。
- sequence 或等价排序保证稳定时间线。
- revision 仅在对应 block 变化时递增。
- fold/view 等 UI 状态不得进入模型。
- 未知事件保留 generic block。
- 会话状态覆盖 connection、submission、execution 和 waiting_permission。

## Fixture spike

冻结完整 schema 前，先在测试单独拉起的隔离 Neovim/OpenCode 及临时项目中采集历史/事件，再用脱敏 fixtures 验证：原生 ID、diff/hunk 数据、工具父子关系和权限事件。不得读取用户会话或项目作为测试输入。信息不足时明确转换来源，不在 renderer 猜测。fixture 文件只放在本任务 fixtures 目录。

## 独立测试

- 文本 delta 更新同一 assistant block。
- 工具输入/输出/diff 更新对应父子节点。
- 多文件、多 hunk diff 保留完整内容。
- reasoning、retry、compaction、错误映射正确。
- permission.asked/replied 驱动 waiting_permission。
- 历史和实时重叠不重复，generation 旧事件被忽略。
- 顺序稳定，revision 只影响变化节点。
- 高频通知可合批，但模型内容不丢失。
- 未知事件可恢复原始详情。
- 相同 fixture 重放得到确定性相同模型。

## 完成标准

- 纯 fixtures 测试全部通过，无网络/UI 依赖。
- block 与状态快照契约满足 06/08。
- 真实 fixture spike 已验证关键假设。
