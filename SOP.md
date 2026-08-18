# 通用下载 SOP（标准操作流程）

> 版本：v2.0（2026-08-18，定位升级：从「GitHub 下载 SOP」升级为「通用下载 SOP」。核心变化：新增来源识别与通道路由表（GitHub/PyPI/npm/官方脚本/CDN/一般 URL 各自的最优通道），GitHub 加速从"主体"降为"一类来源"，全来源统一走 识别→下载→校验→交付→记录 骨架）
> 适用范围：**所有需要下载的任务一律走本 SOP，不区分来源**。GitHub Release / GitHub raw / PyPI 包 / npm 包 / 官方安装脚本 / CDN 直链 / 一般网页文件 / 其他任何下载动作，都默认启用本流程，不临时想其他办法。
> 本 SOP 不含个人环境信息：所有本机路径均来自 `config.ps1` 的 `$DownloadConfig`。

---

## 流程总览

```
识别来源与版本 → 按路由表选通道 → 提交下载 → 进度查看 → 校验与交付 → 记录
```

---

## 步骤 0：识别来源（路由表）

拿到下载任务，第一件事是对号入座：

| 来源 | 识别特征 | 通道 | 细节 |
|------|----------|------|------|
| GitHub Release | `github.com/{o}/{r}/releases/download/` | 加速代理 + aria2 | 步骤 1A |
| GitHub raw 文件 | `raw.githubusercontent.com/` | jsDelivr（≤20MB）或 ghproxy 代理 raw | 步骤 1B |
| GitHub 仓库压缩包 | `github.com/{o}/{r}/archive/` | 加速代理 + aria2 | 同 1A 链路 |
| PyPI 包 | `pypi.org`、`pip install` | 清华镜像 TUNA | 步骤 1C |
| npm 包 | `npmjs.com`、`npm install` | npmmirror | 步骤 1D |
| 官方安装脚本 | `get.docker.com`、`install.sh` | 直连下载脚本 | 步骤 1E |
| CDN / 一般 URL | 其他 http(s) 直链 | aria2 直连 | 步骤 1F |
| 网盘/需登录 | 百度网盘、迅雷、夸克 | **不处理** | 告知边界 |

**判断口诀**：github.com / raw.githubusercontent.com → 加速通道；pypi / pip → 清华镜像；npmjs / registry.npmjs.org → npmmirror；其余 → aria2 直连。

---

## 步骤 1A：GitHub Release / 仓库压缩包

### 识别目标与版本

- 用户要下载什么？从哪来？先确认来源是 GitHub Release（`github.com/{owner}/{repo}/releases`）
- 用 GitHub API 获取最新 release 和资产列表（比抓网页可靠）：
  ```powershell
  $r = Invoke-RestMethod -Uri "https://api.github.com/repos/{owner}/{repo}/releases/latest" -Headers @{"User-Agent"="HanaAgent"} -TimeoutSec 20
  $r.tag_name          # 版本号
  $r.assets | ForEach-Object { "$($_.name)  $([math]::Round($_.size/1MB,2))MB  $($_.browser_download_url)" }
  ```
- 资产选择规则：
  - APK：优先 universal 包（全架构通用，Android 8.0+）
  - 多平台软件：选用户当前平台对应的包（Windows → x64 安装包等）
  - 版本取舍：GitHub latest 可能比商店/应用内提示更新，默认给最新稳定版，用户有明确版本要求则按用户要求
- 不需要 API 时也可直接看 Release 页确认资产文件名

### 健康检查 + 构造加速链接

```
原始链接:  https://github.com/{owner}/{repo}/releases/download/{tag}/{filename}
加速链接:  https://{proxy}/https://github.com/{owner}/{repo}/releases/download/{tag}/{filename}
```

加速代理优先级（2026-08-18 实测校准，依次降级）：

