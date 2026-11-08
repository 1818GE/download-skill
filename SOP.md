# 通用下载 SOP（标准操作流程）

> 版本：v2.2（2026-11-08，安全边界整改。移除全部 `check-certificate=false`（SKILL.md / SOP.md 共 5 处），证书校验默认开启；修正「无官方摘要时核对文件大小」表述，大小一致不能作为校验通过依据；新增「TLS 与来源校验纪律」小节。上一版 v2.1 的路由决策 D1-D5 全部保留，仅收紧安全边界）
> 上一版：v2.1（2026-08-27，下载效率改善 · 路由表重构。5 项决策落地：D1/D3 GitHub 来源全部走加速；D2 进度边界 100MB 划定 plugin card vs AriaNg；D4 健康检查触发 >50MB；D5 小文件用 download-file + 加速 URL 拼接。原有 v2.0 路由表与实战记录全部保留，仅追加本轮变更点）
> 上一版：v2.0（2026-08-18，定位升级：从「GitHub 下载 SOP」升级为「通用下载 SOP」。核心变化：新增来源识别与通道路由表（GitHub/PyPI/npm/官方脚本/CDN/一般 URL 各自的最优通道），GitHub 加速从"主体"降为"一类来源"，全来源统一走 识别→下载→校验→交付→记录 骨架）
> 适用范围：**所有需要下载的任务一律走本 SOP，不区分来源**。GitHub Release / GitHub raw / PyPI 包 / npm 包 / 官方安装脚本 / CDN 直链 / 一般网页文件 / 其他任何下载动作，都默认启用本流程，不临时想其他办法。

---

## 流程总览

```
识别来源与版本 → 按路由表选通道 → 提交下载 → 进度查看 → 校验与交付 → 记录
```

> **通道决策口诀（先决策再行动）**：GitHub 来源一律走加速拼接（≤100MB 进插件 download-file 卡片，>100MB 走技能 aria2 + AriaNg，>50MB 触发健康检查）；其他一切走插件卡片（PyPI/npm/CDN 小文件）；git clone 必须走插件 download-command。

---

## 步骤 0：识别来源（路由表）

拿到下载任务，第一件事是对号入座：

| 来源 | 识别特征 | 尺寸 | 下载通道 | 可视化层 | 细节 |
|------|----------|------|----------|----------|------|
| GitHub Release | `github.com/{o}/{r}/releases/download/` | ≤100MB | 加速代理（构造加速 URL） + 插件 download-file | 插件卡片 | 步骤 1A |
| GitHub Release | 同上 | >100MB | 加速代理 + aria2 | AriaNg | 步骤 1A |
| GitHub raw 文件 | `raw.githubusercontent.com/` | ≤20MB | jsDelivr（CDN 加速） + 插件 download-file | 插件卡片 | 步骤 1B |
| GitHub raw 文件 | 同上 | >20MB | 加速代理（ghproxy 代理 raw） + 插件 download-file | 插件卡片 | 步骤 1B |
| GitHub 仓库压缩包 | `github.com/{o}/{r}/archive/` | ≤100MB | 加速代理（构造加速 URL） + 插件 download-file | 插件卡片 | 同 1A 链路 |
| GitHub 仓库压缩包 | 同上 | >100MB | 加速代理 + aria2 | AriaNg | 同 1A 链路 |
| PyPI 包 | `pypi.org`、`pip install` | 任意 | 插件 download-file（清华镜像） | 插件卡片 | 步骤 1C |
| npm 包 | `npmjs.com`、`npm install` | 任意 | 插件 download-file（npmmirror） | 插件卡片 | 步骤 1D |
| 官方安装脚本 | `get.docker.com`、`install.sh` | 任意 | 插件 download-file | 插件卡片 | 步骤 1E |
| CDN / 一般 URL | 其他 http(s) 直链 | <10MB | 插件 download-file | 插件卡片 | 步骤 1F |
| CDN / 一般 URL | 同上 | ≥10MB | aria2 直连（多线程） | 插件卡片（仅入口） | 步骤 1F |
| git clone / pnpm install | 仓库地址 / package.json | 任意 | 插件 download-command（白名单） | 插件卡片 | 切至 download-progress_download-command |
| 网盘/需登录 | 百度网盘、迅雷、夸克 | — | **不处理** | — | 告知边界 |

