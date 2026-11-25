# 同桌 PeerPets

在一台 Mac 上让 Codex 与 Antigravity（agy）通过各自的 CLI 互相咨询。透明桌宠显示联系方向、等待、回包及失败状态；轻点角色可切到对应客户端。项目按非商业条款共享。

[下载 macOS 完整部署包](https://github.com/TingxiTang/PeerPets/releases/download/v1.6/PeerPets-1.6-macOS.zip) · [查看九个交互过程](docs/interaction-stages.png)

![琉璃课桌实机动效，包含纸团传球、等待与回信纸鹤](docs/glass-desk.gif)

角色立绘来自 CrossPet，白龙设定来自 ZipZipPipe。含角色的预览图片和动图按 CC BY-NC-SA 4.0 共享。[完整署名](macos/Resources/ART-CREDITS.txt) · [美术许可](macos/Resources/CrossPet-LICENSE.md)

## 在新 Mac 上使用

1. 使用 macOS 13 或更高版本，准备 Python 3.9+。在这台电脑安装并分别登录 Codex CLI 和 agy CLI；账号须能访问配置的模型。桌宠点击跳转还需要对应的桌面客户端。每台机器使用自己的账号、网络设置和客户端权限。
2. 解压完整部署包，把整个目录放到固定位置。在 Finder 打开目录中的 `PeerPets.app`。如果从 GitHub 取得的是源码，先按下方命令构建。部署包使用本地临时签名（ad hoc）；如系统要求受信任的开发者，可从源码在本机编译。
3. 在终端进入解压目录，分别运行以下检查。各输出一行含随机后缀的回执且退出码为 0 表示接收端可用。也可以双击 `tools/Check-Peers.command` 同时检查，报告保存于 `outputs/`。

```sh
python3 --version
tools/peer-check antigravity
tools/peer-check codex
```

4. 让两个客户端打开此目录，按 [AGENTS.md](AGENTS.md) 协作。若实际工作在另一个项目，把该文件中的双向入口表与多轮约定合并到现有的项目规则，并把入口路径指向实际安装目录。验证双向发起时，从两个客户端各发起一次自检。

## 日常使用

```sh
tools/ask-agy '请比较这两种设计的取舍……'
python3 tools/peer.py codex --ask '请复核这个计算……'
```

普通咨询在新的临时目录中进行。连续讨论时，发起方把任务目标、上一轮关键结果及本轮问题放进下一次咨询。指定项目目录、通过标准输入发送交接单时可运行 `python3 tools/peer.py codex --cwd "项目目录" < "交接单.txt"`。委托修改前明确范围和验收条件，并显式添加 `--execute`。

| 接收端 | 默认模型 | 默认时限 |
|---|---|---|
| agy | Gemini 4 Neon medium | 文字咨询静默 120 秒、总计 300 秒；自检固定 120 秒 |
| Codex | GPT-6.2 Astra medium | 咨询 300 秒，自检 90 秒 |
| 任一端执行任务 | 该端默认模型 | 1800 秒 |

桥接依次从 `PEER_CODEX_BIN`、ChatGPT.app 的内置 CLI 和 PATH 解析 Codex；agy 使用 `PEER_AGY_BIN` 或 PATH。自定义变量应填写接收端可执行文件的绝对路径，并确保发起请求的客户端进程能读到它们。模型及默认时限在 `tools/peer.py` 中。agy 文字模式需要支持 `acp --stdio`、每会话临时配置和显式选模的版本。原系统验证过的版本组合为 Codex CLI 0.169.1 与 agy CLI 1.5.14。

普通 agy 文字咨询只按当前会话的非空白思考或正文片段刷新静默计时。预计对方可能长时间没有可见输出时，可预先用 `python3 tools/peer.py antigravity --timeout 600 --ask '问题'`，改用整轮固定 600 秒。未确认完成的片段不会当作最终答复；超时或取消后不自动重发。

## 状态和排查

桌宠按用户读取临时事件，每个请求单独记录。并发时显示当前等待和上一条结果，成功、失败或取消后结束该请求的计时。指针移近琉璃课桌时，小课桌用于“显示桌面”，蓝色笑脸抽屉用于在 Finder 打开个人主目录。单击角色仍打开对应客户端。空闲时单击两人之间的纸团，紫猫与白龙来回传球；移开指针会收起道具。桌沿暖灯表示请求在途，每条新收到的成功回执会让纸鹤飞向发起方。失败和取消保留原因提示。启用系统“减少动态效果”时，纸团与纸鹤改在原地显示。拖动角色可移动，右键可设置空闲隐身，空白区域支持点击穿透。

自检失败时查看发起端 stderr、退出码和最后一个阶段。agy 停在 `session/new` 时检查代理来源、模型列表和账户服务；已有代理或受管策略优先，符合条件的 macOS 环境会为 agy 子进程沿用系统本机代理。Codex 配置读取受限时检查发起端对本次命令的权限。一个接收端自检成功，只说明当前账号和发起环境的这条路径可用。

## 从源码构建与测试

在安装了 Apple Command Line Tools（含 Swift、make 和 lipo）的 Mac 上，从本目录运行：

```sh
make test
make app
open build/PeerPets.app
make release
```

`make test` 运行 Python 离线桥接回归和 Swift 桌宠状态检查。`make app` 构建 Apple Silicon 与 Intel 双架构应用并校验签名。`make release` 输出 `build/PeerPets-1.6-macOS.zip`，包含源码、应用、使用说明、署名和许可。本版交付范围为 macOS。桌宠源代码使用 AppKit，桥接使用 POSIX 进程组。

## 在 GitHub 分享

可单独将此项目的源码目录作为仓库根目录，并将完整 ZIP 作为 Release 附件。发布源码时保留 LICENSE、AGENTS.md、macos、tools、scripts、Makefile 与本说明。`.gitignore` 会排除编译缓存、本机报告、环境文件和预编译应用。接收方自行安装两个厂商的客户端。

代码与文档允许非商业部署和免费原样转发。商业用途或分发改版需另行授权。四张原版角色立绘保留 CrossPet 的署名及独立的非商业、相同方式共享许可。[项目许可](LICENSE) · [美术署名](macos/Resources/ART-CREDITS.txt) · [上游美术许可](macos/Resources/CrossPet-LICENSE.md)
