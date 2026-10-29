# 子任务 09D：Neovim Diff view action

## 目标

实现 neovim_diff 的原生分屏 diff 视图，以当前 buffer（含未保存修改）为基准展示 proposed content，不写盘，并完整恢复 window 状态。独立于聊天内联 diff renderer。

## 文件所有权

允许修改：

```text
lua/opencode/tools/diff.lua
tests/headless/tools/diff/**
```

禁止修改 `render/`、server、registry、open/notify、opencode-plugin 和公共装配文件。

## 独立闭环

直接调用 diff handler，验证当前 buffer 与 proposed scratch 分屏 diffthis、重复打开和关闭恢复，无需网络或 OpenCode。

## 范围

- 目标已加载时使用当前 buffer 内容，不用磁盘旧内容覆盖。
- proposed 写入只读 scratch buffer，保留 filetype。
- 分屏 diffthis，不自动接受或写盘。
- 提供统一 close；重复打开同一目标时复用或安全关闭旧视图。
- 保存并恢复 diff、scrollbind、cursorbind、fold 等 window-local 选项。
- 原 buffer 修改状态和内容不变。
- 输入大小限制由 09A 处理，action 校验必要字段。

## 独立测试

- 磁盘与 buffer 不一致时使用 buffer 内容。
- proposed 正确、原 buffer 不变且不写盘。
- filetype 和只读 scratch 正确。
- 重复 diff 不遗留旧 window/buffer 状态。
- close 恢复原 diff/scrollbind/cursorbind/fold。
- 用户先手动关闭一侧时能安全清理。
- 错误结构满足 09A protocol。

## 完成标准

- headless diff 测试全部通过。
- 不修改聊天 renderer，不包含网络或工具注册逻辑。
