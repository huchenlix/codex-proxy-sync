# codex-proxy-sync.ps1
# 把 Windows 系统代理同步到 ~/.codex/.env
#
# 用法（可直接粘贴到 PowerShell 执行，也可存成 .ps1 运行）：
#   .\codex-proxy-sync.ps1                      # 自动检测并写入
#   .\codex-proxy-sync.ps1 -DryRun              # 只看将要写入什么，不落盘
#   .\codex-proxy-sync.ps1 -Port 7890           # 手动指定端口（TUN 模式 / PAC 场景用）
#   .\codex-proxy-sync.ps1 -Scheme socks5       # 代理是 socks5 而非 http
#   .\codex-proxy-sync.ps1 -ApplyToSession      # 同时作用于当前 PowerShell 会话
#   .\codex-proxy-sync.ps1 -IncludeSystemBypass # 合并系统 ProxyOverride 里的绕过名单

& {
    param(
        [int]$Port = 0,
        [string]$ProxyHost = '',
        [ValidateSet('http', 'socks5', 'socks4')]
        [string]$Scheme = 'http',
        [string]$NoProxy = '',
        [switch]$IncludeSystemBypass,
        [switch]$ApplyToSession,
        [switch]$NoBackup,
        [switch]$SkipProbe,
        [switch]$DryRun
    )

    $ErrorActionPreference = 'Stop'
    $regKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'

    # ---------- 1. 获取代理主机与端口 ----------

    $s = Get-ItemProperty $regKey

    if ($Port -le 0 -or [string]::IsNullOrWhiteSpace($ProxyHost)) {
        # 这一版不再因为 ProxyEnable=0 就直接 throw：
        # TUN / 虚拟网卡模式下开关可以不开，流量照样被接管。
        if ($s.ProxyEnable -ne 1) {
            if ($s.AutoConfigURL) {
                Write-Warning "系统代理开关未开启，但检测到 PAC 脚本：$($s.AutoConfigURL)。PAC 场景拿不到端口，请用 -Port 手动指定。"
            }
            else {
                Write-Warning "系统代理开关未开启（ProxyEnable=0）。若你使用 TUN 模式，请用 -Port 手动指定端口。"
            }
        }

        # 兼容 "127.0.0.1:7897" 和 "http=127.0.0.1:7897;https=...;socks=..." 两种写法
        $raw = [string]$s.ProxyServer
        $m = [regex]::Match($raw, '(?:(?<sch>https?|socks\d?)=)?(?<h>[\w\.\-]+):(?<p>\d{1,5})')

        if (-not $m.Success) {
            throw "无法从 ProxyServer 解析出端口，原始值：'$raw'。请显式运行 -Port <端口>。"
        }

        if ([string]::IsNullOrWhiteSpace($ProxyHost)) { $ProxyHost = $m.Groups['h'].Value }
        if ($Port -le 0)                             { $Port      = [int]$m.Groups['p'].Value }

        # 只有用户没显式给 -Scheme 时，才按注册表里的协议前缀推断
        if (-not $PSBoundParameters.ContainsKey('Scheme') -and $m.Groups['sch'].Success) {
            $detected = $m.Groups['sch'].Value
            if ($detected -like 'socks*') { $Scheme = 'socks5' }
        }
    }

    if ([string]::IsNullOrWhiteSpace($ProxyHost)) { $ProxyHost = '127.0.0.1' }
    $proxy = '{0}://{1}:{2}' -f $Scheme, $ProxyHost, $Port

    # ---------- 2. 端口连通性探测（1 秒超时，不阻塞） ----------

    if (-not $SkipProbe) {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        try {
            $ar = $tcp.BeginConnect($ProxyHost, $Port, $null, $null)
            if ($ar.AsyncWaitHandle.WaitOne(1000)) {
                try { $tcp.EndConnect($ar) } catch { }
                Write-Host ('端口探测：{0}:{1} 可连接' -f $ProxyHost, $Port) -ForegroundColor Green
            }
            else {
                Write-Warning ('端口探测：{0}:{1} 在 1 秒内无响应，代理进程可能没启动。' -f $ProxyHost, $Port)
            }
        }
        catch {
            Write-Warning "端口探测失败：$($_.Exception.Message)"
        }
        finally { $tcp.Close() ; $tcp.Dispose() }
    }

    # ---------- 3. 构造 no_proxy ----------

    $bypass = New-Object System.Collections.Generic.List[string]

    if ([string]::IsNullOrWhiteSpace($NoProxy)) {
        $bypass.AddRange([string[]]@(
            'localhost', '127.0.0.1', '::1',
            '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16',
            '169.254.0.0/16', 'fc00::/7', 'fe80::/10'
        ))
    }
    else {
        foreach ($i in ($NoProxy -split ',')) { if ($i.Trim()) { $bypass.Add($i.Trim()) } }
    }

    # 可选：把系统 ProxyOverride 合并进来，并做语法归一
    if ($IncludeSystemBypass -and $s.ProxyOverride) {
        foreach ($item in ([string]$s.ProxyOverride -split '[;,]')) {
            $t = $item.Trim()
            if (-not $t -or $t -eq '<local>') { continue }   # curl/Node 不认 <local>，丢弃
            switch -Regex ($t) {
                '^127\.\*$'        { $bypass.Add('127.0.0.0/8') }
                '^10\.\*$'         { $bypass.Add('10.0.0.0/8') }
                '^192\.168\.\*$'   { $bypass.Add('192.168.0.0/16') }
                '^172\.(1[6-9]|2\d|3[01])\.\*$' { }          # 已被 172.16.0.0/12 覆盖
                '^\*\.(.+)$'       { $bypass.Add(".$($Matches[1])") }
                default            { $bypass.Add($t.ToLower()) }
            }
        }
    }

    $noProxy = (($bypass | Select-Object -Unique) -join ',')

    # ---------- 4. 合并式写入：保留 .env 里的其它变量 ----------

    $path  = Join-Path $HOME '.codex\.env'
    $proxyKeys = @('wss_proxy', 'https_proxy', 'http_proxy', 'all_proxy', 'no_proxy')

    $kept = New-Object System.Collections.Generic.List[string]
    if (Test-Path $path) {
        foreach ($line in (Get-Content $path)) {
            if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=') {
                if ($proxyKeys -contains $Matches[1].ToLower()) { continue }  # 旧的代理行，稍后重写
            }
            $kept.Add($line)
        }
    }

    $newBlock = @(
        "wss_proxy=$proxy", "https_proxy=$proxy", "http_proxy=$proxy", "all_proxy=$proxy",
        "WSS_PROXY=$proxy", "HTTPS_PROXY=$proxy", "HTTP_PROXY=$proxy", "ALL_PROXY=$proxy",
        "no_proxy=$noProxy", "NO_PROXY=$noProxy"
    )

    $content = (($kept | Where-Object { $_ -ne '' }) + $newBlock) -join "`n"

    # ---------- 5. 落盘 ----------

    if ($DryRun) {
        Write-Host '--- DryRun：以下内容不会写入 ---' -ForegroundColor Yellow
        Write-Host $content
        Write-Host "`n目标文件：$path"
        return
    }

    New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null

    if ((Test-Path $path) -and -not $NoBackup) {
        Copy-Item $path "$path.bak" -Force
        Write-Host "已备份：$path.bak" -ForegroundColor DarkGray
    }

    # 无 BOM 的 UTF-8 + LF 换行：.env 解析器最认这一套
    [System.IO.File]::WriteAllText(
        $path,
        $content,
        [System.Text.UTF8Encoding]::new($false)
    )

    # ---------- 6. 回读校验 ----------

    $written = Get-Content $path -Raw
    $ok = $true
    foreach ($kv in $newBlock) {
        if ($written -notmatch [regex]::Escape($kv)) { $ok = $false ; Write-Warning "校验失败，缺少：$kv" }
    }

    if ($ApplyToSession) {
        $env:WSS_PROXY = $proxy ; $env:HTTPS_PROXY = $proxy
        $env:HTTP_PROXY = $proxy ; $env:ALL_PROXY  = $proxy
        $env:wss_proxy = $proxy ; $env:https_proxy = $proxy
        $env:http_proxy = $proxy ; $env:all_proxy  = $proxy
        $env:NO_PROXY = $noProxy ; $env:no_proxy   = $noProxy
        Write-Host '已同步到当前 PowerShell 会话' -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host "代理    ：$proxy"
    Write-Host "不代理  ：$noProxy"
    Write-Host "已写入  ：$path"
    Write-Host $(if ($ok) { '校验通过' } else { '校验未通过' }) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
} @args   # 存成 .ps1 时，把命令行参数转发给内层脚本块；直接粘贴执行时 @args 为空，无副作用
