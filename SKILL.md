---
name: download
description: >
  通用下载技能（所有下载任务的统一入口，GitHub 下载是其中一类来源）。职责覆盖：GitHub Release /
  GitHub raw 仓库文件 / PyPI 包 / npm 包 / 官方安装脚本 / CDN 直链 / 一般网页文件等一切下载动作。
  核心机制是「来源识别 → 通道路由」：GitHub 来源走国内加速代理 + aria2 RPC 守护（AriaNg 看进度），
  PyPI 走清华镜像，npm 走 npmmirror，其余来源走官方镜像或 aria2 直连；所有来源统一走
  「识别→下载→校验→交付→记录」流程骨架，完成后 SHA256 校验 + stage_files 交付。
  当用户想下载任何文件（说「下载」「帮我下」「下载这个链接」「下载安装包/软件/APP/视频」等）、
  需要 GitHub 加速链接、或说「下载 GitHub 链接」「帮我下 GitHub 文件」「加速这个 GitHub 下载」时触发。
  不处理 git clone 场景，也不处理需要登录认证的网盘/客户端下载（百度网盘、迅雷等）。
  **全局约定：所有需要下载的任务一律走本技能，不区分来源，标准操作流程见同目录 SOP.md。**
default-enabled: false
---

# Download Skill（通用下载）

> 运行平台：HanaAgent（技能格式遵循其 SKILL.md 约定）。本技能为**平台无关的逻辑 + 本地配置**：
> 所有本机路径、VPS 信息都在 `config.ps1`（由 `config.example.ps1` 复制而来）中，本文件不含任何个人环境信息。

## 职责

**所有下载任务的统一入口**，GitHub 下载只是其中一类来源。执行顺序：

1. **识别来源**（GitHub / PyPI / npm / 官方脚本 / CDN / 一般 URL）
2. **选择通道**（按来源路由表，GitHub 走加速代理，PyPI 走清华镜像，npm 走 npmmirror，其余 aria2 直连）
3. **下载**（主通道 aria2 RPC，AriaNg 看进度）
4. **校验**（SHA256 对照官方 checksum，至少核对大小）
5. **交付**（stage_files + 告知安装/使用方式）
6. **记录**（SOP 实战记录追加经验）

```
识别来源 → 选择通道 → aria2 提交 → AriaNg 看进度 → 校验 + stage_files 交付 → 记录
```

## 安装与配置

1. 将本目录放入平台的 skills 目录（HanaAgent：`<Hana数据目录>\skills\download`）
2. 复制 `config.example.ps1` 为 `config.ps1`，填写你的 aria2 路径与默认下载目录
3. 可选：配置 VPS 通道。没有 VPS 就留空，技能会自动跳过该通道，不影响主流程
4. `config.ps1` 已被 `.gitignore` 忽略，不会误提交

## 来源识别与通道路由（核心决策表）

拿到下载任务先对号入座，不要凭直觉选通道：

| 来源 | 识别特征 | 下载通道 | 备注 |
|------|----------|----------|------|
| GitHub Release | `github.com/{owner}/{repo}/releases/download/` | 加速代理 + aria2 | 见下方「GitHub 加速」章节 |
| GitHub raw 文件 | `raw.githubusercontent.com/...` 或仓库内文件 | jsDelivr 优先（≤20MB），否则 ghproxy 系列代理 raw | `https://cdn.jsdelivr.net/gh/{owner}/{repo}@{tag}/{file}` |
| GitHub 仓库压缩包 | `github.com/{owner}/{repo}/archive/...` | 加速代理 + aria2（代理同样适用 archive 路径） | 或 jsDelivr（≤20MB） |
| PyPI 包 | `pypi.org/project/...` 或 `pip install xxx` | 清华镜像 TUNA | `pip download -i https://pypi.tuna.tsinghua.edu.cn/simple` 或 aria2 拉取镜像上的 wheel |
| npm 包 | `npmjs.com/package/...` 或 `npm install xxx` | npmmirror | `https://registry.npmmirror.com/{pkg}/-/{pkg}-{version}.tgz` |
| 官方安装脚本 | `get.docker.com`、`install.sh` 等 | 直接 Invoke-WebRequest 下载脚本 | 脚本内部再下载的资源按其 URL 来源重新路由 |
| CDN 直链 | 各类 `*.cdn.*` / 对象存储 / 静态资源 URL | aria2 直连（多线程） | 加速代理只服务 github.com 域名 |
| 一般网页文件 | 其他 http(s) URL | aria2 直连 | 大文件优先 aria2，小文件可 Invoke-WebRequest |
| 需要登录/客户端的网盘 | 百度网盘、迅雷、夸克等 | **不处理** | 告知用户需自己用对应客户端，或已登录拿到直链再交回来 |

