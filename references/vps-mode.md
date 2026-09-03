# VPS 模式（GitHub 加速专用回传通道）

> 本章节从 SKILL.md 抽取。当本地 aria2c + 国内代理速度不理想时，用海外 VPS 先直连 GitHub，再把完整文件拉回本地。
> **配置先行**：首次使用复制 `scripts/vps-config.example.ps1` 为 `vps-config.ps1`，填入你的服务器 `Host` / `SshPort` / `User` / `SshKey` / `LocalDir` 等，**该文件含个人服务器信息，不要提交到共享仓库或随技能分发给他人**。
> **一键执行**：`scripts/vps-download.ps1 -githubUrl "<GitHub Release 附件原始 URL>"`

---

## 三种子模式（按优先级自动降级）

#### A. 代理直连（最快，推荐）

前提是本地 Clash / v2rayN 等代理客户端已开启，且代理允许访问 VPS 的 `HttpPort` 端口。流程为：VPS 用 `wget` 直连 GitHub 下载，本地检测 `7890`、`10809`、`10808` 等常见 HTTP 代理端口，然后通过代理直接请求 `http://<VPS_Host>:<HttpPort>/文件名`。此模式不建立 SSH 数据隧道，速度取决于本地代理线路质量。代理不可用或无法访问 VPS 时自动降级到 B。

#### B. SSH 隧道（兼容，保底）

本地没有可用代理时使用。流程为：VPS 用 `wget` 下载，启动临时 HTTP 服务，再建立 `-L <HttpPort>:127.0.0.1:<HttpPort>` 的 SSH 隧道，本地从 `http://127.0.0.1:<HttpPort>/文件名` 拉取。实测回传速度约 1 MB/s。隧道在后台运行，并在 `finally` 清理块中关闭。

#### C. SSH + scp（最简，无额外服务）

A、B 都失败时使用。VPS 用 `wget` 下载，然后直接通过 `scp` 拉回本地，最后删除 VPS 文件。该模式无需启动 HTTP 文件服务，传输速度与 SSH 隧道相近，约 1 MB/s。

---

## 清理流程与行为约束

- 无论 A、B、C 哪个模式成功，`finally` 都会删除 VPS 上的临时文件。
- A、B 启动的 HTTP 服务会按本次取得的 PID 精确关闭，不使用可能误杀其他服务的 `pkill -f`。
- B 的本地 SSH 隧道进程会在结束时关闭；C 不启动 HTTP 服务，因此只执行文件清理。
- 如果脚本中途被强制终止，可手动清理：

  ```powershell
  ssh -i "<你的 SshKey 路径>" -p <SshPort> <User>@<VPS_Host> 'rm -f <Dldir>/*'
  ```

  （以上占位符均取自 `scripts/vps-config.example.ps1` 的配置值；实际下载使用本地 `vps-config.ps1`）

---

<!-- VPS 端到端验证记录（2026-07-30，历史记录，路径为当时实测环境）：使用 Markpad_2.6.13_x64-setup.exe（7.3 MB）执行一键脚本。VPS wget 3.24s 完成；A 模式四个常见代理端口（7890/10809/10808/7897）全部不可达，脚本自动降级到 B 模式 SSH 隧道；B 模式因启动后立即发起请求可能隧道未就绪，需带 1s×15 次重试，改进后回传成功。最终本地文件大小 7621629 字节，SHA256 b2dce8505f6d3a83bc0c8b7ca1b27aba10c7306d3bfc4d8417b11d65e8e23917 与 GitHub Release 元数据一致；C 模式 scp 单次实测 36.5s（可作为 A/B 全部失败时的兜底）。finally 块会按本次启动的 PID 精确关闭 HTTP 服务并删除临时文件。 -->