**判断口诀**：github.com → 全部走加速（Release/压缩包 100MB 为分界：≤100MB 构造加速 URL 走 download-file 通道，>100MB 走 aria2；raw 文件 ≤20MB 走 jsDelivr，>20MB 走 ghproxy 代理 raw，两条都是加速）；pypi / pip → 插件卡片（清华镜像）；npmjs / registry.npmjs.org → 插件卡片（npmmirror）；CDN / 其他 → 看大小（≥10MB 走 aria2 直连，<10MB 走插件）；git clone / pnpm install → 插件 download-command。**不再有"GitHub 小文件直连"的慢车道**——所有 GitHub 来源默认加速。

---

## 步骤 1A：GitHub Release / 仓库压缩包

> **本节适用所有 GitHub Release 与仓库压缩包下载**（不限大小，决策 D1/D3：所有 GitHub 来源默认加速）。
> 唯一区别在提交通道与可视化层：≤100MB → 插件 download-file（对话流卡片）；>100MB → aria2 RPC（AriaNg）。

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

**所有 GitHub 文件默认走加速 URL**（不再按大小分"加速 vs 直连"）。100MB 线只决定**通道选择**，不决定是否加速：

- **≤100MB 文件**（download-file 通道）：直接按优先级表用第 1 顺位 `v4.gh-proxy.org` 构造加速 URL，调用 `download-progress_download-file` 提交，进度在对话流卡片
- **>100MB 文件**（aria2 通道）：构造加速 URL 后提交 aria2 RPC，进度在 AriaNg

**健康检查仅对 >50MB 文件触发**（D4）——小文件直接拿第 1 顺位 `v4.gh-proxy.org` 构造加速 URL，失败则按优先级表降级下一个（每条只试一次，不探测）；>50MB 才用 GET+Range 按优先级顺序选第一个可用，因为大文件重试成本高。用 GET+Range 取前 1KB（HEAD 会被反代误拒，返回 404/500 不代表代理死亡）：

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

### 构造加速 URL 并按大小选通道

决策 D5：小文件走插件 `download-progress_download-file` 通道，URL 仍按加速前缀拼接（与上方大文件规则格式完全一致，只是「代理拼接」不换代理不健康检查）。

```powershell
$originalUrl = 'https://github.com/{owner}/{repo}/releases/download/{tag}/{filename}'

# 1. 拼代理前缀（小文件走优先级表第 1 顺位；>50MB 走上方健康检查选出的代理）
$proxy = 'https://v4.gh-proxy.org/'   # 或健康检查选出的 $bestProxy
$acceleratedUrl = $proxy.TrimEnd('/') + '/' + $originalUrl

# 2. 按大小选通道
# 获取文件 size（GitHub API 在 assets[].size，CDN 可用 HEAD 探测）
$sizeBytes = $asset.size    # 来自 GitHub API / releases/latest

if ($sizeBytes -le 100MB) {
    # ≤100MB：走插件 download-file，对话流卡片显示进度（决策 D2）
    $taskId = download-progress_download-file(
        url       = $acceleratedUrl,
        fileName  = $filename,
        saveDir   = $DownloadDir        # 或用户指定
    )
} else {
    # >100MB：走 aria2 RPC，进度在 AriaNg（决策 D2）
    # （提交细节见步骤 2）
}
```

要点：
- 加速 URL 构造对所有大小统一格式：`{proxy}/{originalUrl}`，与小/大文件无关
- ≤50MB 不跑健康检查：拿 `v4.gh-proxy.org` 直接试，失败则按优先级表换下一个（不探测，只用 fall-through 逻辑）
- >50MB 才跑健康检查：按优先级顺序选第一个可用代理后再拼加速 URL
- 100MB 边界只决定 `download-file` 通道 vs `aria2` 通道（决策 D2/D3）

### 进度回流（aria2 通道与插件卡片的关联）

- **现状定案（2026-08-27）**：进度边界由文件大小决定（决策 D2）：
  - **≤100MB**：走插件 `download-file` 通道，进度由 `download-progress_download-wait(taskId)` 反馈，**完全在对话流卡片可见**
  - **>100MB**：走 aria2 RPC 通道，进度在 AriaNg 查看，与插件卡片进度不互通（接受不一致）
