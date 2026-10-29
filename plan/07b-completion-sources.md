# 子任务 07B：OpenCode 补全源与提交语义

## 目标

实现文件、命令、Agent、Skill 等 OpenCode 补全源及候选转换，插入和提交语义对齐 TUI。依赖 07A source 契约、02B client 和 05A session 接口，不实现 pum 或 window。

## 文件所有权

允许修改：

```text
lua/opencode/completion/sources/**
tests/unit/completion/sources/**
tests/fixtures/completion/**
```

禁止修改 `completion/core.lua`、`client.lua`、`session.lua` 和公共装配文件。若 client 缺少 endpoint，返回协调者，由 02B owner 扩展。

## 独立闭环

使用假 client/session 验证候选查询、插入数据及 prompt/command/附件提交路由；真实 OpenCode 验证由 10 集成。

## 补全源

| 类型 | 数据来源 | 要求 |
| --- | --- | --- |
| 文件 | filesystem list/find | 当前项目内、模糊查询、正确相对路径 |
| 命令 | command API | 名称、说明和 command kind/metadata |
| Agent | agent API | 当前位置可用数据及所需附件结构 |
| Skill | skill API | 当前位置可用数据及所需附件结构 |

- 触发符、插入文本和最终提交表示以 TUI fixtures 为准。
- 普通文本进入 session.prompt；命令进入 session.command 或统一 session.submit。
- 需要结构化附件的候选生成对应数据，不只拼接文本。
- 无法正确表达的类型明确不支持。
- 缓存按项目位置隔离，配置/服务变化可失效。

## 独立测试

- 每个 source 的 query、项目参数和候选转换正确。
- 文件路径含空格/Unicode 时插入正确。
- 命令候选经 session.submit 路由 command，不走 prompt。
- Agent/Skill 结构化字段正确；不支持时降级明确。
- 缓存隔离、失效和 source 错误行为正确。
- candidate metadata 经 07A 契约保留。
- 不直接调用 pum、window 或 buffer。

## 完成标准

- 假 client/session 测试全部通过。
- 文件与命令具备真实服务验证所需完整实现。
- 不修改补全引擎或公共 client/session 文件。
