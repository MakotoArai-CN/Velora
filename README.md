# avm

`avm` 是一个使用 Zig 编写的多站点 API Key 管理器，用于统一管理并快速切换 Codex、Claude Code、OpenCode 等工具的 API Key 配置。

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
# 构建 Debug 版（默认）
zig build
# 构建最小版本
zig build --release=small
# 构建安全版本
zig build --release=safe
# 构建性能版本
zig build --release=fast

# 测试
zig build test
```

## 一键安装

### Linux x86_64

```bash
curl -fsSL -o avm-linux-x86_64 https://github.com/MakotoArai-CN/avm/releases/latest/download/avm-linux-x86_64 && chmod +x ./avm-linux-x86_64 && ./avm-linux-x86_64 --install
```

### Alpine x86_64

```bash
curl -fsSL -o avm-alpine-x86_64 https://github.com/MakotoArai-CN/avm/releases/latest/download/avm-alpine-x86_64 && chmod +x ./avm-alpine-x86_64 && ./avm-alpine-x86_64 --install
```

### macOS Apple Silicon

```bash
curl -fsSL -o avm-macos-aarch64 https://github.com/MakotoArai-CN/avm/releases/latest/download/avm-macos-aarch64 && chmod +x ./avm-macos-aarch64 && ./avm-macos-aarch64 --install
```

### FreeBSD x86_64

```bash
fetch -o avm-freebsd-x86_64 https://github.com/MakotoArai-CN/avm/releases/latest/download/avm-freebsd-x86_64 && chmod +x ./avm-freebsd-x86_64 && ./avm-freebsd-x86_64 --install
```

### Windows x86_64

```powershell
Invoke-WebRequest https://github.com/MakotoArai-CN/avm/releases/latest/download/avm-windows-x86_64.exe -OutFile .\avm.exe; .\avm.exe --install
```

安装完成后，新终端即可直接运行：

```bash
avm
```

## 常用命令

```bash
# 添加站点（交互式）
avm add <别名>

# 添加站点（直接指定，可选自定义模型）
avm add <类型> <别名> <URL> <Key> [模型]

# 编辑 / 删除站点
avm edit <别名>
avm del <别名>

# 查看站点列表（并行连通性检测，并标记当前使用的工具）
avm list          # 或 avm ls
avm list -g       # 全局检测（包含已归档站点）
avm list all

# 应用站点配置到指定工具
avm use <别名> [模型]              # 自动检测类型，可选覆盖模型
avm use <类型> <别名> [模型]       # 指定目标工具，可选覆盖模型
avm cx <别名> [模型]               # 应用到 Codex
avm cc <别名> [模型]               # 应用到 Claude Code
avm oc <别名> [模型]               # 应用到 OpenCode
avm nb <别名> [模型]               # 应用到 Nanobot
avm ow <别名> [模型]               # 应用到 OpenClaw

# 浏览站点的全部模型
avm models <别名>      # 或 avm m <别名>

# CC Switch 配置导入 / 导出
avm import ccs [配置文件]                  # 默认读取 ~/.ccs/config.yaml
avm export ccs [配置文件或目录]             # 默认写入 ~/.ccs/config.yaml

# 全自动模型调用测试 / 性能基准
avm test                                 # 并行测试所有站点的模型可调用性
avm test <别名>                          # 测试单个站点
avm test --perf                          # 性能基准（交互式选站，按工具类型筛选）

# 设置选项
avm set model_check off                  # 或 avm s mc off
avm set list_latency off                 # 或 avm s ll off
avm set auto_archive on                  # 或 avm s aa on
avm set auto_pick_compatible_model off   # 或 avm s ap off
avm set auto_load_models off             # 或 avm s alm off
avm set model_select_mode keyboard       # 或 avm s msm keyboard
avm set model_call_timeout_ms 60000      # 或 avm s mt 60000

# 帮助 / 用法示例
avm --help                               # 命令参数速查
avm help examples                        # 完整用法示例

# 安装 / 卸载
avm install
avm uninstall

# 检查并自动更新
avm --update
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
| `auto_load_models` | `alm` | 添加 / 编辑时是否自动加载模型列表（默认 on） |
| `list_sort` | `ls` | 默认列表排序: time / alpha / tool / model |
| `model_select_mode` | `msm` | 交互式模型选择方式: number / keyboard |
| `model_call_timeout_ms` | `mt` | 模型调用测试总超时，单位毫秒，范围 3000-600000 |

## 用法示例

