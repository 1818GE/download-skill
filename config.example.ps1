# ============================================================
# Download Skill 配置文件（示例）
# 使用方法：复制本文件为 config.ps1，并按你的环境修改。
# config.ps1 已被 .gitignore 忽略，不会提交到仓库。
# ============================================================

$DownloadConfig = @{
    # ---- aria2（必填）----
    # aria2c 可执行文件路径。留空字符串则自动全局搜索。
    Aria2Path = "$env:USERPROFILE\.hanako\tools\aria2\aria2c.exe"
    # aria2c RPC 配置文件路径（与 aria2c 同目录的 aria2-rpc.conf）
    Aria2Conf = "$env:USERPROFILE\.hanako\tools\aria2\aria2-rpc.conf"
    # aria2 JSON-RPC 端口
    RpcPort = 6801

    # ---- 默认下载目录（必填）----
    DownloadDir = "$env:USERPROFILE\Downloads"

    # ---- VPS 模式（可选）----
    # 海外 VPS，用于 GitHub 大文件加速（VPS 直连 GitHub 后回传本地）。
    # 没有 VPS 就把 Host 留空，技能会自动跳过该通道。
    Vps = @{
        Host     = ''            # 例如 '1.2.3.4'，留空 = 禁用 VPS 通道
        SshPort  = 22            # SSH 端口
        User     = 'root'        # SSH 用户
        SshKey   = "$env:USERPROFILE\.ssh\id_rsa"   # 本机 SSH 私钥路径
        HttpPort = 8889          # VPS 上临时 HTTP 回传服务端口
        Dldir    = '/tmp/github-dl'  # VPS 临时下载目录
    }
}
