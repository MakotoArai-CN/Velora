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
zig test
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

# 添加站点（直接指定）
velora add <类型> <别名> <URL> <Key>

# 编辑 / 删除站点
velora edit <别名>
velora del <别名>

# 查看站点列表（含连通性检测）
velora list
velora list all

# 应用站点配置到指定工具
velora cx use <别名>      # 应用到 Codex
velora cc use <别名>      # 应用到 Claude Code
velora oc use <别名>      # 应用到 OpenCode

# 安装 / 卸载
velora install
velora uninstall

# 检查并自动更新
velora --update
```

## 用法示例

```bash
velora add openai
velora add cx openai https://api.example.com/v1 sk-xxx
velora cx use openai
velora cc use claude
velora oc use openai
```

## 用户数据位置

- `~/.velora/sites.json`：站点配置（类型、URL、API Key）
- `~/.velora/bin`：已安装的可执行文件

## LICENSE

本项目使用 [AGPL-3.0](LICENSE) 协议，未经允许不得用于商业用途，二次修改请务必保留版权声明。