```bash
avm add openai
avm add cx openai https://api.example.com/v1 sk-xxx
avm add cc claude https://api.example.com sk-ant claude-opus-4-6
avm use openai
avm use cc openai claude-opus-4-6
avm oc openai claude-haiku-4-5-20251001
avm nb openai
avm ow openai
avm import ccs ~/.ccs/config.yaml          # 导入 CC Switch 配置
avm export ccs ~/.ccs/config.yaml          # 导出为 CC Switch 配置
avm m openai                              # 浏览 openai 站点的全部模型
avm t                                     # 并行测试所有站点的模型
avm t openai                              # 测试单个站点（带 spinner 进度）
avm t --perf                              # 交互式选择站点 + 性能基准
avm s mc off                              # 关闭模型检测，use 更快
avm s ap off                              # 关闭类型不匹配时的自动兼容模型选择
avm s alm off                             # 关闭添加/编辑时自动加载模型列表
avm s msm keyboard                        # 使用方向键选择模型
avm s mt 60000                            # 将模型调用测试超时设为 60 秒
avm help examples                         # 完整示例
```

## 当前使用工具识别（list 中的 `[← cc, oc]` 标签）

`avm list` 在每个站点行尾会显示一个加粗的标签，列出当前正指向该站点的工具，例如：

```
  ✓ openai (Claude Code) 234ms [← cc, oc]
  ✓ relay  (OpenCode)    312ms [← nb]
  ✓ gpt    (Codex)       128ms [← cx]
```

匹配规则：分别读取每个工具的真实配置文件 / 环境变量（Codex 读 `~/.codex/config.toml` 与对应 env_key；Claude Code 读 `~/.claude/settings.json` 中的 `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN`；OpenCode、Nanobot、OpenClaw 读各自的 JSON），然后用 `base_url` 或 `api_key` 任一匹配站点（解决了用户手动改 URL 后仍能识别的问题）。

## URL 处理规则

avm 会保存用户输入的 `base_url`，不会在站点配置里随意追加、替换或删除路径。这样可以避免误伤使用路径区分协议的站点，例如：

```text
https://relay.example.com/openai
https://relay.example.com/anthropic
```

应用到 Codex、OpenCode、Nanobot、OpenClaw 这类 OpenAI 兼容目标时，只有当站点 URL 明显是裸域名/根路径（例如 `https://relay.example.com`）时，写入目标工具的配置才会派生为 `https://relay.example.com/v1`。如果 URL 已经带有 `/openai`、`/anthropic`、`/v2`、`/api/...` 等路径，则保持原样。

Claude Code 的 `ANTHROPIC_BASE_URL` 始终按站点保存的 URL 原样写入。对于同一服务用不同路径区分 OpenAI / Anthropic 协议的情况，建议分别保存为两个站点别名，或在应用到目标工具前确认目标工具需要的路径。

`avm list` 的当前使用识别会把根路径和仅差一个结尾 `/v1` 的 URL 视为同一站点，避免因为 Codex 侧派生 `/v1` 导致 `[← cx]` 标签丢失。

## 并行连通性检测

`avm list` 的连通性检测会并行执行：每个站点独占一个工作线程，主线程轮询 `done` 标志并按到达顺序刷新对应行。整体耗时由"最慢的那个站点"决定（默认 15 秒超时上限），不再随站点数线性增长。

## 模型调用测试与性能基准（v1.1.8 新增）

```bash
avm t              # 并行测试所有未归档站点的模型可调用性
avm t openai       # 单站点测试（单行 spinner，结束后被结果替换）
avm t --perf       # 性能基准模式：交互选择站点 → 并行 benchmark
```

- 默认模式调用 `testModelCall`，根据模型族（Claude / OpenAI / 未知）自动尝试 `/v1/messages`、`/v1/chat/completions`、`/v1/responses` 三种接口。
- `--perf` 模式发送一个约 150 词的真实生成请求（`max_tokens=256`），从响应的 `usage.completion_tokens` / `usage.output_tokens` 解析输出 token 数，计算 `tokens/sec`。
- 进度展示：每个站点一行，前缀 spinner（`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`）+ 已用秒数；完成后该行被原地替换为最终结果（`✓` / `✗`）。
- `--perf` 的交互式选择支持按工具类型筛选（cx / cc / oc / nb / ow / 全部），随后输入逗号分隔索引或 `a` 全选。

## use 时的模型检测优化（v1.1.8）

`avm use` 不再因为 `/v1/models` 端点受限而误报"无法检测模型（可能需要认证）"。新流程：

