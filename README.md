# Velora

`Velora` 鏄竴涓娇鐢?Zig 缂栧啓鐨?OpenAI API Key 鍚屾宸ュ叿锛岀敤浜庡叏鑷姩鍚屾 `www.fuckopenai.net` 鐨?API Key 锛屽厤鍘荤箒鏉傜殑鏇挎崲姝ラ銆?
## 鏀寔骞冲彴

- Windows锛歚x86_64`銆乣i386`銆乣aarch64`
- macOS锛歚x86_64`銆乣aarch64`
- Linux锛坓libc锛夛細`x86_64`銆乣aarch64`銆乣arm`銆乣i386`銆乣loongarch64`銆乣ppc64le`銆乣riscv64`銆乣s390x`
- Alpine Linux锛坢usl锛夛細`x86_64`銆乣aarch64`銆乣arm`
- FreeBSD锛歚x86_64`銆乣aarch64`

璇存槑锛歀inux 鍐呭缓鑷惎鍔ㄤ緷璧?`systemd --user`锛汚lpine 涓?FreeBSD 寤鸿鑷浣跨敤绯荤粺璋冨害鍣ㄦ墽琛?`velora --background-sync`銆?
## 鏋勫缓

```bash
zig build
zig build test
```

鎴栵細

```bash
make test
make release
```

## 涓€閿畨瑁?
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
Invoke-WebRequest https://github.com/MakotoArai-CN/Velora/releases/latest/download/velora-windows-x86_64.exe -OutFile .\velora-windows-x86_64.exe; .\velora-windows-x86_64.exe --install
```

瀹夎瀹屾垚鍚庯紝鏂扮粓绔嵆鍙洿鎺ヨ繍琛岋細

```bash
velora
```

## 甯哥敤鍛戒护

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

## 鐢ㄦ埛鏁版嵁浣嶇疆

- `~/.velora/velora.conf`
- `~/.velora/auth.json`
- `~/.velora/config.toml`
- `~/.velora/bin`

鍏煎璇诲彇鏃х増锛歚~/.codex/apikey-sync.conf`銆乣~/.codex/auth.json`銆乣~/.codex/config.toml`銆?
## LICENSE

鏈」鐩娇鐢╗AGPL-3.0](LICENSE)

