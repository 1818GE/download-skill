# download-skill

面向国内网络环境的 **AI Agent 通用下载技能**。所有下载任务（GitHub / PyPI / npm / 官方脚本 / CDN / 一般文件）走同一条「识别 → 路由 → 下载 → 校验 → 交付」流程，主打**失败不硬扛、逐级降级**。

最初为 [HanaAgent](https://github.com/liliMozi/openhanako) 平台编写，逻辑与平台解耦，配置全部外置，稍作调整即可迁移到其他支持技能目录的 Agent 平台。

## 解决什么问题

国内直连 GitHub 慢、公共加速镜像生命周期短、下载渠道混乱。本技能把"每次下载都要临时想办法"变成"按路由表自动对号入座"：

| 来源 | 通道 |
|------|------|
| GitHub Release / raw / 压缩包 | 国内加速代理（7 级降级）+ aria2 多线程 |
| PyPI | 清华镜像 |
| npm | npmmirror |
| 官方安装脚本 | 直连下载，内部资源重新路由 |
| CDN / 一般 URL | aria2 直连 |
| 网盘 / 需登录来源 | 明确不处理，告知边界 |

## 特性

- **来源识别 → 通道路由决策表**：拿到 URL 先对号入座，不凭直觉选通道
- **代理优先级表（实测校准）**：v4.gh-proxy.org → gh.zwy.one → ghproxy.net → …，按序降级
- **GET+Range 健康检查**：公共反代普遍拒绝 HEAD 请求，用带 Range 的 GET 取前 1KB 探测，避免误判
- **VPS 三通道回传**（可选）：代理直连 → SSH 隧道 → scp，自动检测自动降级，结束后清理 VPS 临时文件
- **SHA256 硬校验**：任何通道下载完成都必须对照官方 checksum，校验失败不交付
- **全链路兜底**：aria2 缺失 → 全局搜索 → 输出直链让用户手动下载，全程不报错退出
- **文件名安全检查**：防 URL 解析异常与注入，三条通道统一过检

## 目录结构

```
download-skill/
├── SKILL.md                    # 技能主文档（运行配置 + 快速判断口诀，流程指向 SOP）
├── SOP.md                      # 标准操作流程（唯一权威源：步骤 0-4 + 决策 D1-D5 + 降级表 + 实战记录）
├── skill-dependencies.json     # 依赖清单（aria2c / download-progress 连接器，机器可读）
├── references/
│   ├── setup-guide.md          # 安装与代理配置指引
│   └── vps-mode.md             # VPS 回传模式说明
├── scripts/
│   ├── check_environment.ps1   # 环境自检（aria2c / RPC / 下载目录）
│   ├── vps-config.example.ps1  # VPS 配置模板（复制为 vps-config.ps1 后填写，勿提交真实配置）
│   └── vps-download.ps1        # VPS 一键回传脚本
├── .gitignore                  # 忽略 config.ps1 / vps-config.ps1（个人配置不入库）
└── LICENSE                     # MIT
```

## 安装

1. 将本目录放入平台的 skills 目录（HanaAgent：`<Hana数据目录>\skills\download`）
2. 运行 `scripts/check_environment.ps1` 做环境自检（aria2c / RPC / 下载目录），按提示修补缺失项
3. （可选）需要 VPS 回传时：复制 `scripts/vps-config.example.ps1` 为 `vps-config.ps1`，填入服务器 `Host` / `SshPort` / `User` / `SshKey` / `LocalDir`。**此文件含个人服务器信息，不要提交到共享仓库或随技能分发给他人**（已在 .gitignore 排除）
4. 进度查看用 AriaNg（https://ariang.mayswind.net/ ），首次使用在设置里把 RPC 指向 `localhost:6801`
5. 网络诊断技巧：直连疑似卡顿时先 `echo $env:HTTP_PROXY` 确认是否被代理干扰；用 `scripts/socks5-proxy.py` 配 ssh `-o ProxyCommand` 可让 SSH 走本地 SOCKS5 代理连远端

## 依赖与致谢

本技能在运行时**调度以下第三方开源项目**，它们均归各自原作者所有，以各自仓库声明的许可证为准；本仓库仅做调用与集成，不对其行为与可用性负责：

- [aria2](https://aria2.github.io/)：多线程下载核心（JSON-RPC 模式）
- [AriaNg](https://ariang.mayswind.net/)：下载进度 Web 界面
- 公共 ghproxy 系列加速镜像：仅作调度，不隶属于本仓库；镜像列表会过期，技能内置健康检查与更新机制

## 实战记录亮点

- 2026-08-18 代理体检：7 个镜像实测延迟与可用性，剔除 3 个失效候选
- 2026-08-09：111.56MB PowerShell zip、100.46MB APK 经加速代理下载，SHA256 全部与官方一致
- 踩坑沉淀：HEAD 探测反代会大面积误报，必须 GET+Range；zip 版工具加入 PATH 的坑

## 许可证

[MIT](LICENSE)

Copyright (c) 2026 tx
