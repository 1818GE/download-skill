---
name: download
description: >
  通用下载技能（所有下载任务的统一入口，GitHub 下载是其中一类来源）。职责覆盖：GitHub Release /
  GitHub raw 仓库文件 / PyPI 包 / npm 包 / 官方安装脚本 / CDN 直链 / 一般网页文件等一切下载动作。
  核心机制是「来源识别 → 通道路由」：GitHub 来源一律走加速代理（决策 D1/D3，所有大小都加速），
  小文件 ≤100MB 走插件 download-file 通道 + 对话流卡片，大文件 >100MB 走 aria2 RPC + AriaNg（决策 D2），
  健康检查仅对 >50MB 触发（决策 D4）；PyPI 走清华镜像，npm 走 npmmirror，其余来源走官方镜像或 aria2 直连；
  所有来源统一走「识别→路由→下载→校验→交付→记录」流程骨架，完成后 SHA256 校验 + stage_files 交付。
  当用户想下载任何文件（说「下载」「帮我下」「下载这个链接」「下载安装包/软件/APP/视频」等）、
  需要 GitHub 加速链接、或说「下载 GitHub 链接」「帮我下 GitHub 文件」「加速这个 GitHub 下载」时触发。
  不处理 git clone 场景（已由 download-progress 插件 download-command 接替，见 SOP 路由表），也不处理需要登录认证的网盘/客户端下载（百度网盘、迅雷等）。
  **全局约定：所有需要下载的任务一律走本技能，不区分来源，标准操作流程见同目录 SOP.md。**
default-enabled: false
version: 1.0.0
agent_created: true
---

# Download Skill（通用下载）

## 运行配置（首次使用前解析）

本技能不直接写死本机路径，运行前按以下变量解析（首次使用询问用户或探测环境）：

| 变量 | 含义 | 解析方式 |
|------|------|----------|
| `$Aria2c` | aria2c 可执行文件 | 优先读环境变量 `ARIA2C_EXE`；否则探测 `$env:USERPROFILE\.hanako\tools\aria2\aria2c.exe`；再全盘搜索 `aria2c.exe`（深度 5）；均无则降级输出直链 |
| `$Conf` | aria2 RPC 配置文件 | 与 `$Aria2c` 同目录的 `aria2-rpc.conf` |
| `$DownloadDir` | 默认下载目录 | 优先环境变量 `ARIA2_DOWNLOAD_DIR`；否则默认 `D:\Downloads`（Windows）/ `~/Downloads`（macOS、Linux），安装时可改成本机习惯目录 |
| VPS 配置 | 海外回传服务器 | 见 `scripts/vps-config.example.ps1`（复制为 vps-config.ps1 后填写真实信息，不写死在正文） |

> 依赖清单见 `skill-dependencies.json`；环境自检见 `scripts/check_environment.ps1`；安装与代理配置见 `references/setup-guide.md`；VPS 模式见 `references/vps-mode.md`。

## 职责

**所有下载任务的统一入口**，GitHub 下载只是其中一类来源。执行顺序：

1. **识别来源**（GitHub / PyPI / npm / 官方脚本 / CDN / 一般 URL）
2. **选择通道**（按来源路由表，GitHub 一律走加速代理，按大小选 download-file 通道或 aria2；PyPI 走清华镜像，npm 走 npmmirror，其余 aria2 直连）
3. **下载**（≤100MB 插件 download-file 对话流卡片；>100MB aria2 RPC + AriaNg）
4. **校验**（SHA256 对照官方 checksum，至少核对大小）
5. **交付**（stage_files + 告知安装/使用方式）
6. **记录**（SOP 实战记录追加经验）

```
识别来源 → 按路由表选通道（GitHub 一律加速拼接，≤100MB download-file / >100MB aria2）→ 提交下载 → 进度查看（≤100MB 卡片 / >100MB AriaNg）→ SHA256 校验 + stage_files 交付 → 记录
```

## 来源识别与通道路由（核心决策表）

完整路由表（含尺寸阈值、可视化层、各来源下载步骤）以同目录 **SOP.md → 步骤 0** 为唯一权威源，本文件不再重复维护。

