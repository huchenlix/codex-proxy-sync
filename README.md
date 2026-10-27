# codex-proxy-sync

把 Windows 系统代理一键同步到 `~/.codex/.env`，**专治 Codex 客户端反复重连 5 次后失败**。

一个 PowerShell 脚本，无依赖、无需安装，双击运行或粘贴执行都行。

---

## 它解决什么问题

Codex 客户端**不会自动跟随 Windows 系统代理** —— 它的联网配置来自 `~/.codex/.env` 里的 `HTTPS_PROXY` / `ALL_PROXY` 等变量，而不是读注册表里的系统代理。

于是就有了这个割裂：浏览器能科学上网，Codex 客户端却连不上。

> 命令行版 Codex CLI 读的是同一份 `~/.codex/.env`，所以本脚本对它同样有效。

### 典型症状

Codex 客户端启动后卡在重连循环里，一次、两次……**重试到第 5 次就彻底断开**，报连接失败退出。这不是账号问题，也不是 Codex 本身坏了 —— 是它压根没走代理，请求根本发不出去。

手动把代理写进 `~/.codex/.env` 就能解决，但代理端口一变就得重配一遍。本脚本就是把这个手工活自动化。

本脚本做的事：**读取注册表中的系统代理设置 → 写成 `~/.codex/.env` 里的代理环境变量**。

---

## 快速开始

```powershell
powershell -ExecutionPolicy Bypass -File .\codex-proxy-sync.ps1
```

跑完输出类似：

```
端口探测：127.0.0.1:7897 可连接
已备份：C:\Users\you\.codex\.env.bak
代理    ：http://127.0.0.1:7897
不代理  ：localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,...
已写入  ：C:\Users\you\.codex\.env
校验通过
```

不确定会发生什么？先预演一遍，不写盘：

```powershell
powershell -ExecutionPolicy Bypass -File .\codex-proxy-sync.ps1 -DryRun
```

### 别忘了最后一步：重启 Codex

**写完 `.env` 不会立刻生效。** Codex 客户端只在**启动时**读取一次 `.env`，运行期间不会重新加载。

所以脚本跑完后，必须**完全退出并重新启动 Codex 客户端**，新配置才会被读进去。

> 这一步最容易漏。不重启的话，你会看到 Codex 照旧重连 5 次然后失败，然后误以为脚本没起作用 —— 其实配置早写好了，只是没被加载。

换个端口后同理：重跑脚本，**然后重启 Codex**。

---

## 参数

| 参数 | 说明 |
| --- | --- |
| `-Port <int>` | 手动指定代理端口。**TUN 模式 / PAC 场景必填**，其余情况自动检测 |
| `-ProxyHost <string>` | 代理主机，默认 `127.0.0.1`。局域网代理用这个 |
| `-Scheme <http\|socks5\|socks4>` | 代理协议，默认 `http` |
| `-NoProxy <string>` | 自定义绕过名单（逗号分隔），不给则用内置默认值 |
| `-IncludeSystemBypass` | 把系统「代理服务器例外」里的名单也合并进来 |
| `-ApplyToSession` | 同时写入当前 PowerShell 会话的 `$env:`（顺带让 curl / npm / git 生效） |
| `-NoBackup` | 不生成 `.env.bak` 备份 |
| `-SkipProbe` | 跳过端口连通性探测 |
| `-DryRun` | 只打印将要写入的内容，不落盘 |

### 常见组合

```powershell
# 代理是 socks5（Clash 的 mixed-port 通常是 http，纯 socks 端口才需要这个）
.\codex-proxy-sync.ps1 -Port 1080 -Scheme socks5

# TUN / 虚拟网卡模式：系统代理开关没开，手动给端口
.\codex-proxy-sync.ps1 -Port 7897

# 顺手让当前终端里的 curl / npm / git 也走代理
.\codex-proxy-sync.ps1 -ApplyToSession

# 合并系统自带的绕过名单
.\codex-proxy-sync.ps1 -IncludeSystemBypass
```

---

## 它做了什么