| 优先级 | 代理 | 说明 |
|--------|------|------|
| 1 | `https://v4.gh-proxy.org/` | Cloudflare 优选线路，实测响应最快 |
| 2 | `https://gh.zwy.one/` | 2026-05 社区实测速度第一（7119 KB/s） |
| 3 | `https://ghproxy.net/` | 无广告，断点续传，日常小文件首选 |
| 4 | `https://gh-proxy.com/` | 备用实例 |
| 5 | `https://ghproxy.homeboyc.cn/` | >1GB 大文件稳定专用，断点续传 |
| 6 | `https://mirror.ghproxy.com/` | 移动/联通网络优化 |
| 7 | `https://ghfast.top/` | 多国 CDN，海外回国场景 |

**大文件（>100MB）下载前先健康检查**，用 GET+Range 取前 1KB（HEAD 会被反代误拒，返回 404/500 不代表代理死亡）：

```powershell
$testUrl = '原始 Release 链接'
$proxies = @('https://v4.gh-proxy.org/','https://gh.zwy.one/','https://ghproxy.net/','https://gh-proxy.com/','https://ghproxy.homeboyc.cn/','https://mirror.ghproxy.com/','https://ghfast.top/')
foreach ($p in $proxies) {
    try {
        $r = Invoke-WebRequest -Uri ($p.TrimEnd('/') + '/' + $testUrl) -Headers @{ Range = 'bytes=0-1023' } -Method Get -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
        if ($r.RawContentLength -ge 1024) { Write-Host "$p 可用"; break }
    } catch { }
}
```

全部不通则访问 `https://ghproxy.link/`（动态镜像列表）或搜索最新汇总，再不行输出原始链接 Hana 直连。

**文件名安全检查**（所有通道通用）：

```powershell
$filename = [Uri]::UnescapeDataString([IO.Path]::GetFileName($uri.AbsolutePath))
if ([string]::IsNullOrWhiteSpace($filename) -or $filename -notmatch '^[A-Za-z0-9._-]+$') {
    throw "文件名不安全或无法解析：$filename"
}
```

---

## 步骤 1B：GitHub raw / 仓库内文件

```powershell
# 优先 jsDelivr（≤20MB，国内快）
# https://cdn.jsdelivr.net/gh/{owner}/{repo}@{tag}/{file}
# 大文件走 ghproxy 系列代理 raw：
# https://{proxy}/https://raw.githubusercontent.com/{owner}/{repo}/{tag}/{file}
```

jsDelivr 无法命中（仓库太大/超 20MB/私有）时降级到代理。

---

## 步骤 1C：PyPI 包（清华镜像）

```powershell
# 方式一：pip 直下（带依赖树）
pip download -d $DownloadConfig.DownloadDir -i https://pypi.tuna.tsinghua.edu.cn/simple {package}=={version}

# 方式二：aria2 拉 wheel（先抓 simple 页面拿文件列表）
# Invoke-WebRequest 'https://pypi.tuna.tsinghua.edu.cn/simple/{package}/'
# 解析出 {package}-{version}-py3-none-any.whl 或 .tar.gz 文件名后走 aria2
```

pip 不存在时用方式二。大包（>50MB）优先方式二（aria2 多线程更快）。

---

## 步骤 1D：npm 包（npmmirror）

```powershell
# tgz 直链（aria2 可直接下载）
# https://registry.npmmirror.com/{package}/-/ 拿 {package}-{version}.tgz 文件名
# 或 npm install --registry=https://registry.npmmirror.com {package}
```

---

## 步骤 1E：官方安装脚本

```powershell
Invoke-WebRequest -Uri 'https://get.docker.com' -OutFile "$($DownloadConfig.DownloadDir)\get-docker.sh" -TimeoutSec 120 -UseBasicParsing
```

脚本下载完成后，脚本内部引用的资源（一般是 GitHub 或其他 CDN）按其实际 URL 来源重新走本路由表，不要想当然用同一条通道。

---

## 步骤 1F：CDN / 一般 URL