- **为什么 GitHub 中小文件现在能进卡片**：决策 D5 令所有 GitHub 文件都按加速 URL 拼接后走 `download-file` 通道，不再被强制跳到 aria2，所以进度源唯一化；100MB 以上仍走 aria2（大文件多线程优势、且 AriaNg 进度可接受）
- **不互通原因**：插件 `download-file` 一旦调用即真实下载（Node fetch 直连、无「仅展示」模式），且 dlcore.js 无外部任务挂载（adopt/attach）能力，aria2 的 gid 无法关联到插件 taskId——两条关联策略均不可行
- **改进方向**：若插件未来支持「attach 外部任务 / 仅展示模式」，升级本小节为双通道进度合一（aria2 任务也能进对话流卡片）

---

## 步骤 1B：GitHub raw / 仓库内文件

- raw 文件本身就走 CDN 加速（jsDelivr / ghproxy 都是加速源），不需“是否加速”二选一；20MB 阈值仅决定走哪个 CDN
- **≤20MB（jsDelivr 优先）**：`https://cdn.jsdelivr.net/gh/{owner}/{repo}@{tag}/{file}`，提交插件 `download-file` 通道，进度在对话流卡片
- **>20MB（ghproxy 代理 raw）**：`https://{proxy}/https://raw.githubusercontent.com/{owner}/{repo}/{tag}/{file}`，同样提交插件 `download-file` 通道，进度在对话流卡片

```powershell
# ≤20MB：jsDelivr 拼接
$rawUrl = "https://cdn.jsdelivr.net/gh/{owner}/{repo}@{tag}/{file}"

# >20MB：代理 raw 拼接
$proxy = 'https://v4.gh-proxy.org/'   # 或健康检查选出的 $bestProxy
$rawUrl = $proxy.TrimEnd('/') + '/https://raw.githubusercontent.com/{owner}/{repo}/{tag}/{file}'

# 两路都走插件 download-file（决策 D5：raw 也一律进卡片）
$taskId = download-progress_download-file(
    url       = $rawUrl,
    fileName  = $filename,
    saveDir   = $DownloadDir
)
```

jsDelivr 无法命中（仓库太大/超 20MB/私有）时降级到 ghproxy 代理 raw。

---

## 步骤 1C：PyPI 包（清华镜像）

```powershell
# 方式一：pip 直下（带依赖树）
pip download -d $DownloadDir -i https://pypi.tuna.tsinghua.edu.cn/simple {package}=={version}

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
Invoke-WebRequest -Uri 'https://get.docker.com' -OutFile "$DownloadDir\get-docker.sh" -TimeoutSec 120 -UseBasicParsing
```

脚本下载完成后，脚本内部引用的资源（一般是 GitHub 或其他 CDN）按其实际 URL 来源重新走本路由表，不要想当然用同一条通道。

---

## 步骤 1F：CDN / 一般 URL

直接 aria2 多线程直连，不构造任何加速前缀。大文件优先 aria2；小文件（<10MB）可 Invoke-WebRequest 一把梭。

---

## 步骤 2：aria2 RPC 提交

> 本步骤仅适用于 **>100MB 走 aria2 通道**的情况（GitHub 大文件 / CDN ≥10MB）。≤100MB 走插件 `download-file` 通道，直接跳到步骤 3 调用 `download-progress_download-wait` 即可。

```powershell
$aria2c = $env:ARIA2C_EXE
if (-not $aria2c -or -not (Test-Path $aria2c)) {
    $found = Get-ChildItem -Path C:\ -Filter aria2c.exe -Recurse -ErrorAction SilentlyContinue -Depth 5 | Select -First 1
    if (-not $found) { 输出直链让用户手动下载; return }   # 不报错退出
    $aria2c = $found.FullName
}
$conf = [System.IO.Path]::GetDirectoryName($aria2c) + '\aria2-rpc.conf'

# 检查 / 启动 RPC（端口 6801）
$rpcRunning = $null -ne (netstat -ano | Select-String ':6801' | Select-String 'LISTENING')
if (-not $rpcRunning) {
    Start-Process -WindowStyle Hidden -FilePath $aria2c -ArgumentList "--conf-path=$conf"
    Start-Sleep -Seconds 2
}

# 提交下载（默认目录 $DownloadDir；$url = 已按路由表构造好的最终 URL）
$body = @{
    jsonrpc = '2.0'
    id = [guid]::NewGuid().ToString()
    method = 'aria2.addUri'
    params = @(, @($url), @{ dir = $DownloadDir; 'max-connection-per-server' = '10'; 'split' = '10' })
} | ConvertTo-Json -Compress
$res = Invoke-RestMethod -Uri 'http://localhost:6801/jsonrpc' -Method Post -Body $body -ContentType 'application/json'
$res.result   # gid，回报给用户
```