**快速判断口诀**：
- 域名为 github.com / raw.githubusercontent.com → 一律加速通道（100MB 仅选通道，不决定是否加速；raw 20MB 仅选 CDN 源）
- pypi.org / pip → 清华镜像；npmjs / registry.npmjs.org → npmmirror
- 其余 → aria2 直连；需要登录/客户端的网盘 → **不处理**

## 关键路径

| 资源 | 变量 / 值 |
|------|-----------|
| aria2c 可执行文件 | `$Aria2c`（解析见上方「运行配置」） |
| aria2c RPC 配置 | `$Conf`（与 `$Aria2c` 同目录的 `aria2-rpc.conf`） |
| aria2c 会话文件 | 与 `$Aria2c` 同目录的 `session.txt` |
| RPC 端口 | 6801 |
| AriaNg 页面 | Hana 菜单 → AriaNg，或打开 `/api/plugins/ariang/page` |

> 如果 `$Aria2c` 在默认位置不存在，执行全局搜索 `Get-ChildItem -Path C:\ -Filter aria2c.exe -Recurse -ErrorAction SilentlyContinue -Depth 5` 定位实际位置（或设 `ARIA2C_EXE` 环境变量直接指定）。如果全盘不存在，输出直链让用户手动下载，**不要报错退出**。

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
$target = $proxy.TrimEnd('/') + '/' + $testUrl   # $proxy 为代理（如 https://v4.gh-proxy.org/），$testUrl 为目标 Release 原始链接
$r = Invoke-WebRequest -Uri $target -Headers @{ Range = 'bytes=0-1023' } -Method Get -TimeoutSec 10 -UseBasicParsing
if ($r.RawContentLength -ge 1024) { '代理可用' }
```

**健康检查仅对 >50MB 文件触发**（D4）：小文件（≤50MB）直接按优先级表用第 1 顺位 `v4.gh-proxy.org` 拼接加速 URL，失败则按优先级表换下一个（不探测，只用 fall-through 逻辑）。>50MB 才按优先级顺序选第一个可用代理，因为大文件重试成本高。100MB 只决定提交通道（≤100MB 插件 download-file / >100MB aria2），不决定是否走代理、也不决定是否跑健康检查。

### GitHub raw 文件加速（≤20MB 用 jsDelivr，否则走代理）

```
jsDelivr:   https://cdn.jsdelivr.net/gh/{owner}/{repo}@{tag}/{file}
代理方式:   https://{proxy}/https://raw.githubusercontent.com/{owner}/{repo}/{tag}/{file}
```

两路都进插件 `download-file` 通道（决策 D5：raw 也一律进卡片，不走 aria2），进度在对话流；20MB 阈值仅决定走 jsDelivr 还是 ghproxy 拼接（都是加速源）。

## 非 GitHub 来源通道（快速参考）

### PyPI（清华镜像）

```powershell
# 方式一：pip 直下（带依赖树）
pip download -d $DownloadDir -i https://pypi.tuna.tsinghua.edu.cn/simple {package}=={version}

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
Invoke-WebRequest -Uri 'https://get.docker.com' -OutFile '$DownloadDir\get-docker.sh' -TimeoutSec 120 -UseBasicParsing
# 脚本下载完成后，脚本内部引用的资源按其实际 URL 来源重新走本路由表
```

### CDN / 一般 URL

直接 aria2 多线程直连（通道代码同下方「通过 RPC 提交下载」，不构造加速链接）。

## RPC 守护管理

### 检查 RPC 是否运行

通过检查端口 6801 是否在监听来判断 RPC 守护是否存活：

```powershell
$rpcRunning = $null -ne (netstat -ano | Select-String ':6801' | Select-String 'LISTENING')
```

### 启动 RPC 守护

如果 RPC 未运行，以后台静默方式启动：

```powershell
$aria2c = '$Aria2c'
$conf = '$Conf'

