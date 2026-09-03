# download 技能安装与配置指南

> 本文件说明 download 技能运行所需的依赖、安装方式与环境变量。依赖清单见同目录 `skill-dependencies.json`。

---

## 1. download-progress 连接器（必需）

小文件（≤100MB）走对话流卡片通道，依赖 **download-progress** 连接器提供的工具：

- `download-file`：提交下载，进度在对话流卡片
- `download-wait`：回查进度 / 等待完成（返回 state/percent/speed/eta/filePath）
- `download-command`：接管 `git clone` / `pnpm install` 等命令型下载
- `stage_files`：把文件交付给用户

**安装**：在连接器管理中连接 `download-progress`。未连接时技能会在小文件环节提示先连接，并降级到 aria2 / 直连通道。

---

## 2. aria2c（必需，仅大文件通道）

>100MB 文件走 aria2 RPC + AriaNg 通道。

**安装方式（任选其一）**：

1. 下载 aria2 二进制放到任意目录，设置环境变量 `ARIA2C_EXE` 指向 `aria2c.exe`；
2. 放到 `$env:USERPROFILE\.hanako\tools\aria2\aria2c.exe`（技能默认探测位置）；
3. 放任意位置，技能首次使用全盘搜索 `aria2c.exe`（深度 5）。

**RPC 配置文件** `aria2-rpc.conf` 与 `aria2c.exe` 放在同目录，RPC 端口固定 **6801**。技能会在需要时自动后台启动守护（不弹窗），下载全部完成后保持运行待命；关闭方法见 SKILL.md「停止 RPC 守护」。

**AriaNg 首次配置**（仅大文件通道需要看进度）：

1. 打开 AriaNg 页面（Hana 菜单 → AriaNg，或 `/api/plugins/ariang/page`）
2. ⚙ 设置 → RPC → 主机 `localhost`、端口 `6801` → 连接
3. 设置自动保存，后续无需重复

---

## 3. 海外 VPS（可选，回传兜底）

本地代理 / aria2 速度不理想时，可用海外 VPS 先直连 GitHub 再拉回。详见 `references/vps-mode.md`，配置先复制 `scripts/vps-config.example.ps1` 为 `vps-config.ps1` 后填入服务器 IP / SSH 密钥 / 端口，**不要随技能分发**。

---

## 4. GitHub 加速代理优先级（2026-08-18 实测校准）

| 优先级 | 代理 | 说明 |
|--------|------|------|
| 1 | `https://v4.gh-proxy.org/` | Cloudflare 优选线路，实测响应最快，默认首选 |
| 2 | `https://gh.zwy.one/` | 2026-05 社区实测速度第一（7119 KB/s），紧急/大文件优先 |
| 3 | `https://ghproxy.net/` | 通用稳定，无广告，支持断点续传（日常小文件推荐） |
| 4 | `https://gh-proxy.com/` | 备用实例 |
| 5 | `https://ghproxy.homeboyc.cn/` | 大文件（>1GB）专用，稳定不断连，支持断点续传 |
| 6 | `https://mirror.ghproxy.com/` | 移动/联通网络优化（5G 下实测 5-8 MB/s） |
| 7 | `https://ghfast.top/` | 多国 CDN，海外回国场景友好 |

> 代理列表为易腐资产：镜像站生命周期短，全部失败时可访问 `https://ghproxy.link/`（动态镜像列表）或搜索最新汇总。

---

## 5. 环境变量

| 变量 | 作用 |
|------|------|
| `ARIA2C_EXE` | 直接指定 aria2c 路径，跳过搜索 |
| `ARIA2_DOWNLOAD_DIR` | 指定默认下载目录（默认 `D:\Downloads`） |