- 下载目录：默认 `$DownloadDir`；用户指定目录时替换 `dir` 参数
- 提交成功必须回报：文件名、大小、gid

---

## 步骤 3：进度查看

- **进度边界定案（决策 D2）**：
  - **≤100MB（插件 download-file 通道）**——进度直接在对话流卡片看，下载完成卡片显示 100% 并可直接打开文件或复制路径
  - **>100MB（aria2 通道，GitHub 大文件 / CDN ≥10MB）**——进度在 AriaNg 查看（见附录 A）
- 插件 `download-file` / `download-command` 通道需要回查进度/等完成时，调用 `download-progress_download-wait(taskId)` 返回完整快照（state/percent/speed/eta/filePath）
- 整条 GitHub 加速链路（不管选哪条通道）起点都是「构造加速 URL」，进度边界仅决定「哪条通道提交」，不决定是否加速
- 大文件下载时长不确定，不需要轮询干等，看卡片或完成通知即可

---

## 步骤 4：完成校验与交付

1. 确认完成并关联 taskId：调用 `download-progress_download-wait(taskId)` 拿 filePath，确认任务 done 且文件落盘；aria2 通道则用 aria2 `tellStatus` 确认 gid 完成、路径一致
2. 校验：**SHA256 必校验**（镜像/CDN/磁盘任一环节都可能损坏文件，这是硬步骤不是可选步骤）：
   ```powershell
   Get-FileHash '{filePath}' -Algorithm SHA256
   ```
   对照来源的官方摘要（SHA256/SHA512，GitHub Release 页 / PyPI 元数据 / 官方发布页 / 上游 checksum 文件）；没有官方摘要时**不得以大小一致作为校验通过依据**——大小一致 ≠ 内容一致，只能发现明显损坏（截断/空文件），此时交付必须显式标注「来源真实性未校验」并说明仅做了大小与元数据一致性初筛，由用户决定是否使用
3. 交付：用 `stage_files` 把文件交付给用户（Hana 会话内可直接取）
4. 说明安装/使用方式（APK → 传到手机安装覆盖旧版；exe → 直接运行；whl → pip install 本地文件等）

---

## TLS 与来源校验纪律

**证书校验默认开启，不因兼容性关闭。** aria2 的 `check-certificate` 保持默认 true；`Invoke-WebRequest` 使用系统默认证书链验证。加速镜像或代理出现证书异常时的正确处置是**换下一个镜像**（按优先级表 fall-through），不是关闭校验。

**文件大小不能证明来源真实性。** 同尺寸内容可以被替换，大小一致只能用于发现明显损坏（截断/空文件），不能作为校验通过的结论。校验优先级：
1. 官方发布 SHA256/SHA512 摘要（GitHub Release 页、PyPI 元数据、官方发布页、上游 checksum 文件）
2. 官方签名（GPG/sigstore/minisign）验证
3. 以上皆无 → 交付时必须显式标注「**来源真实性未校验**」，并说明仅做了大小与元数据一致性初筛，由用户决定是否使用

**唯一允许关闭证书校验的场景**（需同时满足，缺一不可）：
- 用户明确知情并同意该次下载接受风险（如自建自签名代理、内网镜像）
- 仅对当次下载生效，不写入配置、不固化为脚本默认
- 必须同时提供独立可信的摘要或签名校验
- 在交付说明中记录：关闭原因、影响范围、已采取的补偿校验

---

## 降级策略

