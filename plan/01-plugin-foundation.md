# 子任务 01：插件骨架、配置与健康检查

## 目标

建立可安装、可加载、可测试的 Neovim Lua 插件骨架，统一后续子任务使用的配置和模块边界。

本任务不涉及 OpenCode 网络请求，也不实现具体聊天 UI。

## 文件所有权

允许修改 `lua/opencode/init.lua`、`lua/opencode/config.lua`、`lua/opencode/health.lua`、`plugin/opencode.lua`、`tests/minimal_init.lua`、`tests/support/**`、`tests/unit/config/**` 和 `tests/unit/health/**`。其他 coder 不得修改这些公共装配文件；最终业务 wiring 由 10 完成。

## 独立闭环

完成后，用户能够：

1. 通过插件管理器加载 `opencode.nvim`。
2. 调用 `require("opencode").setup(...)` 自定义配置。
3. 使用 `:checkhealth opencode` 检查 Neovim 版本和 `vim.uv` 等核心运行环境。
4. 在 headless Neovim 中加载插件并验证配置行为。

## 范围

- 建立 `lua/opencode/`、`plugin/`、`tests/` 和 `doc/` 目录。
- 实现 `init.lua` 的 `setup()` 和公共入口。
- 实现 `config.lua` 的默认配置、深度合并和校验。
- 实现 `health.lua`。
- 建立 headless Neovim 测试入口。
- 在 `tests/support/` 提供共享隔离测试 harness：创建独立 XDG 目录、shada、临时项目及测试 Neovim；登记并定向清理测试 PID，支持后续独立 OpenCode 服务、端口和注册位置。
- harness 不连接用户 Neovim/OpenCode，不加载或改写用户配置，失败/中断清理也只处理本测试创建的资源。
- 在 README 写明最低 Neovim 版本、测试隔离规则；核心 transport 不依赖外部 HTTP 进程。

## 默认配置

```lua
require("opencode").setup({
  server = {
    url = "http://127.0.0.1:4096",
    headers = {},
  },
  project = {
    root = nil, -- 首次创建会话时根据当前文件或 cwd 推断并固定
  },
  sidebar = {
    width = 48,
    input_height = 8,
  },
  keymaps = {
    toggle = "<leader>oo",
    send_selection = "<leader>os",
    question_selection = "<leader>oq",
    submit = "<C-s>",
  },
})
```

## 模块约定

```text
lua/opencode/
├── init.lua
├── config.lua
└── health.lua
plugin/opencode.lua
tests/
```

- 具体功能由后续模块实现，`init.lua` 不应堆积业务逻辑。
- 配置项应允许覆盖；快捷键设为 `false` 表示禁用，省略或 `nil` 表示继承默认值。
- 本任务不注册尚未实现且会报错的快捷键。
- 首版 server URL 接受本地 `http://`；`https://` 在 TLS transport 实现前给出明确的不支持错误。

## 独立测试

### 自动化

- 不调用 `setup()` 时可以使用默认配置加载。
- 用户配置只覆盖指定字段，其余默认值保持不变。
- 非法 URL、窗口尺寸和快捷键类型会给出明确错误。
- `false` 能禁用快捷键，且不会被默认配置重新覆盖。
- 省略快捷键字段时继承默认值。
- headless Neovim 能重复加载插件，不产生重复命令或 autocmd。
- 测试 harness 使用独立 XDG/shada/临时项目，证明不会读取或写入用户配置与数据。
- harness 只清理登记的测试进程和资源，异常退出后不会终止或删除用户实例及文件。
- 未配置隔离真实服务时，相关测试明确 skip，不回退用户默认服务。

### 手动验证

- 在测试单独拉起、使用隔离 XDG/shada 的专用 Neovim 中加载插件，不读取用户配置。
- 在该专用实例执行 `:checkhealth opencode`，验证 Neovim 版本、`vim.uv` 和本地 server URL 配置检查。

## 完成标准

- 插件可加载，配置行为符合上述约定。
- 健康检查能发现不满足要求的核心运行环境。
- 自动化测试可单独运行且全部通过。
- 不依赖任何其他子任务的实现。
