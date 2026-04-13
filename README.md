# Velora

`Velora` 是一个使用 Zig 编写的多站点 API Key 管理器，用于统一管理并快速切换 Codex、Claude Code、OpenCode 等工具的 API Key 配置。

## 支持平台

- Windows：`x86_64`、`i386`、`aarch64`
- macOS：`x86_64`、`aarch64`
- Linux（glibc）：`x86_64`、`aarch64`、`arm`、`i386`、`loongarch64`、`ppc64le`、`riscv64`、`s390x`
- Alpine Linux（musl）：`x86_64`、`aarch64`、`arm`
- FreeBSD：`x86_64`、`aarch64`

## 支持的目标工具

| 类型 | 工具 | 配置方式 |
|------|------|----------|
| `cx` | OpenAI Codex | `~/.codex/config.toml`（`base_url` + `OPENAI_API_KEY`） |
| `cc` | Claude Code | `~/.claude/settings.json`（`ANTHROPIC_AUTH_TOKEN`） |
| `oc` | OpenCode | `~/.config/opencode/opencode.json` |
| `nb` | Nanobot | `~/.nanobot/config.json` |
| `ow` | OpenClaw | `~/.openclaw/openclaw.json` |

## 构建

```bash
# 构建 Debug 版
zig build -Doptimize=Debug
# 构建最小版本
zig build -Doptimize=ReleaseSmall
# 构建安全版本
zig build -Doptimize=ReleaseSafe
# 构建性能版本
zig build -Doptimize=ReleaseFast

# 测试
zig build test
```

## 一键安装

### Linux x86_64

```bash
curl -fsSL -o velora-linux-x86_64 https://github.com/MakotoArai-CN/Velora/releases/latest/download/velora-linux-x86_64 && chmod +x ./velora-linux-x86_64 && ./velora-linux-x86_64 --install
```

### Alpine x86_64

```bash
curl -fsSL -o velora-alpine-x86_64 https://github.com/MakotoArai-CN/Velora/releases/latest/download/velora-alpine-x86_64 && chmod +x ./velora-alpine-x86_64 && ./velora-alpine-x86_64 --install
```

### macOS Apple Silicon

```bash
curl -fsSL -o velora-macos-aarch64 https://github.com/MakotoArai-CN/Velora/releases/latest/download/velora-macos-aarch64 && chmod +x ./velora-macos-aarch64 && ./velora-macos-aarch64 --install
```

### FreeBSD x86_64

```bash
fetch -o velora-freebsd-x86_64 https://github.com/MakotoArai-CN/Velora/releases/latest/download/velora-freebsd-x86_64 && chmod +x ./velora-freebsd-x86_64 && ./velora-freebsd-x86_64 --install
```

### Windows x86_64

```powershell
Invoke-WebRequest https://github.com/MakotoArai-CN/Velora/releases/latest/download/velora-windows-x86_64.exe -OutFile .\velora.exe; .\velora.exe --install
```

安装完成后，新终端即可直接运行：

```bash
velora
```

## 常用命令

```bash
# 添加站点（交互式）
velora add <别名>

# 添加站点（直接指定，可选自定义模型）
velora add <类型> <别名> <URL> <Key> [模型]

# 编辑 / 删除站点
velora edit <别名>
velora del <别名>

# 查看站点列表（含连通性检测）
velora list          # 或 velora ls
velora list -g       # 全局检测（包含已归档站点）
velora list all

# 应用站点配置到指定工具
velora use <别名> [模型]              # 自动检测类型，可选覆盖模型
velora use <类型> <别名> [模型]       # 指定目标工具，可选覆盖模型
velora cx <别名> [模型]               # 应用到 Codex
velora cc <别名> [模型]               # 应用到 Claude Code
velora oc <别名> [模型]               # 应用到 OpenCode
velora nb <别名> [模型]               # 应用到 Nanobot
velora ow <别名> [模型]               # 应用到 OpenClaw

# 浏览站点的全部模型
velora models <别名>      # 或 velora m <别名>

# 设置选项
velora set model_check off                  # 或 velora s mc off
velora set list_latency off                 # 或 velora s ll off
velora set auto_archive on                  # 或 velora s aa on
velora set auto_pick_compatible_model off   # 或 velora s ap off

# 安装 / 卸载
velora install
velora uninstall

# 检查并自动更新
velora --update
```

### 命令缩写

| 完整命令 | 缩写 | 说明 |
| --------- | ---- | ---- |
| `set` | `s` | 设置选项 |
| `models` | `m` | 浏览模型 |
| `list` | `ls` | 站点列表 |
| `del` | `rm` | 删除站点 |

### 设置选项缩写

| 完整选项 | 缩写 | 说明 |
| --------- | ---- | ---- |
| `model_check` | `mc` | use 时是否检测模型（默认 on） |
| `list_latency` | `ll` | list 时是否检测延迟（默认 on） |
| `auto_archive` | `aa` | 是否自动归档不可用站点（默认 off） |
| `auto_pick_compatible_model` | `ap` | 类型不匹配时是否自动选择兼容模型（默认 on） |

## 用法示例

```bash
velora add openai
velora add cx openai https://api.example.com/v1 sk-xxx
velora add cc claude https://api.example.com sk-ant claude-opus-4-6
velora use openai
velora use cc openai claude-opus-4-6
velora oc openai claude-haiku-4-5-20251001
velora nb openai
velora ow openai
velora m openai                              # 浏览 openai 站点的全部模型
velora s mc off                              # 关闭模型检测，use 更快
velora s ap off                              # 关闭类型不匹配时的自动兼容模型选择
```

## 模型配置

- 每个站点都支持自定义 `model`
- 同一个站点也支持按目标工具保存单独的模型覆盖
- 当目标工具与站点原始类型不匹配时，`auto_pick_compatible_model` 默认会先读取远端模型列表，再自动选择该目标工具可用的兼容模型
- `nb` / `ow` 当前按 OpenAI 系列模型自动选择；`oc` 可在 OpenAI / Claude 系列之间选择；`cc` 使用 Claude 系列
- 用户也可以在 `use` 命令后直接追加模型名覆盖本次目标模型
- 未手动指定时，会自动使用并写入默认模型：
  - `cc` -> `claude-opus-4-6`
  - `cx` -> `gpt-5.4`
  - `oc` -> `gpt-5.4`
  - `nb` -> `gpt-5.4`
  - `ow` -> `gpt-5.4`
- `claude-opus-4-6[1m]` 这类带后缀的 Claude 模型会在兼容性检测时自动归一化检查

## 归档与全局检测

- `velora list`：仅检查未归档站点
- `velora list -g`：检查全部站点，包括已归档站点
- `auto_archive` 开启后，不可达站点会自动归档
- 已归档站点在全局检测中恢复可用时会自动取消归档
- `velora list all` 会显示详细信息，并保留归档状态展示

## 用户数据位置

- `~/.velora/sites.json`：站点配置（类型、URL、API Key、主模型、按工具模型覆盖、归档状态、多工具默认设置）
- `~/.velora/bin`：已安装的可执行文件

## LICENSE

本项目使用 [AGPL-3.0](LICENSE) 协议，未经允许不得用于商业用途，二次修改请务必保留版权声明。

[![Star History Chart](https://api.star-history.com/svg?repos=MakotoArai-CN/Velora&type=date&legend=top-left)](https://www.star-history.com/#MakotoArai-CN/Velora&type=date&legend=top-left)
