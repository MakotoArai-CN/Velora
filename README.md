# Velora

`Velora` 是一个使用 Zig 编写的 OpenAI API Key 同步工具，用于全自动同步 `www.fuckopenai.net` 的 API Key ，免去繁杂的替换步骤。

## 支持平台

- Windows：`x86_64`、`i386`、`aarch64`
- macOS：`x86_64`、`aarch64`
- Linux（glibc）：`x86_64`、`aarch64`、`arm`、`i386`、`loongarch64`、`ppc64le`、`riscv64`、`s390x`
- Alpine Linux（musl）：`x86_64`、`aarch64`、`arm`
- FreeBSD：`x86_64`、`aarch64`

说明：Linux 内建自启动依赖 `systemd --user`；Alpine 和 FreeBSD 建议自行使用系统调度器执行 `velora --background-sync`。

## 构建

```bash
# 构建Debug版
zig build -Doptimize=Debug
# 构建最小版本
zig build -Doptimize=ReleaseSmall
# 构建安全版本
zig build -Doptimize=ReleaseSafe
# 构建性能版本
zig build -Doptimize=ReleaseFast
```

或：

```bash
make test
make release
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
velora --setup
velora
velora --daemon --interval 30
velora --autostart --interval 30
velora --no-autostart
velora --install
velora --del
velora --uninstall
velora --status
```

## 用户数据位置

- `~/.velora/velora.conf`
- `~/.velora/auth.json`
- `~/.velora/config.toml`
- `~/.velora/bin`

## LICENSE

本项目使用 [AGPL-3.0](LICENSE) 协议，未经允许不得用于商业用途，二次修改请务必保留版权声明。