直接 aria2 多线程直连，不构造任何加速前缀。大文件优先 aria2；小文件（<10MB）可 Invoke-WebRequest 一把梭。

---

## 步骤 2：aria2 RPC 提交

```powershell
$aria2c = $DownloadConfig.Aria2Path
if (-not (Test-Path $aria2c)) {
    $found = Get-ChildItem -Path C:\ -Filter aria2c.exe -Recurse -ErrorAction SilentlyContinue -Depth 5 | Select -First 1
    if (-not $found) { 输出直链让用户手动下载; return }   # 不报错退出
    $aria2c = $found.FullName
}
$conf = [System.IO.Path]::GetDirectoryName($aria2c) + '\aria2-rpc.conf'

# 检查 / 启动 RPC（端口见 $DownloadConfig.RpcPort）
$rpcRunning = $null -ne (netstat -ano | Select-String ":$($DownloadConfig.RpcPort)" | Select-String 'LISTENING')
if (-not $rpcRunning) {
    Start-Process -WindowStyle Hidden -FilePath $aria2c -ArgumentList "--conf-path=$conf"
    Start-Sleep -Seconds 2
}

# 提交下载（默认目录 $DownloadConfig.DownloadDir；$url = 已按路由表构造好的最终 URL）
$body = @{
    jsonrpc = '2.0'
    id = [guid]::NewGuid().ToString()
    method = 'aria2.addUri'
    params = @(, @($url), @{ dir = $DownloadConfig.DownloadDir; 'check-certificate' = 'false'; 'max-connection-per-server' = '10'; 'split' = '10' })
} | ConvertTo-Json -Compress
$res = Invoke-RestMethod -Uri "http://localhost:$($DownloadConfig.RpcPort)/jsonrpc" -Method Post -Body $body -ContentType 'application/json'
$res.result   # gid，回报给用户
```

- 下载目录：默认 `$DownloadConfig.DownloadDir`；用户指定目录时替换 `dir` 参数
- 提交成功必须回报：文件名、大小、gid

---

## 步骤 3：进度查看

- 告知用户：**Hana 菜单 → AriaNg** 查看实时进度
- AriaNg 首次使用配置：左上角 ⚙ 设置 → RPC → 主机 `localhost`、端口 `$DownloadConfig.RpcPort` → 连接
- 大文件（>50MB）下载时长不确定，不需要轮询等待，让用户在 AriaNg 看或等完成通知

---

## 步骤 4：完成校验与交付

1. 确认完成：aria2 `tellStatus` 轮询，或等用户确认 AriaNg 显示完成
2. 校验：**SHA256 必校验**（镜像/CDN/磁盘任一环节都可能损坏文件，这是硬步骤不是可选步骤）：
   ```powershell
   Get-FileHash "$($DownloadConfig.DownloadDir)\{file}" -Algorithm SHA256
   ```
   对照来源的官方 checksum（GitHub Release 页 / PyPI 元数据 / 官方发布页）；没有官方 checksum 时至少核对文件大小与来源元数据一致
3. 交付：用 `stage_files` 把文件交付给用户（Hana 会话内可直接取）
4. 说明安装/使用方式（APK → 传到手机安装覆盖旧版；exe → 直接运行；whl → pip install 本地文件等）

---

## 降级策略