1. 先做一次真实模型调用测试。
2. 再尝试列出 `/v1/models`。
3. 如果列模型失败但调用成功，输出友好提示"模型列表受限，但模型调用已验证"。

## 编辑后自动重新应用

`avm edit <别名>` 修改站点配置（URL / Key / 模型 / 类型）后，会自动检测当前哪些工具正在使用该站点（基于编辑前的 `base_url` / `api_key` 与各工具配置文件 / 环境变量的匹配），并将更新后的配置实时写回这些工具的配置文件。**无需在 edit 之后再手动执行 `use`。**

例如：当前 `cx` 正在使用 `yuchen` 站点，执行 `avm edit yuchen` 修改 URL 或 Key 之后，`~/.codex/config.toml` 与 `OPENAI_API_KEY` 环境变量会被同步刷新。如果同一个站点同时被多个工具使用（例如 `cx` 与 `cc` 同时指向 `yuchen`），所有匹配工具都会被一并更新。

匹配逻辑与 `avm list` 中的 `[← cc, oc]` 标签完全一致——通过 `base_url` 或 `api_key` 任一命中即视为匹配（兼容用户手动改 URL 后仍能识别的情况）。

## 单站点应用到多个工具

同一个站点可以同时配置为多个工具的默认目标（站点结构中的 `default_tools_mask` 是位掩码，覆盖 `cx` / `cc` / `oc` / `nb` / `ow`）。

- 当一个站点的 `default_tools_mask` 包含多个工具时，运行 `avm use <别名>`（不指定具体工具）会依次将该站点应用到所有勾选的工具
- 显式 `avm cx <别名>` / `avm cc <别名>` 等命令仍可单独应用到指定工具
- 每个工具可单独保存模型覆盖（`models_cx` / `models_cc` / `models_oc` / `models_nb` / `models_ow`），auto-reapply 时会按工具读取各自的模型
- `avm list` 中 `[← cx, cc]` 这类标签会同时列出所有正在使用该站点的工具

## CC Switch 导入 / 导出

avm 支持和 CC Switch 的配置互通：

```bash
avm import ccs                         # 默认读取 ~/.ccs/config.yaml
avm import ccs ~/.ccs/config.yaml
avm export ccs                         # 默认写入 ~/.ccs/config.yaml
avm export ccs ~/.ccs                  # 写入指定目录下的 config.yaml
avm export ccs ./config.yaml
```

导入时，avm 会读取 `profiles` 中的 `settings_file` / `settings`，并从对应 JSON 的 `env` 中提取 `ANTHROPIC_AUTH_TOKEN`、`ANTHROPIC_BASE_URL`、`ANTHROPIC_MODEL` 或 `ANTHROPIC_DEFAULT_*_MODEL`。导入结果会保存为 `cc` 可用站点，并写入独立的 `models_cc`，不会把 GPT 系列模型作为 Claude Code 默认模型。

导出时，avm 会生成 CCS 的 `config.yaml` 和每个 profile 对应的 `.settings.json`。只有 Claude Code 兼容的站点会被导出；GPT / OpenAI 系列模型不会被导出为 CC profile，避免后续在 Claude Code 中误用。

## 模型配置

- 每个站点都支持自定义 `model`
- 同一个站点也支持按目标工具保存单独的模型覆盖
- 当目标工具与站点原始类型不匹配时，`auto_pick_compatible_model` 默认会先读取远端模型列表，再自动选择该目标工具可用的兼容模型
- `cc` 和 `cx` 的模型选择相互隔离：`gpt*` / `o*` 不会自动写入 Claude Code，`claude-*` 不会自动写入 Codex；GLM、Kimi 等未明确归类但可通过 Anthropic 协议使用的模型仍可用于 `cc`
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

- `avm list`：仅检查未归档站点
- `avm list -g`：检查全部站点，包括已归档站点
- `auto_archive` 开启后，不可达站点会自动归档
- 已归档站点在全局检测中恢复可用时会自动取消归档
- `avm list all` 会显示详细信息，并保留归档状态展示

## 用户数据位置

- `~/.avm/sites.json`：站点配置（类型、URL、API Key、主模型、按工具模型覆盖、归档状态、多工具默认设置）
- `~/.avm/bin`：已安装的可执行文件

## LICENSE

本项目使用 [AGPL-3.0](LICENSE) 协议，未经允许不得用于商业用途，二次修改请务必保留版权声明。

[![Star History Chart](https://api.star-history.com/svg?repos=MakotoArai-CN/avm&type=date&legend=top-left)](https://www.star-history.com/#MakotoArai-CN/avm&type=date&legend=top-left)