# 若路径不存在，全局搜索
if (-not (Test-Path $aria2c)) {
    $found = Get-ChildItem -Path C:\ -Filter aria2c.exe -Recurse -ErrorAction SilentlyContinue -Depth 5 | Select -First 1
    if ($found) { $aria2c = $found.FullName; $conf = [System.IO.Path]::GetDirectoryName($aria2c) + '\aria2-rpc.conf' }
}

Start-Process -WindowStyle Hidden -FilePath $aria2c -ArgumentList "--conf-path=$conf"

# 等待 RPC 准备就绪（最多 5 秒）
$timeout = 5
while ($timeout -gt 0 -and ($null -eq (netstat -ano | Select-String ':6801' | Select-String 'LISTENING'))) {
    Start-Sleep -Milliseconds 500
    $timeout -= 0.5
}
```

启动后 aria2c 会持续运行在后台，监听 RPC 请求。下载全部完成后不会自动退出（保持等待新任务）。如需关闭，用户可告诉你想停止 aria2c 守护，或者手动在任务管理器中结束 aria2c.exe。

## 通过 RPC 提交下载

> 本节仅适用于 **>100MB 走 aria2 通道**的情况。≤100MB 走插件 `download-progress_download-file` 通道，详见 SOP.md 步骤 1A。

构造最终下载 URL（GitHub 来源 = 加速链接，其余 = 原始 URL），通过 JSON-RPC 提交任务：

```powershell
$body = @{
    jsonrpc = '2.0'
    id = [guid]::NewGuid().ToString()
    method = 'aria2.addUri'
    params = @(
        , @($url)
        , @{
            dir = '$DownloadDir'
            'check-certificate' = 'false'
            'max-connection-per-server' = '10'
            'split' = '10'
        }
    )
} | ConvertTo-Json -Compress

$rpcResult = Invoke-RestMethod -Uri 'http://localhost:6801/jsonrpc' -Method Post -Body $body -ContentType 'application/json'
```

如果用户指定了自定义下载目录，在 `dir` 参数中传入。

## aria2 路径自检（执行前先跑）

```powershell
$aria2c = '$Aria2c'
if (-not (Test-Path $aria2c)) {
    $found = Get-ChildItem -Path C:\ -Filter aria2c.exe -Recurse -ErrorAction SilentlyContinue -Depth 5 | Select -First 1
    if (-not $found) { throw 'aria2c 未安装，请使用降级策略' }
    $aria2c = $found.FullName
}
$conf = [System.IO.Path]::GetDirectoryName($aria2c) + '\aria2-rpc.conf'
```

## 完整流程（自检 → RPC → 提交）

```powershell
$aria2c = '$Aria2c'
$conf = '$Conf'
$url = '最终下载 URL（GitHub 来源已拼好加速前缀）'

# 0. 自检路径
if (-not (Test-Path $aria2c)) {
    $found = Get-ChildItem -Path C:\ -Filter aria2c.exe -Recurse -ErrorAction SilentlyContinue -Depth 5 | Select -First 1
    if (-not $found) { throw 'aria2c 未安装，请使用降级策略（输出直链让用户手动下载）' }
    $aria2c = $found.FullName
    $conf = [System.IO.Path]::GetDirectoryName($aria2c) + '\aria2-rpc.conf'
}

# 1. 检查 / 启动 RPC
$rpcRunning = $null -ne (netstat -ano | Select-String ':6801' | Select-String 'LISTENING')
if (-not $rpcRunning) {
    Start-Process -WindowStyle Hidden -FilePath $aria2c -ArgumentList "--conf-path=$conf"
    Start-Sleep -Seconds 2
}

# 2. 提交下载
$body = @{
    jsonrpc = '2.0'
    id = [guid]::NewGuid().ToString()
    method = 'aria2.addUri'
    params = @(, @($url), @{ dir = '$DownloadDir'; 'check-certificate' = 'false'; 'max-connection-per-server' = '10'; 'split' = '10' })
} | ConvertTo-Json -Compress