**判断口诀**：域名为 github.com / raw.githubusercontent.com → 加速通道；pypi.org / pip → 清华镜像；npmjs / registry.npmjs.org → npmmirror；其余 → aria2 直连。

## 关键路径

| 资源 | 路径 |
|------|------|
| aria2c 可执行文件 | `$DownloadConfig.Aria2Path`（config.ps1 配置） |
| aria2c RPC 配置 | `$DownloadConfig.Aria2Conf`（config.ps1 配置） |
| RPC 端口 | `$DownloadConfig.RpcPort`（默认 6801） |
| 默认下载目录 | `$DownloadConfig.DownloadDir`（config.ps1 配置） |
| AriaNg 页面 | Hana 菜单 → AriaNg，或打开 `/api/plugins/ariang/page` |

> 若 aria2c 在配置路径不存在，执行全局搜索 `Get-ChildItem -Path C:\ -Filter aria2c.exe -Recurse -ErrorAction SilentlyContinue -Depth 5` 定位实际位置。如果全盘不存在，输出直链让用户手动下载，**不要报错退出**。

## GitHub 加速（GitHub 来源专用）

### 加速链接构造

```
原始链接:  https://github.com/{owner}/{repo}/releases/download/{tag}/{filename}
加速链接:  https://{proxy}/https://github.com/{owner}/{repo}/releases/download/{tag}/{filename}
```

### 加速代理优先级（2026-08-18 实测校准）

| 优先级 | 代理 | 说明 |
|--------|------|------|
| 1 | `https://v4.gh-proxy.org/` | Cloudflare 优选线路，实测响应最快，默认首选 |
| 2 | `https://gh.zwy.one/` | 2026-05 社区实测速度第一（7119 KB/s），紧急/大文件优先 |
| 3 | `https://ghproxy.net/` | 通用稳定，无广告，支持断点续传（日常小文件推荐） |
| 4 | `https://gh-proxy.com/` | 备用实例 |
| 5 | `https://ghproxy.homeboyc.cn/` | 大文件（>1GB）专用，稳定不断连，支持断点续传 |
| 6 | `https://mirror.ghproxy.com/` | 移动/联通网络优化（5G 下实测 5-8 MB/s） |
| 7 | `https://ghfast.top/` | 多国 CDN，海外回国场景友好 |

按顺序降级尝试；全都不通则输出原始链接并由 Hana 直连下载。代理列表会过期（镜像站生命周期短），如全部失败，可访问 `https://ghproxy.link/`（动态更新的可用镜像列表，需 JS 渲染）或搜索最新镜像汇总获取新域名。

### 健康检查（下载前探测）

**不要用 HEAD 探测代理**：多数反代镜像拒绝 HEAD 请求（返回 404/500），但 GET 正常，会误判代理已死。用带 Range 头的 GET 取前 1KB：

```powershell
# 返回 200/206 且拿到 1024 bytes 即视为可用
$target = 'https://{proxy}/' + $testUrl   # $testUrl 为目标 Release 原始链接
$r = Invoke-WebRequest -Uri $target -Headers @{ Range = 'bytes=0-1023' } -Method Get -TimeoutSec 10 -UseBasicParsing
if ($r.RawContentLength -ge 1024) { '代理可用' }
```

下载大文件（>100MB）前建议先跑健康检查选最快可用代理；小文件直接按优先级表用 v4.gh-proxy.org 即可。

### GitHub raw 文件加速（≤20MB 用 jsDelivr，否则走代理）

```
jsDelivr:   https://cdn.jsdelivr.net/gh/{owner}/{repo}@{tag}/{file}
代理方式:   https://{proxy}/https://raw.githubusercontent.com/{owner}/{repo}/{tag}/{file}
```