1. **读注册表** `HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings`，取 `ProxyServer`。
   兼容两种写法：裸的 `127.0.0.1:7897`，以及 `http=127.0.0.1:7897;https=...;socks=...`。
2. **探测端口**：1 秒超时的 TCP 连接，代理进程没起会警告你（但不会中断写入）。
3. **构造绕过名单**：内置局域网段；用 `-IncludeSystemBypass` 时会合并系统例外，并把 `127.*` → `127.0.0.0/8`、`*.foo.com` → `.foo.com` 做语法归一（`<local>` 会被丢弃，curl/Node 不认它）。
4. **合并式写入**：只替换代理相关的 key，`.env` 里你自己的变量（比如 `CODEX_API_KEY`）**原样保留**。
5. **备份**：写前另存为 `.env.bak`。
6. **回读校验**：写完全量比对一遍，缺哪行会红字报出来。

### 生成的 `.env`

```ini
wss_proxy=http://127.0.0.1:7897
https_proxy=http://127.0.0.1:7897
http_proxy=http://127.0.0.1:7897
all_proxy=http://127.0.0.1:7897
WSS_PROXY=http://127.0.0.1:7897
HTTPS_PROXY=http://127.0.0.1:7897
HTTP_PROXY=http://127.0.0.1:7897
ALL_PROXY=http://127.0.0.1:7897
no_proxy=localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/16,...
NO_PROXY=localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/16,...
```

大小写各写一份是刻意的 —— 不同程序读环境变量的习惯不一样，双写最省事。

文件用 **无 BOM 的 UTF-8 + LF 换行**，这是 `.env` 解析器最认的组合。

---

## 排错

**`无法加载文件 ... 因为在此系统上禁止运行脚本`**

Windows 执行策略拦了。两种解法：

```powershell
# 一次性绕过（推荐，不改系统设置）
powershell -ExecutionPolicy Bypass -File .\codex-proxy-sync.ps1

# 或永久放开当前用户
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

不想碰策略也行：把脚本内容整段复制，直接粘到 PowerShell 窗口里回车 —— 脚本体是 `& { ... }` 结构，粘贴即可执行，参数跟在末尾花括号后面写。

**中文注释显示成乱码 / 报「字符串缺少终止符」**

PowerShell 5.1 会把**没有 BOM 的 `.ps1` 当成 ANSI 解码**。如果你用某些编辑器另存过这个脚本，务必存成 **UTF-8 with BOM**。本仓库内的文件已带 BOM。

**`系统代理开关未开启`**

只是警告，不是错误。如果你用的是 TUN / 虚拟网卡模式，系统代理开关本来就不需要开 —— 用 `-Port` 手动指定端口即可：

```powershell
.\codex-proxy-sync.ps1 -Port 7897
```

如果走的是 **PAC 脚本**（`AutoConfigURL`），端口无法自动获取，同样用 `-Port`。

**`端口探测 ... 在 1 秒内无响应`**

代理客户端没启动，或者端口填错了。确认一下 Clash / v2rayN 等工具的实际端口。

**写入后 Codex 还是连不上**

- **先确认你重启过 Codex**。`.env` 只在启动时读一次，这是最常见的原因。
- 确认代理端口没错：跑一次 `-DryRun` 看看写进去的是什么。
- `.env` 只对 Codex 生效。想让当前终端的 curl / git / npm 也走代理，加 `-ApplyToSession`。
- 换端口后要**重跑一次**脚本再重启 Codex，`.env` 不会自动更新。

---

## 说明

- 仅支持 Windows（依赖注册表 + PowerShell 5.1+）。
- 脚本幂等：反复运行不会产生重复行。
- `no_proxy` 里的局域网段是通用默认值，有特殊内网需求用 `-NoProxy` 覆盖。

## 致谢

初代版本代码由 B 站用户 [**lithiurn**](https://space.bilibili.com/347512596) 贡献，感谢。

本仓库在其基础上做了这些改进：`.env` 合并式写入（不丢自定义变量）、写前备份、TUN/PAC 场景支持、socks5 支持、端口连通性探测、写后回读校验等。

## License

MIT