| 情况 | 处理 |
|------|------|
| 镜像证书异常 / 证书校验失败 | **不关闭校验**，按优先级表依次换镜像；全部镜像证书异常时改用 Hana 直连（Invoke-WebRequest 长超时 600s），仍不通则输出直链并说明风险 |
| aria2c 路径不存在 | 先全局搜索（深度 5），全盘没有才输出直链让用户手动下载 |
| RPC 启动失败 / 端口被占用 | 降级 CLI 直调：`& $aria2c -x 10 -s 10 -o "$DownloadDir\{file}" "{url}"` |
| RPC 提交失败 | 同上，CLI 直调 |
| GitHub 加速代理不可达 | 按优先级表依次换（v4.gh-proxy.org → gh.zwy.one → ghproxy.net → gh-proxy.com → ghproxy.homeboyc.cn → mirror.ghproxy.com → ghfast.top）→ 全不通则访问 ghproxy.link 找新镜像 → 再不行 Hana 直连（Invoke-WebRequest 长超时 600s） |
| 私有仓库 Release 资产 | 镜像无法代理认证流量，GitHub API + token 直连 |
| 镜像/直连都慢（GitHub 来源） | VPS 模式（SSH 直连 GitHub 拉回，见 SKILL.md 完整脚本） |
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

- **PowerShell-7.6.4-win-x64.zip**（111.56MB）：API 获取 v7.6.4 → v4.gh-proxy.org 加速 → aria2 RPC（gid 72e89edfc4d15310）→ 完成校验（本地 111.56MB = API size，一致）→ 解压到 `<USERPROFILE>\pwsh7`（zip 免安装，无需管理员）
- **Microsoft.WindowsTerminal_1.24.11911.0_x64.zip**（11.11MB）：gid fbbd10be8f2b9eef → 解压到 `<USERPROFILE>\wt\terminal-1.24.11911.0`（PowerShell.MCP proxy 的 ConPTY 终端宿主）
- 经验：zip 版 PowerShell 不在标准安装位置时，MCP server 找不到 pwsh.exe，必须把解压目录加入用户 PATH；Hana 进程环境变量不会热更新，连接器路径问题用 bat 包装注入 PATH 解决（见 windows-mcp 相关 SOP）

## 实战记录（2026-08-09 验证）

- **tailscale-android universal APK**（100.46MB）：API 获取 latest 为 v1.102.2（比应用内提示的 1.98.8 新）→ v4.gh-proxy.org 加速 → aria2 RPC 提交成功（gid 148d9ba4dee1064f）
- 经验：
  - 用 GitHub API 拿资产列表，文件名和大小一次到位，避免网页解析
  - universal APK 打包全架构所以大（100MB+），属正常
  - 加速代理对大文件是刚需，直连 GitHub 在国内基本拉不动

---

## 实战记录（2026-08-18 凌晨追加：GhostLock 验证工具链）

- **rustup-init.exe**（12.8MB，x86_64-pc-windows-msvc）：GitHub 加速通道全灭（v4.gh-proxy.org RPC 提交成功但 URI 序列化失败、CLI 直调 ERR；gh.zwy.one/ghproxy.net/gh-proxy.com 均失败；API latest 404 → 判定 `latest/download` 重定向是代理杀手）→ 按路由表识别 rustup 为「官方安装脚本/CDN」类来源 → 切官方 CDN `static.rust-lang.org/rustup/dist/...` aria2 直连成功（78KiB/s）→ SHA256 对照官方 `.sha256` 文件一致（`86478e53...`）
- **zig-x86_64-windows-0.16.0.zip**（92.7MB）：来源 ziglang.org（非 GitHub）→ 按 SOP 路由表本应走插件卡片（download-progress_download-file），但当前会话插件工具未加载（工具列表无 download-progress_*，MCP 搜索无结果）→ 降级技能内通道 aria2 直连 → SHA256 对照官方 index.json 一致（`68659eb5...`）
- **踩坑**：①aria2 RPC 的 params 嵌套数组经 ConvertTo-Json 后丢失（`URI is not provided`）——降级 CLI 直调即可；②`releases/latest/download` 302 重定向对加速代理不友好，优先用具体版本号或官方 CDN；③非 GitHub 来源的标准通道是插件卡片，aria2 直连仅是插件不可用时的降级，需在记录中说明降级原因

---

## 全局约定