## 非 GitHub 来源通道（快速参考）

### PyPI（清华镜像）

```powershell
# 方式一：pip 直下（带依赖树）
pip download -d $DownloadConfig.DownloadDir -i https://pypi.tuna.tsinghua.edu.cn/simple {package}=={version}

# 方式二：aria2 拉 wheel（先访问镜像 simple 页面拿文件名）
# https://pypi.tuna.tsinghua.edu.cn/simple/{package}/ 页面列出所有版本文件
```

### npm（npmmirror）

```powershell
# tgz 直链模式（浏览器/aria2 可直接下载）
# https://registry.npmmirror.com/{package}/-/ 列表页找 {package}-{version}.tgz
# 或 npm install --registry=https://registry.npmmirror.com {package}
```

### 官方安装脚本

```powershell
Invoke-WebRequest -Uri 'https://get.docker.com' -OutFile "$($DownloadConfig.DownloadDir)\get-docker.sh" -TimeoutSec 120 -UseBasicParsing
# 脚本下载完成后，脚本内部引用的资源按其实际 URL 来源重新走本路由表
```

### CDN / 一般 URL

直接 aria2 多线程直连（通道代码同下方「通过 RPC 提交下载」，不构造加速链接）。

## RPC 守护管理

### 检查 RPC 是否运行

通过检查 RPC 端口是否在监听来判断守护是否存活：

```powershell
$rpcRunning = $null -ne (netstat -ano | Select-String ":$($DownloadConfig.RpcPort)" | Select-String 'LISTENING')
```

### 启动 RPC 守护

如果 RPC 未运行，以后台静默方式启动：

```powershell
$aria2c = $DownloadConfig.Aria2Path
$conf = $DownloadConfig.Aria2Conf

# 若路径不存在，全局搜索
if (-not (Test-Path $aria2c)) {
    $found = Get-ChildItem -Path C:\ -Filter aria2c.exe -Recurse -ErrorAction SilentlyContinue -Depth 5 | Select -First 1
    if ($found) { $aria2c = $found.FullName; $conf = [System.IO.Path]::GetDirectoryName($aria2c) + '\aria2-rpc.conf' }
}

Start-Process -WindowStyle Hidden -FilePath $aria2c -ArgumentList "--conf-path=$conf"

# 等待 RPC 准备就绪（最多 5 秒）
$timeout = 5
while ($timeout -gt 0 -and ($null -eq (netstat -ano | Select-String ":$($DownloadConfig.RpcPort)" | Select-String 'LISTENING'))) {
    Start-Sleep -Milliseconds 500
    $timeout -= 0.5
}
```

启动后 aria2c 会持续运行在后台，监听 RPC 请求。下载全部完成后不会自动退出（保持等待新任务）。如需关闭，用户可告诉你想停止 aria2c 守护，或者手动在任务管理器中结束 aria2c.exe。

## 通过 RPC 提交下载

构造最终下载 URL（GitHub 来源 = 加速链接，其余 = 原始 URL），通过 JSON-RPC 提交任务：

```powershell
$body = @{
    jsonrpc = '2.0'
    id = [guid]::NewGuid().ToString()
    method = 'aria2.addUri'
    params = @(
        , @($url)
        , @{
            dir = $DownloadConfig.DownloadDir
            'check-certificate' = 'false'
            'max-connection-per-server' = '10'
            'split' = '10'
        }
    )
} | ConvertTo-Json -Compress

$rpcResult = Invoke-RestMethod -Uri "http://localhost:$($DownloadConfig.RpcPort)/jsonrpc" -Method Post -Body $body -ContentType 'application/json'
```

如果用户指定了自定义下载目录，在 `dir` 参数中传入。

## 完整流程（自检 → RPC → 提交）