| 情况 | 处理 |
|------|------|
| aria2c 路径不存在 | 先全局搜索（深度 5），全盘没有才输出直链让用户手动下载 |
| RPC 启动失败 / 端口被占用 | 降级 CLI 直调：`& $aria2c -x 10 -s 10 --check-certificate=false -o "$($DownloadConfig.DownloadDir)\{file}" "{url}"` |
| RPC 提交失败 | 同上，CLI 直调 |
| GitHub 加速代理不可达 | 按优先级表依次换（v4.gh-proxy.org → gh.zwy.one → ghproxy.net → gh-proxy.com → ghproxy.homeboyc.cn → mirror.ghproxy.com → ghfast.top）→ 全不通则访问 ghproxy.link 找新镜像 → 再不行 Hana 直连（Invoke-WebRequest 长超时 600s） |
| 私有仓库 Release 资产 | 镜像无法代理认证流量，GitHub API + token 直连 |
| 镜像/直连都慢（GitHub 来源） | VPS 模式（SSH 直连 GitHub 拉回，见 SKILL.md 完整脚本；未配置 VPS 则跳过） |
| PyPI 直连慢 | 清华镜像 → 阿里云镜像（`https://mirrors.aliyun.com/pypi/simple/`）→ 官方 pypi.org |
| npm 慢 | npmmirror → 官方 registry.npmjs.org |
| 需要登录/客户端的网盘 | 不处理，告知用户边界（需自己用对应客户端，或提供已登录直链） |
| 全部失败 | 输出直链让用户手动下载，不报错退出 |

---

## 实战记录（2026-08-18 代理体检）

- **代理健康检查实测**（GET+Range 取前 1KB，测试文件 MinGit-2.47.1-64-bit.zip）：v4.gh-proxy.org（1670ms）、gh.zwy.one（1409ms）、ghproxy.net（1859ms）、gh-proxy.com（1853ms）、ghfast.top（5446ms）全部可用；ghp.ci SSL 失败、moeyy.cn/gh-proxy 404、ghproxy.cxkpro.top 502（已从候选剔除）
- **踩坑**：HEAD 请求探测代理会大面积误报（v4.gh-proxy.org/ghproxy.net/gh-proxy.com 全部返回 404/500），实际 GET 全部正常。反代镜像普遍不支持 HEAD，健康检查必须用 GET+Range
- **镜像生态现状**：公共镜像生命周期短、速度波动大，2026-05 社区实测第一梯队 gh.zwy.one（7119 KB/s）、raw.ihtw.moe（6516）、gh.llkk.cc（6211）；ghproxy.homeboyc.cn 大文件稳定；mirror.ghproxy.com 对移动/联通网络优化
- **校验经验**：无论走哪个镜像，安装前必须 SHA256 对照官方 checksum（镜像不篡改，但 CDN 缓存、磁盘、传输都可能损坏文件）

## 实战记录（2026-08-09 晚间追加）

- **PowerShell-7.6.4-win-x64.zip**（111.56MB）：API 获取 v7.6.4 → v4.gh-proxy.org 加速 → aria2 RPC 提交 → 完成校验（本地大小 = API size，一致）→ zip 免安装解压使用（无需管理员）
- **Microsoft.WindowsTerminal_1.24.11911.0_x64.zip**（11.11MB）：同样链路下载校验
- 经验：zip 版 PowerShell 不在标准安装位置时，依赖它的程序找不到 pwsh.exe，必须把解压目录加入用户 PATH；进程环境变量不会热更新，连接器路径问题可用包装脚本注入 PATH 解决

## 实战记录（2026-08-09 验证）

- **tailscale-android universal APK**（100.46MB）：API 获取 latest 为 v1.102.2（比应用内提示的新）→ v4.gh-proxy.org 加速 → aria2 RPC 提交成功
- 经验：
  - 用 GitHub API 拿资产列表，文件名和大小一次到位，避免网页解析
  - universal APK 打包全架构所以大（100MB+），属正常
  - 加速代理对大文件是刚需，直连 GitHub 在国内基本拉不动

---

## 全局约定

1. **涉及下载的任务一律走本 SOP**，不区分来源，不临时另想方法
2. 下载目录默认 `$DownloadConfig.DownloadDir`
3. 完成后必须校验 SHA256 + stage_files 交付 + 告知 AriaNg 查看路径
4. 失败不硬扛：按降级策略逐级降，最后兜底是输出直链让用户手动下载
5. 代理列表是易腐资产：每次大文件下载前健康检查，发现失效代理及时记录并更新本表
6. 网盘/需登录来源不硬闯：明确告知边界，等用户提供可下载直链再继续
