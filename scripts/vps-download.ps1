# vps-download.ps1 —— 海外 VPS 回传一键脚本（从 download 技能抽取，配置参数化）
# 用法:
#   .\vps-download.ps1 -githubUrl "https://github.com/{owner}/{repo}/releases/download/{tag}/{filename}"
# 首次使用: 先编辑同目录 vps-config.ps1，填入你的服务器 Host / 端口 / 私钥路径 / 下载目录
# 说明: 输入必须是 GitHub Release 附件的原始 URL。A/B/C 三种回传方式自动检测与降级，
#       结束后按本次取得的 PID 精确关闭 HTTP 服务并删除 VPS 临时文件。

param([Parameter(Mandatory = $true)][string]$githubUrl)

# 加载用户配置（vps-config.ps1 必须返回 $vps 哈希表）
$vps = & "$PSScriptRoot\vps-config.ps1"
if (-not $vps -or -not $vps.Host -or $vps.Host -eq 'YOUR_VPS_IP') {
    throw "未找到有效 VPS 配置，请先编辑 scripts/vps-config.ps1 填入真实服务器信息。"
}

$uri = [Uri]$githubUrl
if ($uri.Host -ne 'github.com' -or $uri.AbsolutePath -notmatch '/releases/download/') {
    throw '只接受 github.com 的 Release 附件原始 URL。'
}
$filename = [Uri]::UnescapeDataString([IO.Path]::GetFileName($uri.AbsolutePath))
if ([string]::IsNullOrWhiteSpace($filename) -or $filename -notmatch '^[A-Za-z0-9._-]+$') {
    throw "文件名不安全或无法解析：$filename"
}
if (-not (Test-Path -LiteralPath $vps.SshKey)) { throw "SSH 密钥不存在：$($vps.SshKey)" }
New-Item -ItemType Directory -Force -Path $vps.LocalDir | Out-Null
$localPath = Join-Path $vps.LocalDir $filename
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