```powershell
$aria2c = $DownloadConfig.Aria2Path
$conf = $DownloadConfig.Aria2Conf
$url = '最终下载 URL（GitHub 来源已拼好加速前缀）'

# 0. 自检路径
if (-not (Test-Path $aria2c)) {
    $found = Get-ChildItem -Path C:\ -Filter aria2c.exe -Recurse -ErrorAction SilentlyContinue -Depth 5 | Select -First 1
    if (-not $found) { throw 'aria2c 未安装，请使用降级策略（输出直链让用户手动下载）' }
    $aria2c = $found.FullName
    $conf = [System.IO.Path]::GetDirectoryName($aria2c) + '\aria2-rpc.conf'
}

# 1. 检查 / 启动 RPC
$rpcRunning = $null -ne (netstat -ano | Select-String ":$($DownloadConfig.RpcPort)" | Select-String 'LISTENING')
if (-not $rpcRunning) {
    Start-Process -WindowStyle Hidden -FilePath $aria2c -ArgumentList "--conf-path=$conf"
    Start-Sleep -Seconds 2
}

# 2. 提交下载
$body = @{
    jsonrpc = '2.0'
    id = [guid]::NewGuid().ToString()
    method = 'aria2.addUri'
    params = @(, @($url), @{ dir = $DownloadConfig.DownloadDir; 'check-certificate' = 'false'; 'max-connection-per-server' = '10'; 'split' = '10' })
} | ConvertTo-Json -Compress

Invoke-RestMethod -Uri "http://localhost:$($DownloadConfig.RpcPort)/jsonrpc" -Method Post -Body $body -ContentType 'application/json'
```

## 输出

告知用户以下信息：

1. 下载任务已提交（包含文件名、大小信息，如果有）
2. 打开 Hana 菜单 → AriaNg，或访问 `/api/plugins/ariang/page` 实时查看下载进度
3. 最终下载链接（GitHub 来源给加速链接，方便在其他设备上手动下载）
4. 下载完成后：校验 SHA256（与官方 checksum 或来源元数据对照），再 stage_files 交付

输出示例：

```
任务已提交到 aria2c：filename.zip
在 Hana 中打开 AriaNg 页面即可查看实时下载进度。
加速链接：{加速链接}
原始链接：{原始链接}
```

## 文件名安全检查（所有通道通用）

提交下载前校验文件名，防止 URL 解析异常或注入：

```powershell
$filename = [Uri]::UnescapeDataString([IO.Path]::GetFileName($uri.AbsolutePath))
if ([string]::IsNullOrWhiteSpace($filename) -or $filename -notmatch '^[A-Za-z0-9._-]+$') {
    throw "文件名不安全或无法解析：$filename"
}
```

aria2 RPC 提交、CLI 直调、VPS 模式三条通道都要过这一关。

## AriaNg 首次使用配置

首次打开 AriaNg 页面时，需要设置 RPC 连接：

1. 打开 AriaNg 页面
2. 点击左上角「⚙ 设置」→「RPC」标签
3. 「主机」保持 `localhost`，「端口」改为 `$DownloadConfig.RpcPort`（默认 6801）
4. 点击「连接」按钮，状态变为「已连接」即成功
5. 设置会自动保存到浏览器，后续无需重复配置

## 停止 RPC 守护

如果用户想关闭后台的 aria2c 守护，执行：

```powershell
Get-Process aria2c | Where-Object { $_.Id -ne $null } | Stop-Process
```

或者告诉 Hana"停掉 aria2c"，她会帮你执行。

## 降级策略

| 情况 | 处理 |
|------|------|
| aria2c 路径不存在 | 先全局搜索（深度 5），找到了则用实际路径；全盘不存在才输出直链让用户手动下载 |
| RPC 启动失败或端口被占用 | 降级为 CLI 直调模式下载（`aria2c -x 10 -s 10 -o "filename" "URL"`） |
| RPC 提交失败 | 降级为 CLI 直调模式下载 |
| GitHub 加速代理不可达 | 按优先级表依次降级（v4.gh-proxy.org → gh.zwy.one → ghproxy.net → gh-proxy.com → ghproxy.homeboyc.cn → mirror.ghproxy.com → ghfast.top），全不通则访问 ghproxy.link 找新镜像或 Hana 直连（Invoke-WebRequest 长超时 600s） |
| 代理列表全部过期 | 访问 `https://ghproxy.link/`（动态镜像列表站，需 JS 渲染则用 browser）或搜索「GitHub 镜像站汇总」获取新域名，验证后写入本表 |
| 私有仓库 Release 资产 | 镜像无法代理认证流量，用 GitHub API + token 直连获取 |
| 本地代理/VPS 均未配置 | 跳过 VPS 通道，继续走公共代理降级链 |
| 非 GitHub 来源 | 按路由表走源内通道（清华镜像 / npmmirror / 官方镜像 / aria2 直连），同样完成校验 + 交付 + 记录；来源无法识别则告知用户 |
| 需要登录/客户端的网盘 | 不处理，告知用户边界：需自己在对应客户端下载，或提供已登录会话的直链 |
| 全部失败 | 输出直链让用户手动下载，不报错退出 |

