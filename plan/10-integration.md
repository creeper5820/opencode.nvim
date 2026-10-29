# 子任务 10：公共装配与端到端集成

## 目标

在各独立模块完成后统一完成依赖装配、配置与快捷键注册、文档和真实端到端验证。此任务是除 01 外唯一可以修改公共装配入口的子任务，避免并行 coder 冲突。

## 文件所有权

允许修改：

```text
lua/opencode/init.lua
lua/opencode/config.lua
plugin/opencode.lua
doc/**
README.md
tests/integration/e2e/**
```

为修复集成缺陷需要修改其他任务模块时，必须由协调者重新委托对应 owner，不在本任务直接越界重写。

## 前置条件

- 01–09 各自独立测试已通过。
- 公共契约没有未解决分歧。
- 05C 已提供真实脱敏 fixtures。
- 09A/09B 的 registry 与 RPC 版本一致。

## 装配范围

- 创建 transport/client/session/sync/state。
- 创建双窗口 UI，附着 renderer/completion/status。
- 注册选择操作、输入提交和工具 server/actions。
- 注册命令、可配置快捷键及禁用逻辑。
- 确保 setup 重复调用、hide/show、detach 和退出清理正确。
- README/doc 写明本地服务、可选 OpenCode companion 的加载方式、首版限制和测试方式。
- companion 缺失时不得 setup 失败或影响核心功能；health 仅给非阻塞 info。核心测试必须覆盖 companion 完全不存在的情况，主动工具 e2e 在 companion 未安装时明确 skip。

## 隔离测试环境

必须复用 01 的隔离测试 harness：每次 e2e 在 `/tmp/opencode` 下创建独立临时目录、XDG 目录和项目，单独启动并登记测试 Neovim 与 OpenCode 服务，使用独立端口、service 注册位置和测试专用插件配置。

禁止连接或操作用户默认 OpenCode service、正在运行的 Neovim、用户配置和真实项目。清理只针对本测试登记的 PID、端口、注册项和临时目录；服务未显式配置时测试必须 skip，不得回退到用户实例。

## 独立集成测试

1. 在隔离环境中启动真实本地 OpenCode V2 服务。
2. 打开侧边栏并确保项目会话。
3. 普通 prompt 被接纳，草稿清空，流式文本和工具/diff 正确显示。
4. command 补全提交命中 command，而非 prompt。
5. `<leader>os` 不提交；`<leader>oq` 直接提问。
6. 输出/输入 window 快捷键和补全不干扰普通代码 buffer。
7. 折叠、滚动、状态栏、waiting_permission 和重连正确。
8. 加载 OpenCode TypeScript 工具插件，真实调用 open/notify/diff。
9. 多 Neovim 实例不串项目，认证失败有可读错误。
10. 重复 setup、开关窗口和退出无重复订阅、进程或 listener。

## 版本交付

基本功能及上述验证完成后，在仓库根目录初始化 Git，检查 `.gitignore`，确保不提交测试临时文件、依赖目录、token、用户数据或隔离环境产物；审查最终 diff 后创建一次包含全部基本功能的提交。不得提交到远程或修改用户全局 Git 配置。

## 完成标准

- 全部独立模块测试及 e2e 测试通过。
- README 和 doc 与实际配置/行为一致。
- 00 总览状态可根据各任务验收结果更新。
- 不通过绕过独立模块边界或引入终端按键 hook 完成集成。