1. **涉及下载的任务一律走本 SOP**，不区分来源，不临时另想方法
2. 下载目录默认 `$DownloadDir`（见 SKILL.md「运行配置」，可用环境变量 `ARIA2_DOWNLOAD_DIR` 覆盖）
3. 完成后必须校验 SHA256 + stage_files 交付 + 确认插件卡片已显示完成（aria2 通道则确认 AriaNg 完成）
4. 失败不硬扛：按降级策略逐级降，最后兜底是输出直链让用户手动下载
5. 代理列表是易腐资产：每次大文件下载前健康检查，发现失效代理及时记录并更新本表
6. 网盘/需登录来源不硬闯：明确告知边界，等用户提供可下载直链再继续

---

## 附录 A：AriaNg 使用说明（aria2 通道专用）

- aria2 通道（GitHub 大文件 / CDN ≥10MB）的进度在 AriaNg 页面查看：Hana 菜单 → AriaNg，或打开 `/api/plugins/ariang/page`
- 首次使用配置：左上角 ⚙ 设置 → RPC → 主机 `localhost`、端口 `6801` → 连接，设置自动保存
- 插件卡片通道（默认）不需要 AriaNg

---

## 实战记录（2026-08-19 download-progress 适配定案）

- **通道分工定案**：download-progress 插件（可视化层）与 download 技能（通道层）整合完成——SOP 路由表新增可视化层列，插件 enforce 改为分区劝导（GitHub 大文件例外走 aria2 加速）
- **阈值规则**：GitHub Release/仓库压缩包 >100MB 走技能加速通道（插件卡片仅入口）；≤100MB 走插件 download-file；GitHub raw 以 20MB 为界（jsDelivr vs ghproxy）；CDN/一般 URL ≥10MB 走 aria2 直连；git clone / pnpm install 走插件 download-command
- **实测数据（2026-08-19 补验完成，T7/T11 收口）**：
  - 插件 download-file 小文件：lodash-4.17.21.tgz（npmmirror，318961B，483ms 完成）、clipboard-2.0.11.tgz（npmmirror，25081B，168ms）、idna-3.0 wheel（清华 PyPI，58618B）、jq-windows-amd64.exe（GitHub Release 961KB 直连）、jq.h（jsDelivr GitHub raw 2550B）——全部落盘 D:\Downloads 且内容完整性校验通过
  - 插件 download-command：pnpm install 白名单接管验证通过（1000 packages，lockfile + node_modules 完整）
  - aria2 通道：OBS-Studio 187.85MB（用例 2 已验，SHA256 与官方一致，≈22MB/s）
  - 失败路径验证：HTTP 404 时插件 error 字段清晰回传（state=failed + error 消息），失败通知机制正常
- **踩坑记录**：
  - 清华 PyPI simple 索引页 href 是相对路径（../../packages/...），标准 urljoin 解析后前缀是 `https://mirrors.tuna.tsinghua.edu.cn/pypi/web/packages/`，手拼漏 `/web/` 会 404
  - download-wait 的 taskId 是插件内部 UUID（见 tasks.json），不是文件名；直接传文件名查不到任务
  - 误给索引页 URL（如 /pypi/web/simple/idna/）会下载 HTML 页面本体，先解析出真实文件直链再下
  - **软件安装包先抓官网真实直链，别猜老域名**（2026-08-19 微信案例）：`dldir1.qq.com/weixin/Windows/WeChatSetup.exe` 解析出 58.222.16.147 慢节点仅 0.01MB/s 直连，官网页面（pc.weixin.qq.com）真实链接 `dldir1v6.qq.com/weixin/Universal/Windows/WeChatWin_4.1.13.exe` 同网络下 26-29MB/s，差约 20 倍。同一软件多 CDN 域名节点质量天差地别，下载前先抓官网页面里的真实链接（web_fetch 官网 → 提取 .exe 链接）
  - **代理变量陷阱**：系统设了 HTTP_PROXY/HTTPS_PROXY（如 127.0.0.1:7897）时，Python urllib 等默认走代理，测速/下载会拿到假慢数据；Node fetch（插件）和 curl 默认不走环境变量代理。诊断网络问题时先 `echo $env:HTTP_PROXY` 确认是否被代理干扰

---

## 实战记录（2026-08-27 下载效率改善·路由表重构）