Invoke-RestMethod -Uri 'http://localhost:6801/jsonrpc' -Method Post -Body $body -ContentType 'application/json'
```

## 输出

告知用户以下信息：

1. 下载任务已提交（包含文件名、大小信息，如果有）
2. **≤100MB**：进度在对话流卡片（插件 download-file 通道），下载完成卡片显示 100% + 可直接打开/复制路径
3. **>100MB**：进度在 AriaNg（aria2 通道），打开 Hana 菜单 → AriaNg，或访问 `/api/plugins/ariang/page` 查看
4. 最终下载链接（GitHub 来源给加速链接，方便在其他设备上手动下载）
5. 下载完成后：校验 SHA256（与官方 checksum 或来源元数据对照），再 stage_files 交付

输出示例（≤100MB 插件 download-file）：

```
任务已提交到 download-file：filename.zip（5.2 MB）
对话流卡片实时显示进度，完成后可点卡片直接打开。
加速链接：{加速链接}
原始链接：{原始链接}
```

输出示例（>100MB aria2）：

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
3. 「主机」保持 `localhost`，「端口」改为 `6801`
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
| aria2c 路径不存在 | 先全局搜索 `Get-ChildItem -Path C:\ -Filter aria2c.exe -Recurse -Depth 5`，找到了则用实际路径；全盘不存在才输出直链让用户手动下载 |
| RPC 启动失败或端口被占用 | 降级为 CLI 直调模式下载（`aria2c -x 10 -s 10 -o "filename" "URL"`） |
| RPC 提交失败 | 降级为 CLI 直调模式下载 |
| GitHub 加速代理不可达 | 按优先级表依次降级（v4.gh-proxy.org → gh.zwy.one → ghproxy.net → gh-proxy.com → ghproxy.homeboyc.cn → mirror.ghproxy.com → ghfast.top），全不通则访问 ghproxy.link 找新镜像或 Hana 直连（Invoke-WebRequest 长超时 600s） |
| 代理列表全部过期 | 访问 `https://ghproxy.link/`（动态镜像列表站，需 JS 渲染则用 browser）或搜索「GitHub 镜像站汇总」获取新域名，验证后写入本表 |
| 私有仓库 Release 资产 | 镜像无法代理认证流量，用 GitHub API + token 直连获取 |
| 非 GitHub 来源 | 按路由表走源内通道（清华镜像 / npmmirror / 官方镜像 / aria2 直连），同样完成校验 + 交付 + 记录；来源无法识别则告知用户 |
| 需要登录/客户端的网盘 | 不处理，告知用户边界：需自己在对应客户端下载，或提供已登录会话的直链 |
| 全部失败 | 输出直链让用户手动下载，不报错退出 |

### CLI 直调降级示例

```powershell
$aria2c = '$Aria2c'
$url = '最终下载 URL（GitHub 来源已拼好加速前缀）'
$out = '$DownloadDir\{filename}'
& $aria2c -x 10 -s 10 --check-certificate=false -o "$out" "$url"
```

### Hana 直连降级示例（最后兜底）

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$url = '最终下载 URL'
$out = '$DownloadDir\{filename}'
Invoke-WebRequest -Uri $url -OutFile $out -TimeoutSec 600 -UseBasicParsing
```

---

## VPS 模式（GitHub 加速专用回传通道）

> 本章节已抽取到 `references/vps-mode.md`，一键脚本在 `scripts/vps-download.ps1`，服务器配置先复制 `scripts/vps-config.example.ps1` 为 `vps-config.ps1` 后填写真实信息，**不要随技能分发**。
> 当本地 aria2c + 国内代理速度不理想时，用海外 VPS 先直连 GitHub 再把文件拉回本地：A 代理直连 → B SSH 隧道 → C SSH+scp 自动降级，结束后按本次取得的 PID 精确清理 VPS 临时文件。

快速使用：

```powershell
# 1. 复制 scripts/vps-config.example.ps1 为 vps-config.ps1 后填入 Host / SshPort / User / SshKey / LocalDir
# 2. 运行（输入为 GitHub Release 附件原始 URL）
.\scripts\vps-download.ps1 -githubUrl "https://github.com/{owner}/{repo}/releases/download/{tag}/{filename}"
```
