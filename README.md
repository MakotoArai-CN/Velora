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

# 查看站点列表（并行连通性检测，并标记当前使用的工具）
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

# 全自动模型调用测试 / 性能基准
velora test                                 # 并行测试所有站点的模型可调用性
velora test <别名>                          # 测试单个站点
velora test --perf                          # 性能基准（交互式选站，按工具类型筛选）

# 设置选项
velora set model_check off                  # 或 velora s mc off
velora set list_latency off                 # 或 velora s ll off
velora set auto_archive on                  # 或 velora s aa on
velora set auto_pick_compatible_model off   # 或 velora s ap off

# 帮助 / 用法示例
velora --help                               # 命令、选项、设置概览
velora help examples                        # 完整用法示例（已从默认 help 中折叠）

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
| `test` | `t` | 模型调用测试 / 性能基准 |
| `list` | `ls` | 站点列表 |
| `del` | `rm` | 删除站点 |

### 设置选项缩写

| 完整选项 | 缩写 | 说明 |
| --------- | ---- | ---- |
| `model_check` | `mc` | use 时是否检测模型（默认 on） |
| `list_latency` | `ll` | list 时是否检测延迟（默认 on） |
| `auto_archive` | `aa` | 是否自动归档不可用站点（默认 off） |
| `auto_pick_compatible_model` | `ap` | 类型不匹配时是否自动选择兼容模型（默认 on） |
| `list_sort` | `ls` | 默认列表排序: time / alpha / tool / model |

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
velora t                                     # 并行测试所有站点的模型
velora t openai                              # 测试单个站点（带 spinner 进度）
velora t --perf                              # 交互式选择站点 + 性能基准
velora s mc off                              # 关闭模型检测，use 更快
velora s ap off                              # 关闭类型不匹配时的自动兼容模型选择
velora help examples                         # 完整示例（在默认 help 中已折叠）
```

## 当前使用工具识别（list 中的 `[← cc, oc]` 标签）

`velora list` 在每个站点行尾会显示一个加粗的标签，列出当前正指向该站点的工具，例如：

```
  ✓ openai (Claude Code) 234ms [← cc, oc]
  ✓ relay  (OpenCode)    312ms [← nb]
  ✓ gpt    (Codex)       128ms [← cx]
```

匹配规则：分别读取每个工具的真实配置文件 / 环境变量（Codex 读 `~/.codex/config.toml` 与对应 env_key；Claude Code 读 `~/.claude/settings.json` 中的 `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN`；OpenCode、Nanobot、OpenClaw 读各自的 JSON），然后用 `base_url` 或 `api_key` 任一匹配站点（解决了用户手动改 URL 后仍能识别的问题）。

## 并行连通性检测

`velora list` 的连通性检测会并行执行：每个站点独占一个工作线程，主线程轮询 `done` 标志并按到达顺序刷新对应行。整体耗时由"最慢的那个站点"决定（默认 15 秒超时上限），不再随站点数线性增长。

## 模型调用测试与性能基准（v1.1.8 新增）

```bash
velora t              # 并行测试所有未归档站点的模型可调用性
velora t openai       # 单站点测试（单行 spinner，结束后被结果替换）
velora t --perf       # 性能基准模式：交互选择站点 → 并行 benchmark
```

- 默认模式调用 `testModelCall`，根据模型族（Claude / OpenAI / 未知）自动尝试 `/v1/messages`、`/v1/chat/completions`、`/v1/responses` 三种接口。
- `--perf` 模式发送一个约 150 词的真实生成请求（`max_tokens=256`），从响应的 `usage.completion_tokens` / `usage.output_tokens` 解析输出 token 数，计算 `tokens/sec`。
- 进度展示：每个站点一行，前缀 spinner（`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`）+ 已用秒数；完成后该行被原地替换为最终结果（`✓` / `✗`）。
- `--perf` 的交互式选择支持按工具类型筛选（cx / cc / oc / nb / ow / 全部），随后输入逗号分隔索引或 `a` 全选。

## use 时的模型检测优化（v1.1.8）

`velora use` 不再因为 `/v1/models` 端点受限而误报"无法检测模型（可能需要认证）"。新流程：

1. 先做一次真实模型调用测试。
2. 再尝试列出 `/v1/models`。
3. 如果列模型失败但调用成功，输出友好提示"模型列表受限，但模型调用已验证"。

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