### CLI 直调降级示例

```powershell
$aria2c = $DownloadConfig.Aria2Path
$url = '最终下载 URL（GitHub 来源已拼好加速前缀）'
$out = "$($DownloadConfig.DownloadDir)\{filename}"
& $aria2c -x 10 -s 10 --check-certificate=false -o "$out" "$url"
```

### Hana 直连降级示例（最后兜底）

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$url = '最终下载 URL'
$out = "$($DownloadConfig.DownloadDir)\{filename}"
Invoke-WebRequest -Uri $url -OutFile $out -TimeoutSec 600 -UseBasicParsing
```

---

## VPS 模式（GitHub 加速专用通道）

当本地 aria2c + 国内代理速度不理想时，使用海外 VPS 先直连 GitHub，再把完整文件拉回本地。优先尝试本地代理直连，其次使用 SSH 隧道，最后使用 `scp`。三种方式都在下载结束后清理 VPS 临时文件；A、B 模式还会关闭本次启动的 HTTP 文件服务。

### VPS 配置

VPS 参数全部来自 `config.ps1` 的 `$DownloadConfig.Vps`（见 `config.example.ps1`）。未配置 `Host` 时本通道自动跳过。所有远程 shell 命令都通过变量传给 SSH，命令模板使用单引号，避免 PowerShell 在本地展开 `$`、`&` 等字符。

```powershell
$vps = $DownloadConfig.Vps
if (-not $vps.Host) { throw '未配置 VPS（config.ps1），跳过 VPS 通道' }
```

### 三种子模式（按优先级）

#### A. 代理直连（最快，推荐）

前提是本地 Clash/v2rayN 等代理客户端已开启，并且代理允许访问 VPS 的 HTTP 端口。流程为：VPS 用 `wget` 直连 GitHub 下载，本地检测 `7890`、`10809`、`10808` 等常见 HTTP 代理端口，然后通过代理直接请求 `http://{VPS_IP}:{HttpPort}/文件名`。此模式不建立 SSH 数据隧道，速度取决于本地代理线路质量。代理不可用或无法访问 VPS 时自动降级到 B。

#### B. SSH 隧道（兼容，保底）

本地没有可用代理时使用。流程为：VPS 用 `wget` 下载，启动临时 HTTP 服务，再建立 `-L {HttpPort}:127.0.0.1:{HttpPort}` 的 SSH 隧道，本地从 `http://127.0.0.1:{HttpPort}/文件名` 拉取。实测回传速度约 1 MB/s。隧道在后台运行，并在 `finally` 清理块中关闭。

#### C. SSH + scp（最简，无额外服务）

A、B 都失败时使用。VPS 用 `wget` 下载，然后直接通过 `scp` 拉回本地，最后删除 VPS 文件。该模式无需启动 HTTP 文件服务，传输速度与 SSH 隧道相近，约 1 MB/s。

### 完整一键下载脚本（自动检测与降级）

将下面脚本保存为 `.ps1`，或直接复制到 PowerShell 执行。输入必须是 GitHub Release 附件的原始 URL。脚本要求已通过 `config.ps1` 定义 `$DownloadConfig`（内含 `Aria2Path` 等基础项与 `Vps` 配置；脚本内会自动读取）。