- **变更依据**：haba 立项 b82d46f0 需求规格（v1.0），tx 拍板 5 项决策（D1-D5）
- **核心变更**：
  - **D1/D3**：GitHub 来源不再有"加速 vs 直连"分叉——所有 GitHub 文件默认按加速 URL 拼接（Release/压缩包走 ghproxy 代理，raw ≤20MB 走 jsDelivr，>20MB 走 ghproxy 代理 raw）。100MB 线不再决定"是否加速"，仅决定"提交通道"
  - **D2**：进度边界 100MB——≤100MB 走插件 download-file，进度完全在对话流卡片；>100MB 走 aria2，进度在 AriaNg
  - **D4**：健康检查触发从 >100MB 调到 >50MB——小文件（≤50MB）直接拿 `v4.gh-proxy.org` 拼接加速 URL，失败则按优先级表 fall-through，不探测
  - **D5**：小文件用 download-file 通道，URL 仍按 `{proxy}/{originalUrl}` 拼接，与大文件规则格式一致
- **路由表变更**（步骤 0）：GitHub Release/仓库压缩包两行合并语义：≤100MB → 加速代理 + download-file + 插件卡片；>100MB → 加速代理 + aria2 + AriaNg。两路都"加速"，仅通道与可视化层不同
- **步骤 1A 变更**：
  - 顶部加注「本节适用所有 GitHub Release 与仓库压缩包下载（不限大小，决策 D1/D3）」
  - 健康检查小节加 >50MB 触发说明与 fall-through 描述
  - 新增"构造加速 URL 并按大小选通道"小节，演示小文件用 download-file + 加速 URL 的具体脚本
- **步骤 1B 变更**：raw 文件两路都进插件 download-file 通道（决策 D5），进度都在卡片
- **步骤 2 变更**：aria2 RPC 提交顶部加注「仅适用于 >100MB 走 aria2 通道」≤100MB 直接跳到 download-wait
- **步骤 3 变更**：进度查看按 100MB 边界重写：≤100MB 卡片 / >100MB AriaNg
- **进度回流小节变更**：标题不变，内容改为反映 100MB 进度边界定案
- **不变量**（必须保留）：SHA256 必校验、文件名安全检查、7 代理优先级表本身、git clone/pnpm 走 download-command、fallback 链、history records 不断追加
- **未做的部分**（留给 Lead/Integrator）：本轮不发起任何真实下载——验证切片（1-5）由 Lead/Integrator 在测试会话执行；plugin 端 dlcore.js 不动（决策 D2/D3 仅改 SOP/SKILL，不动插件）

## 实战记录（2026-08-27 晚：本机代理环境实测发现）

- **背景**：b82d46f0 实测验收时速度未达标，追查后发现本机运行 Clash Verge（TUN 模式，规则 `GEOIP,CN,DIRECT` + `MATCH,Proxy`），流量全部进节点，此前"直连基线"实为节点速度
- **环境事实**：TUN 模式 + 系统代理 `127.0.0.1:7897`（mixed-port）；Node fetch（插件 download-file）**不读 Windows 系统代理**，系统代理模式下插件下载 = 真直连；Clash 订阅为自建海外 VPS 服务商美国节点（普通国际线路）
- **实测数据**（Markor 11.5MB / jq 961KB）：真直连（绕过 Clash）180s 0 字节卡死；海外节点 0.07-0.4 MiB/s（晚高峰劣化）；公共加速代理 gh.zwy.one 0.24（当晚为直连节点的 3.4 倍）；显式走系统代理（`Invoke-WebRequest -Proxy 127.0.0.1:7897`）0.071；ghproxy.net 当晚失联（1.4s 失败 ×2）
- **结论**：传输方式（TUN/系统代理/显式代理）非瓶颈，**节点线路质量是决定性变量**；自建美国机房普通线路晚高峰拥塞是天花板；公共 ghproxy 在无好节点环境下仍有价值（3.4 倍）
- **未来方向**（待立项）：①系统代理感知路由——检测本机代理端口（注册表 ProxyEnable/ProxyServer）存在时，优先走本地代理而非公共 ghproxy（`Invoke-WebRequest -Proxy` 或 `aria2 --all-proxy` 已验证可行）；②多节点自动选优（url-test 组）依赖用户 Clash 配置；③目标值复测需在好节点条件下（HENET IEPL 或白天时段）重跑
