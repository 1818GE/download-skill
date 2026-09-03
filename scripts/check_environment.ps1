# check_environment.ps1 —— download 技能环境自检
# 探测 aria2c 是否可用，并提示 download-progress 连接器连接状态。
# 用法: .\check_environment.ps1

$ok = $true

Write-Host '== download 技能环境自检 ==' -ForegroundColor Cyan

# 1. aria2c
$aria2c = $env:ARIA2C_EXE
if (-not $aria2c -or -not (Test-Path $aria2c)) {
    $candidate = Join-Path $env:USERPROFILE '.hanako\tools\aria2\aria2c.exe'
    if (Test-Path $candidate) { $aria2c = $candidate }
}
if (-not $aria2c) {
    $found = Get-ChildItem -Path C:\ -Filter aria2c.exe -Recurse -ErrorAction SilentlyContinue -Depth 5 | Select-Object -First 1
    if ($found) { $aria2c = $found.FullName }
}
if ($aria2c -and (Test-Path $aria2c)) {
    Write-Host "[OK] aria2c 可用: $aria2c" -ForegroundColor Green
    $rpc = $null -ne (netstat -ano | Select-String ':6801' | Select-String 'LISTENING')
    if ($rpc) { Write-Host '[OK] aria2 RPC 已在 6801 监听' -ForegroundColor Green }
    else { Write-Host '[提示] aria2 RPC 未运行，大文件下载时会自动后台启动' -ForegroundColor Yellow }
} else {
    Write-Host '[缺失] 未找到 aria2c。>100MB 大文件通道不可用，将降级输出直链让用户手动下载。' -ForegroundColor Red
    $ok = $false
}

# 2. download-progress 连接器（进程内工具，无法直接探测，给出人工确认提示）
Write-Host '[确认] 请确保已在连接器管理中连接 download-progress（提供 download-file / download-wait / download-command / stage_files 工具）。' -ForegroundColor Yellow
Write-Host '        未连接时，小文件通道不可用，技能会提示先连接。' -ForegroundColor Yellow

# 3. 下载目录
$dl = $env:ARIA2_DOWNLOAD_DIR
if (-not $dl) { $dl = 'D:\Downloads' }
Write-Host "[信息] 默认下载目录: $dl（可用 ARIA2_DOWNLOAD_DIR 覆盖）" -ForegroundColor Gray

if ($ok) { Write-Host '== 自检通过（aria2c 就绪）== ' -ForegroundColor Green }
else { Write-Host '== 自检未完成：aria2c 缺失，仅小文件/直链通道可用 ==' -ForegroundColor Yellow }