```powershell
param([Parameter(Mandatory = $true)][string]$githubUrl)

# 读取配置（config.ps1 位于本脚本同目录）
. (Join-Path $PSScriptRoot 'config.ps1')
$vps = $DownloadConfig.Vps
if (-not $vps.Host) { throw '未配置 VPS（config.ps1），跳过 VPS 通道' }

$uri = [Uri]$githubUrl
if ($uri.Host -ne 'github.com' -or $uri.AbsolutePath -notmatch '/releases/download/') {
    throw '只接受 github.com 的 Release 附件原始 URL。'
}
$filename = [Uri]::UnescapeDataString([IO.Path]::GetFileName($uri.AbsolutePath))
if ([string]::IsNullOrWhiteSpace($filename) -or $filename -notmatch '^[A-Za-z0-9._-]+$') {
    throw "文件名不安全或无法解析：$filename"
}
if (-not (Test-Path -LiteralPath $vps.SshKey)) { throw "SSH 密钥不存在：$($vps.SshKey)" }
New-Item -ItemType Directory -Force -Path $DownloadConfig.DownloadDir | Out-Null
$localPath = Join-Path $DownloadConfig.DownloadDir $filename
if (Test-Path -LiteralPath $localPath) { Remove-Item -Force -LiteralPath $localPath }

$sshExe = (Get-Command ssh.exe -ErrorAction Stop).Source
$scpExe = (Get-Command scp.exe -ErrorAction Stop).Source
$target = '{0}@{1}' -f $vps.User, $vps.Host
$sshArgs = @('-i', $vps.SshKey, '-p', [string]$vps.SshPort,
    '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new')
$scpArgs = @('-i', $vps.SshKey, '-P', [string]$vps.SshPort,
    '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new')
$serverPid = $null
$tunnel = $null
$serverStarted = $false

function Invoke-VpsCommand([string]$remoteCommand) {
    $output = & $script:sshExe @script:sshArgs $script:target $remoteCommand 2>&1
    if ($LASTEXITCODE -ne 0) { throw (($output | Out-String).Trim()) }
    return @($output)
}
function Start-VpsHttpServer {
    if ($script:serverStarted) { return }
    $command = 'mkdir -p ''{0}''; nohup python3 -m http.server {1} --bind 0.0.0.0 --directory ''{0}'' >/dev/null 2>&1 & echo $!' -f $script:vps.Dldir, $script:vps.HttpPort
    $output = Invoke-VpsCommand $command
    $pidText = ($output | Select-Object -Last 1).ToString().Trim()
    if ($pidText -notmatch '^\d+$') { throw "无法取得 HTTP 服务 PID：$pidText" }
    $script:serverPid = [int]$pidText
    $script:serverStarted = $true
    Start-Sleep -Seconds 1
}
function Start-VpsTunnel {
    if ($script:tunnel -and -not $script:tunnel.HasExited) { return }
    $tunnelArgs = $script:sshArgs + @('-N', '-L', ('{0}:127.0.0.1:{0}' -f $script:vps.HttpPort), $script:target)
    $script:tunnel = Start-Process -FilePath $script:sshExe -ArgumentList $tunnelArgs -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 1
    if ($script:tunnel.HasExited) { throw 'SSH 隧道启动后立即退出。' }
}
function Test-HttpEndpoint([string]$url, [int]$proxyPort) {
    try {
        $params = @{ Uri = $url; Method = 'Head'; TimeoutSec = 8; UseBasicParsing = $true; ErrorAction = 'Stop' }
        if ($proxyPort -gt 0) { $params.Proxy = 'http://127.0.0.1:{0}' -f $proxyPort }
        Invoke-WebRequest @params | Out-Null
        return $true
    } catch { return $false }
}

try {
    $prepare = 'mkdir -p ''{0}''; rm -f ''{0}/{1}''' -f $vps.Dldir, $filename
    Invoke-VpsCommand $prepare | Out-Null
    $remoteFile = '{0}/{1}' -f $vps.Dldir, $filename
    $download = 'wget -q --tries=3 --timeout=60 -O ''{0}'' ''{1}'' && test -s ''{0}''' -f $remoteFile, $githubUrl, $remoteFile
    Write-Host '[VPS] 正在通过海外直连下载 GitHub 文件...'
    Invoke-VpsCommand $download | Out-Null
    Write-Host '[VPS] 下载完成，开始选择回传通道。'

    $proxyPort = $null
    foreach ($candidate in @(7890, 10809, 10808, 7897)) {
        Start-VpsHttpServer
        $probe = 'http://{0}:{1}/{2}' -f $vps.Host, $vps.HttpPort, $filename
        if (Test-HttpEndpoint $probe $candidate) { $proxyPort = $candidate; break }
    }
    if ($proxyPort) {
        Write-Host "[A] 使用本地 HTTP 代理端口 $proxyPort（代理直连）。"
        $request = @{ Uri = $probe; Proxy = 'http://127.0.0.1:{0}' -f $proxyPort; OutFile = $localPath; TimeoutSec = 600; UseBasicParsing = $true; ErrorAction = 'Stop' }
        Invoke-WebRequest @request
    } else {
        Write-Host '[A] 未检测到可用本地代理，降级到 SSH 隧道。'
        Start-VpsHttpServer
        Start-VpsTunnel
        $probe = 'http://127.0.0.1:{0}/{1}' -f $vps.HttpPort, $filename
        for ($i = 0; $i -lt 15; $i++) {
            if (Test-HttpEndpoint $probe 0) { break }
            Start-Sleep -Seconds 1
        }
        Invoke-WebRequest -Uri $probe -OutFile $localPath -TimeoutSec 600 -UseBasicParsing -ErrorAction Stop
    }
    if (-not (Test-Path -LiteralPath $localPath) -or (Get-Item -LiteralPath $localPath).Length -le 0) { throw '本地文件为空。' }
    $file = Get-Item -LiteralPath $localPath
    Write-Host (('[完成] {0}，{1:N1} MB。' -f $file.Name, ($file.Length / 1MB)))
} catch {
    if (Test-Path -LiteralPath $localPath) { Remove-Item -Force -LiteralPath $localPath -ErrorAction SilentlyContinue }
    Write-Warning (('[A/B] 回传失败：{0}' -f $_.Exception.Message))
    Write-Host '[C] 改用 SSH + scp 回传（不依赖 HTTP 服务）。'
    try {
        $source = '{0}:{1}' -f $target, $remoteFile
        $copyArgs = $script:scpArgs + @($source, $localPath)
        & $script:scpExe @copyArgs
        if ($LASTEXITCODE -ne 0) { throw 'scp 返回非零退出码。' }
        if (-not (Test-Path -LiteralPath $localPath) -or (Get-Item -LiteralPath $localPath).Length -le 0) { throw 'scp 后本地文件为空。' }
        $file = Get-Item -LiteralPath $localPath
        Write-Host (('[完成] {0}，{1:N1} MB。' -f $file.Name, ($file.Length / 1MB)))
    } catch {
        throw ('三种 VPS 回传模式均失败：{0}' -f $_.Exception.Message)
    }
} finally {
    if ($script:tunnel -and -not $script:tunnel.HasExited) { Stop-Process -Id $script:tunnel.Id -Force -ErrorAction SilentlyContinue }
    if ($script:serverPid) {
        $stop = 'kill {0} 2>/dev/null || true; rm -f ''{1}/{2}''' -f $script:serverPid, $script:vps.Dldir, $filename
        try { Invoke-VpsCommand $stop | Out-Null } catch { Write-Warning ('VPS 清理失败：{0}' -f $_.Exception.Message) }
    } else {
        $clean = 'rm -f ''{0}/{1}''' -f $vps.Dldir, $filename
        try { Invoke-VpsCommand $clean | Out-Null } catch { }
    }
}
```

### 清理流程与行为约束

- 无论 A、B、C 哪个模式成功，`finally` 都会删除 VPS 上的临时文件。
- A、B 启动的 HTTP 服务会按本次取得的 PID 精确关闭，不使用可能误杀其他服务的 `pkill -f`。
- B 的本地 SSH 隧道进程会在结束时关闭；C 不启动 HTTP 服务，因此只执行文件清理。
- 如果脚本中途被强制终止，可手动清理 VPS：`ssh -i <密钥> -p <端口> <用户>@<VPS IP> 'rm -f /tmp/github-dl/*'`。

<!-- VPS 端到端验证记录（2026-07-30）：使用 7.3 MB 的安装包执行一键脚本。VPS wget 3.24s 完成；A 模式四个常见代理端口全部不可达，脚本自动降级到 B 模式 SSH 隧道；B 模式因启动后立即发起请求可能隧道未就绪，需带 1s×15 次重试，改进后回传成功。最终本地文件大小与 GitHub Release 元数据一致，SHA256 校验通过；C 模式 scp 单次实测 36.5s（可作为 A/B 全部失败时的兜底）。`finally` 块会按本次启动的 PID 精确关闭 HTTP 服务并删除 VPS 临时文件。 -->
