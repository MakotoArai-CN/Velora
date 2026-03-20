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
velora list all

# 应用站点配置到指定工具
velora use <别名>         # 自动检测类型
velora cx <别名>          # 应用到 Codex
velora cc <别名>          # 应用到 Claude Code
velora oc <别名>          # 应用到 OpenCode

# 浏览站点的全部模型
velora models <别名>      # 或 velora m <别名>

# 设置选项
velora set model_check off    # 或 velora s mc off  关闭模型检测
velora set list_latency off   # 或 velora s ll off  关闭延迟检测

# 安装 / 卸载
velora install
velora uninstall

# 检查并自动更新
velora --update
```

### 命令缩写

| 完整命令 | 缩写 | 说明 |
|----------|------|------|
| `set` | `s` | 设置选项 |
| `models` | `m` | 浏览模型 |
| `list` | `ls` | 站点列表 |
| `del` | `rm` | 删除站点 |

### 设置选项缩写

| 完整选项 | 缩写 | 说明 |
|----------|------|------|
| `model_check` | `mc` | use 时是否检测模型（默认 on） |
| `list_latency` | `ll` | list 时是否检测延迟（默认 on） |

## 用法示例

```bash
velora add openai
velora add cx openai https://api.example.com/v1 sk-xxx
velora add cc claude https://api.example.com sk-ant claude-opus-4-6
velora use openai
velora cx openai
velora cc claude
velora m openai          # 浏览 openai 站点的全部模型
velora s mc off          # 关闭模型检测，use 更快
```

## 模型配置

- 每个站点都支持自定义 `model`
- 未手动指定时，会自动使用并写入默认模型：
- `cc` -> `claude-opus-4-6`
- `cx` -> `GPT-5.4`
- `oc` -> `GPT-5.4`

## 用户数据位置

- `~/.velora/sites.json`：站点配置（类型、URL、API Key、模型）
- `~/.velora/settings.json`：用户设置（model_check、list_latency 等）
- `~/.velora/bin`：已安装的可执行文件

## LICENSE

本项目使用 [AGPL-3.0](LICENSE) 协议，未经允许不得用于商业用途，二次修改请务必保留版权声明。

[![Star History Chart](https://api.star-history.com/svg?repos=MakotoArai-CN/Velora&type=date&legend=top-left)](https://www.star-history.com/#MakotoArai-CN/Velora&type=date&legend=top-left)
