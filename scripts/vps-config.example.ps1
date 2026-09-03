# vps-config.ps1 —— VPS 回传模式配置（首次使用时填写你自己的服务器信息）
# 注意：本文件含个人服务器信息，不要提交到共享仓库 / 不要随技能分发给他人。
# 本脚本最后一个表达式返回 $vps 哈希表，供 vps-download.ps1 调用。

@{
    Host     = 'YOUR_VPS_IP'                                # 改成你的海外 VPS 公网 IP，例如 203.0.113.10
    SshPort  = 22                                          # 改成你的 SSH 端口
    User     = 'root'                                      # 改成登录用户名
    SshKey   = Join-Path $env:USERPROFILE '.ssh\id_rsa'    # 改成你的私钥路径
    HttpPort = 8889                                        # VPS 上临时 HTTP 文件服务端口
    Dldir    = '/tmp/github-dl'                            # VPS 上的临时下载目录
    LocalDir = 'D:\Downloads'                              # 改成本机下载目录（与 SKILL.md 的 $DownloadDir 保持一致）
}
