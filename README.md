# 把 autoinstall 烧进 Ubuntu ISO

一条命令产出一块自动装机 U 盘：默认停在**硬盘选择**页由你确认（避免误抹盘），确认后自动装完并带全套预装软件。

适用：Ubuntu Server **22.04 / 24.04**，以及 Ubuntu **Desktop 24.04**（`--edition desktop`，默认按 ISO 自动识别，见「[Ubuntu Desktop 24.04](#ubuntu-desktop-2404)」）。

构建机：**Linux / WSL2 原生运行**；**macOS / Windows / Linux 都可以用 Docker 容器**（包装脚本首次运行时用仓库里的 `Dockerfile` 在本机构建镜像，不依赖任何镜像仓库），见「[在 macOS / Windows / Linux 上用容器构建](#在-macos--windows--linux-上用容器构建)」。产出的 ISO 只面向 x86_64 (amd64) 目标机。

---

## 为什么这样做，而不是重制 squashfs

| 做法 | 需要 root | 耗时 | 引导记录 | 维护成本 |
|---|---|---|---|---|
| 解包 squashfs → chroot 装包 → 重打 ISO | 要 | 20–40 min | 需要手工重建，易碎 | 高 |
| **本方案：注入 nocloud 种子 + 打补丁 grub** | **不要** | **1–3 min** | **`-boot_image any replay` 原样复用** | **低** |

关键点：软件不是「预装进 squashfs」，而是**装机过程中由安装器自动装上**。所以：

- 不需要动 `casper/filesystem.squashfs`，ISO 体积几乎不变；
- BIOS / UEFI 双启动、Secure Boot 签名链完全不受影响（shim/grub 都是原版）；
- 换 Ubuntu 点版本时，只需拿新 ISO 重跑一次脚本，脚本不用改。

代价：装机仍要走完整安装流程（约 8–15 min），且**必须联网**（见「离线限制」）。

---

## 预装软件栈

`software/` 下的脚本按编号顺序在目标系统 chroot 内执行，**单个失败不拖垮整台机器**：失败的脚本单独记日志，装机照常完成，机器能进去排查。

| 脚本 | 装什么 | 要点 |
|---|---|---|
| `00-base.sh` | 基础依赖 | `policy-rc.d` 拦住 chroot 里的服务启动；修 `resolv.conf`；apt 非交互；含 **git**、**ripgrep**（`rg`） |
| `10-openssh.sh` | openssh-server | 幂等兜底，启用 `ssh.service` |
| `15-github-cli.sh` | GitHub CLI (`gh`) | 官方 apt 源（cli.github.com）；**不**执行 `gh auth` |
| `20-docker.sh` | Docker CE | 官方仓库（非 `docker.io`），含 compose v2 / buildx，**配了日志轮转** |
| `25-nvidia-container-toolkit.sh` | NVIDIA Container Toolkit | 官方仓库；`nvidia-ctk` 合并 Docker runtime（保留 daemon.json 日志轮转）；**不装 GPU 驱动** |
| `30-jenkins.sh` | Jenkins LTS | 优先 JDK 21（不够退 17），jenkins 用户加入 docker 组 |
| `40-nodejs.sh` | Node.js 24 | NodeSource 优先，官方 tarball 兜底 |
| `45-gitea.sh` | Gitea（最新稳定版，可 `--pin-gitea`） | 官方 linux-amd64 二进制（sha256 校验）→ `/usr/local/bin/gitea`；系统用户 `git`；SQLite；**装机阶段写好配置并创建管理员**，开机 `gitea.service` 自启。监听 **0.0.0.0:3000**（不与 Jenkins 8080 冲突），开放注册，LFS 开，`OFFLINE_MODE`。SSH 克隆走系统 OpenSSH：`git@host:user/repo.git` |
| `50-grok.sh` | xAI Grok Build | `@xai-official/grok`，**官方包**，不是社区的 `@vibe-kit/grok-cli` |
| `60-opencode.sh` | OpenCode | `opencode-ai` |
| `70-openmausbot.sh` | OpenMausBot | npm CLI + 一个**故意未启用**的 systemd 单元 |
| `80-unity-cli.sh` | Unity CLI | 官方 CDN 二进制装到 `/usr/local/bin/unity`；**不含 Editor / 登录 / 许可证** |
| `85-godot.sh` | Godot Engine 4.7.2 | 官方 Linux x86_64 标准编辑器 zip → `/opt/godot/4.7.2/` + `/usr/local/bin/godot`；**不含 export templates** |
| `99-cleanup.sh` | 收尾 | 恢复 `resolv.conf`、删 `policy-rc.d`、清 apt 缓存、写清单 |

### 两个版本约束，别忽略

- **Node 必须是 24**。Grok 要 ≥20、opencode 要 ≥18、OpenMausBot 要 **≥24**——最后这个决定了版本下限。Ubuntu 24.04 自带的 Node 18 不够用，所以 `40-nodejs.sh` 走 NodeSource 而不是 `apt install nodejs`。
- **Jenkins 要 Java 17/21**。装成 Java 11 会启动失败，脚本里做了 21→17 的探测回退。

### Gitea：装完即可用

默认预装（`--skip 45` / `--skip 45-gitea` 可跳过）。装机 chroot 里就会：

- 写入 `/etc/gitea/app.ini`（`INSTALL_LOCK=true`，SQLite，每台机器独立生成 `SECRET_KEY` / `INTERNAL_TOKEN` / JWT），并 `gitea migrate`；
- 创建管理员（默认用户名 = `--username`（默认 `ubuntu`），密码 = `--password` 明文（都不传时为默认密码 `ubuntu1990`）；可用 `--gitea-admin-user` / `--gitea-admin-password` / `--gitea-admin-email` 覆盖）。只给了 `--password-hash`、没有明文时，会生成随机密码并写入 **`/root/gitea-admin-password`**（root、0600）。构建时的明文密码单独放在 ISO 的 `/provision/gitea-admin.secret`（0600，不进 `provision.env` / 构建日志），装机用完即删。管理员 `must-change-password=false`，**装完请尽快改掉密码**；
- `systemctl enable gitea.service`（官方单元，`After=network-online.target`）。防火墙规则不动。

开机后浏览器打开 `http://<本机IP>:3000/` 即可（`HTTP_ADDR=0.0.0.0`，局域网可访问）。**开放注册**（`DISABLE_REGISTRATION=false`），局域网里的人都能自助注册；若只想管理员拉人，把该值改成 `true` 后 `sudo systemctl restart gitea`。

网页上显示的克隆地址默认是 `http://localhost:3000/` / `git@localhost:...`（构建时还不知道装到哪台机器）。要改成真实 IP 或域名，编辑 `/etc/gitea/app.ini` 的 `[server]` 段 `ROOT_URL`、`DOMAIN`、`SSH_DOMAIN`，然后重启 Gitea。

SSH 克隆使用系统 OpenSSH（端口 22、用户 `git`，Gitea 维护 `~git/.ssh/authorized_keys`）。不要用 `--username git`（与该系统用户冲突）；若你事后在 sshd 里加了 `AllowUsers`，请把 `git` 加进去。

### 密钥一律不进镜像

这三个 AI CLI 都需要凭据，但**镜像里一个都不放**：

| 工具 | 首次使用 |
|---|---|
| Grok | `export XAI_API_KEY=xai-...`（CI 里走环境变量） |
| OpenCode | `opencode auth login` |
| OpenMausBot | 填 `/etc/openmausbot/env`（0600），再 `systemctl enable --now openmausbot` |
| Unity CLI | 装机后 `unity auth login`，需要 Editor 再 `unity install <ver>`（镜像**不**预装 Editor） |
| GitHub CLI | 装机后 `gh auth login`（镜像只预装二进制） |

理由很直接：镜像会被复制、被外传，烤进去的 key 等于公开。而且 OpenMausBot 本身还依赖「本机已登录的 claude / codex / grok CLI」，这层也必须在跑起来之后才配对。

### 容量与依赖提醒

- 目标盘预留 **≥ 25 GB**（Docker 镜像 + Jenkins workspace 很吃空间）；这套预装本身约占 1.2–1.5 GB（另加 Godot 解压约 140 MB、Gitea 二进制约 115 MB，数据目录随后增长）。
- OpenMausBot 是 Electron 应用，npm 包会拉下较大体积的运行时；服务器上只用 `openmausbot serve`，不需要 X11。
- 首次开机后要跑一次 `apt-get update`——`99-cleanup.sh` 为了缩体积清掉了 `/var/lib/apt/lists`。

### 增删软件

加：在 `software/` 放一个 `85-你的东西.sh`，按现有脚本的约定（`set -euo pipefail`、结尾自带校验命令、失败即非零退出）即可，无需改主脚本。

减：`--skip "30 70"` 跳过 Jenkins 和 OpenMausBot；`--skip "30-jenkins 70-openmausbot"` 等价。整套不要就 `--no-provision`。

---

## 在 macOS / Windows / Linux 上用容器构建

构建逻辑不变（仍是 `build-iso.sh` + `tools/*.sh`），只是打包进一个 Ubuntu 镜像，由薄包装脚本负责挂载目录、改写路径、转发参数：

| 宿主机 | 前置条件 | 入口 |
|---|---|---|
| macOS (Intel / Apple Silicon) | Docker Desktop（或 OrbStack / Colima） | `./scripts/aib.sh` |
| Windows 10/11 | Docker Desktop（WSL2 后端，**Linux containers** 模式） | `.\scripts\aib.ps1`（PowerShell 5.1 / 7） |
| Windows + WSL2 发行版 | 在 WSL 里装 docker 或启用 Docker Desktop 的 WSL 集成 | 在 WSL 里用 `./scripts/aib.sh`，或直接原生 `./build-iso.sh` |
| Linux | docker engine | `./scripts/aib.sh`（或继续原生 `./build-iso.sh`） |

宿主机只需要 Docker 和本仓库（`git clone` 或下载 zip），不必装 xorriso / python / node。

**镜像在本机构建，不从任何 registry 拉取**：
- 第一次运行任意子命令时，包装脚本发现本地没有 `autoinstall-iso-builder:local`，就用仓库根目录的 `Dockerfile` 自动 `docker build`。**首次约 3–10 分钟**（主要是 apt 下载与 Node tarball，取决于网络；Apple Silicon 给 22.04/amd64 构建时更慢），之后每次运行秒级启动。
- `git pull` 更新仓库后加 `--rebuild` 重新构建（Docker 层缓存仍生效，通常只重做最后几层）；镜像带 `aib.revision` 标签，脚本发现镜像比仓库旧时会提示。
- 国内网络：`APT_MIRROR=http://mirrors.aliyun.com/ubuntu ./scripts/aib.sh ...`（PowerShell：`$env:APT_MIRROR='http://mirrors.aliyun.com/ubuntu'`）只影响镜像构建时的 apt 源；DNS/代理受限时可用 `AIB_BUILD_ARGS="--network=host"` 给自动 `docker build` 追加参数。

```bash
# macOS / Linux：子命令后面的参数与 build-iso.sh 完全一致
./scripts/aib.sh build --iso ~/Downloads/ubuntu-24.04.3-live-server-amd64.iso \
  --out out/node01.iso --hostname node01 --username ops \
  --password-hash "$(openssl passwd -6 'Ch@ngeMe')" \
  --ssh-authorized-keys ~/.ssh/id_ed25519.pub

# 最简：不传用户名/密码 → 默认 ubuntu / ubuntu1990（构建时告警，装完请改）
./scripts/aib.sh build --iso ~/Downloads/ubuntu-24.04.3-live-server-amd64.iso --out out/node01.iso

./scripts/aib.sh check-iso out/node01.iso          # 只读检查 user-data（--auto-disk 产物）
./scripts/aib.sh --dry-run build --iso ...          # 只打印 docker 命令, 不运行
```

```powershell
# Windows PowerShell（单引号避免 $6$... 被 PowerShell 展开）
.\scripts\aib.ps1 build --iso C:\isos\ubuntu-24.04.3-live-server-amd64.iso `
  --out out\node01.iso --hostname node01 --username ops `
  --password-hash '$6$rounds=...$...' `
  --ssh-authorized-keys $HOME\.ssh\id_ed25519.pub
```

> Windows 上没有 `openssl` 时可以用 `--password '明文'`（容器内哈希；dry-run 打印时会打码），或在 WSL / Git Bash 里 `openssl passwd -6` 生成哈希。若脚本被执行策略拦截：`powershell -ExecutionPolicy Bypass -File .\scripts\aib.ps1 ...`。

**子命令**：`build`（= build-iso.sh）、`fetch-offline`（= tools/fetch-offline-bundle.sh）、`validate-offline`、`check-iso`（= qemu-smoke --guard-only）、`local-check`、`shell`、`help`、`version`。

**包装选项**（写在子命令之前）：

| 选项 | 作用 |
|---|---|
| （默认） | 本地镜像 `autoinstall-iso-builder:local`（抓 22.04 捆绑用 `:local-jammy`），不存在时自动构建 |
| `--rebuild` | 强制重新 `docker build` 本地镜像 |
| `--image REF` / `AIB_IMAGE` | 改用指定的完整镜像引用（例如自己推到内网 registry 的镜像），此时不再自动构建 |
| `--local` | 兼容旧用法，等同默认（无操作） |
| `--platform P` | 覆盖 docker `--platform`（本地镜像 tag 会带架构后缀，如 `:local-amd64`，避免与本机架构镜像互相覆盖） |
| `--docker-arg A` / `AIB_DOCKER_ARGS` | 追加 docker run 参数（如 `--network=host`、代理环境变量） |
| `--dry-run` | 只打印要执行的 docker 命令（注意：写在子命令**之后**的 `--dry-run` 是 build-iso.sh 自己的干跑） |

**路径与属主**：当前目录挂到容器 `/work`；`--iso` / `--out` / `--offline-bundle` / `--ssh-authorized-keys` / `--debs` / `--iso-sha256sums` / `--cache-root` / `--bundle` 若指向当前目录之外，包装脚本自动把其**父目录**挂到 `/mnt/aibN` 并改写参数（Windows 的 `C:\...` 盘符路径同理）。路径里不能有逗号（docker `--mount` 限制）。Linux / WSL2 上产出文件属于当前用户（容器内用 `AIB_UID/AIB_GID` 降权或事后 chown），不会留下 root 文件。

**本地镜像 tag**：

| tag | 内容 |
|---|---|
| `autoinstall-iso-builder:local` | Ubuntu 24.04 基底，本机架构；`build` / `check-iso` / 抓 24.04 捆绑都用它 |
| `autoinstall-iso-builder:local-jammy` | Ubuntu 22.04 基底，**只在给 22.04 抓离线捆绑时需要**；包装脚本按 `--release jammy` / 22.04 ISO 名自动选择并按需构建 |
| `…-amd64` 后缀 | 仅在 ARM 主机上强制 `linux/amd64`（抓捆绑）时出现 |

### 容器里抓离线捆绑（无需 docker-in-docker）

原生 Linux 上 `fetch-offline-bundle.sh` 默认 `docker run ubuntu:<release>` 解析 apt 依赖闭包（行为不变）。在 builder 容器里则用 **direct 模式**（镜像内置 `AIB_APT_RUNNER=direct`）：容器本身就是对应发行版的 Ubuntu，直接在这个一次性容器里跑 apt，不需要挂 docker.sock。因此镜像发行版必须与目标一致——24.04 用默认镜像，22.04 用 `-jammy` 变体（包装脚本自动选择）。

```bash
./scripts/aib.sh fetch-offline --release noble --out cache/offline-bundles/noble-amd64 --packages "vim,curl"
./scripts/aib.sh fetch-offline --release jammy --out cache/offline-bundles/jammy-amd64   # 自动构建并使用 :local-jammy

./scripts/aib.sh build --iso ubuntu-24.04.3-live-server-amd64.iso --out out/offline.iso \
  --password-hash "$(openssl passwd -6 'Ch@ngeMe')" \
  --offline --offline-bundle cache/offline-bundles/noble-amd64 --packages "vim,curl"
```

- `fetch-offline` 与 `build --fetch-offline` 需要容器以 root 运行（容器内 `apt-get`），结束后自动把捆绑目录 chown 回当前用户。
- **Apple Silicon / ARM**：ISO 重打包与架构无关，`build` 原生 arm64 运行；但 `fetch-offline` 要解析 amd64 的 deb 闭包、打 linux-x64 的 npm 树，包装脚本会强制 `--platform linux/amd64`（Docker Desktop 里建议开启 “Use Rosetta for x86_64/amd64 emulation”，否则 QEMU 仿真会很慢）。
- 默认缓存目录是挂载目录下的 `cache/offline-bundles/`（容器内 `OFFLINE_CACHE_ROOT=/work/cache/offline-bundles`），重复构建可复用。
- `--apt-runner direct` 只能在一次性容器里用（会改写本机 `/etc/apt`）；脚本会检查容器标记、root、发行版代号与架构，不匹配直接失败。

### 手动构建镜像（可选）

包装脚本会自动构建；想手动构建或推到自己的 registry 时：

```bash
docker build -t autoinstall-iso-builder:local .                                   # 24.04 基底
docker build -t autoinstall-iso-builder:local-jammy --build-arg UBUNTU_VERSION=22.04 .
docker build --build-arg APT_MIRROR=http://mirrors.aliyun.com/ubuntu -t autoinstall-iso-builder:local .   # 换 apt 源
./scripts/aib.sh --rebuild version    # 或让包装脚本重建
./scripts/aib.sh --image registry.example.com/aib:1 build ...      # 使用自建镜像
```

### 写 U 盘（各平台）

| 宿主机 | 工具 |
|---|---|
| Windows | [Rufus](https://rufus.ie)（选 **DD 镜像模式**；提示 ISOHybrid 时选 DD）或 [balenaEtcher](https://etcher.balena.io) |
| macOS | balenaEtcher；或命令行 `diskutil list` → `diskutil unmountDisk /dev/diskN` → `sudo dd if=out/node01.iso of=/dev/rdiskN bs=4m` |
| Linux | `sudo dd if=out/node01.iso of=/dev/sdX bs=4M status=progress oflag=sync`，或 balenaEtcher / GNOME Disks |

> 只能用「原样写入」的方式（dd / Etcher / Rufus DD 模式）。Rufus 的 ISO 模式、Ventoy 等会改写/包装引导，可能导致 grub 里注入的 `autoinstall ds=nocloud...` 参数不生效。写盘前务必确认目标盘号，dd 写错盘不可恢复。

### 容器方案的限制

- macOS / Windows 上**不能**直接跑 `test/qemu-smoke.sh` 的完整装机冒烟（需要 qemu + libguestfs，最好有 KVM）；容器里只提供 `check-iso`（只读检查）。完整冒烟请在 Linux 宿主机或 Linux VM 里做。
- 首次运行要现场构建镜像（约 3–10 分钟），需要能访问 Ubuntu apt 源与 nodejs.org。
- CI 只在 ubuntu runner 上跑：容器端到端（自动本地构建 + 假 ISO）以及 bash / PowerShell 包装脚本的 `--dry-run` 断言；不在 macOS / Windows runner 上跑（省分钟数），这两个平台的真机运行未经 CI 覆盖。

---

## 快速开始（WSL2 / Linux）

```bash
sudo apt update && sudo apt install -y xorriso python3-yaml openssl

chmod +x build-iso.sh test/qemu-smoke.sh tools/*.py software/*.sh

# 1. 先干跑，确认 YAML、grub 注入和软件执行顺序都对
./build-iso.sh --iso ubuntu-24.04.1-live-server-amd64.iso \
               --out out/test.iso \
               --hostname ci-node01 --username ops \
               --password-hash "$(openssl passwd -6 'Ch@ngeMe')" \
               --dry-run

# 2. 正式产出
./build-iso.sh --iso ubuntu-24.04.1-live-server-amd64.iso \
               --out out/ubuntu-24.04.1-ci-node.iso \
               --hostname ci-node01 --username ops \
               --password-hash "$(openssl passwd -6 'Ch@ngeMe')" \
               --packages "vim,tmux,net-tools" \
               --mirror http://mirrors.aliyun.com/ubuntu

# 3. 无人值守冒烟（QEMU/CI）需加 --auto-disk，否则会停在选盘页
./build-iso.sh --iso ubuntu-24.04.1-live-server-amd64.iso                --out out/ubuntu-24.04.1-ci-node-autodisk.iso                --hostname ci-node01 --username ops                --password-hash "$(openssl passwd -6 'Ch@ngeMe')"                --auto-disk

# 4. 先在虚拟机跑一遍（务必做，别直接上物理机）
#    qemu-smoke 会先读 ISO 里的 user-data：若 interactive-sections 非空会立刻失败，
#    提示用 --auto-disk 重建（避免空等选盘页直至超时）。
bash test/qemu-smoke.sh out/ubuntu-24.04.1-ci-node-autodisk.iso
bash test/qemu-smoke.sh out/ubuntu-24.04.1-ci-node-autodisk.iso --uefi
```

> WSL2 里操作 `/mnt/c/...` 下的文件会慢 3–5 倍，建议把 ISO 放在 `~/` 下再跑。
>
> npm 在国内会很慢：先 `npm config set registry https://registry.npmmirror.com --location=global`，或在 `40-nodejs.sh` 后加一行。

---

## Ubuntu Desktop 24.04

24.04 起桌面安装器（`ubuntu-desktop-bootstrap`，Flutter 前端 + Subiquity 后端）与 Server 共用 autoinstall，所以同一套 NoCloud 种子 + grub 注入可直接用于 Desktop ISO。

```bash
# 校验后构建（--edition 可省略：ISO 会被自动识别为 desktop）
./build-iso.sh --iso ubuntu-24.04.5.1-desktop-amd64.iso \
  --iso-sha256sums SHA256SUMS \
  --out out/ubuntu-24.04-desktop-autoinstall.iso \
  --edition desktop \
  --desktop-source minimal \
  --hostname desk01 --username alice --realname "Alice" \
  --password-hash "$(openssl passwd -6 'Ch@ngeMe')" \
  --ssh-authorized-keys ~/.ssh/id_ed25519.pub

# 全离线 Desktop：同一份 noble 捆绑可直接复用（见「全离线模式」）
./build-iso.sh --iso ubuntu-24.04.5.1-desktop-amd64.iso \
  --out out/ubuntu-24.04-desktop-offline.iso \
  --password-hash "$(openssl passwd -6 'Ch@ngeMe')" \
  --offline --offline-bundle cache/offline-bundles/noble-amd64
```

### 与 Server 的差异（脚本自动处理）

| 项 | Server | Desktop 24.04 |
|---|---|---|
| 识别 | `install-sources.yaml` 里 `variant: server` | `variant: desktop`（`.disk/info` 兜底） |
| 注入的菜单 | `Try or Install`（含 `Try or Install Ubuntu Server`） | `Try or Install Ubuntu` **和** `Ubuntu (safe graphics)`（N 卡/新显卡黑屏时用后者，同样自动装）；正则锚定，**不会**误匹配 Server 菜单 |
| `source.id` | 不写（ISO 默认 `ubuntu-server`） | `ubuntu-desktop-minimal`（默认，与桌面安装器默认一致、体积小）或 `--desktop-source standard` → `ubuntu-desktop`（含 LibreOffice 等） |
| `identity.realname` | 仅在 `--realname` 时写 | 必写，默认 = `--username` |
| 网络 | `autoinstall.network` 写 en*/eth* DHCP（networkd） | **不写** `autoinstall.network`（live 会话由 NetworkManager 管，写 networkd 配置会互相打架）；late-command 写 `/etc/netplan/50-autoinstall-dhcp.yaml`，带 `renderer: NetworkManager` + en*/eth* DHCP，并关掉 cloud-init 网络改写。`--network none` 则只保留桌面默认（NetworkManager 自动 DHCP） |
| SSH | 安装器 `install-server: true`（Server ISO 自带 openssh-server） | 在线：同左，但**需要联网**（官方：Desktop ISO 不含 openssh-server）；全离线：`install-server: false`，改由 `10-openssh.sh` 从离线捆绑安装（因此全离线 Desktop 不允许 `--no-provision`） |
| 选盘 | 默认停在选盘页 | 同左：图形安装器停在「安装类型/磁盘」页，确认后继续 |
| 配置投递 | `/nocloud` + 内核参数 | 同左；另在 ISO 根放一份 `/autoinstall.yaml` 兜底（Subiquity 优先级：内核参数 > live 根 > cloud-config > 介质根，正常不会用到） |

`software/*.sh` 在 Desktop 目标上不需要改：Desktop minimal 不带 curl/git/openssh-server，`00-base`/`10-openssh` 会补装；已装的包（ca-certificates、gnupg、jq 等）照旧跳过。GitHub CLI / Docker / NVIDIA Container Toolkit / Jenkins / Node / Gitea / Grok / OpenCode / OpenMausBot / Unity CLI / Godot 与 Server 相同（Toolkit **不含** GPU 驱动；Unity CLI **不含** Editor；Godot **不含** export templates）。

### 离线：Desktop 能不能全离线？

能，且**不需要单独的 Desktop 捆绑**。`fetch-offline-bundle.sh` 在最小 `ubuntu:24.04` 容器里强制下载**完整递归依赖闭包**（含容器里已装的库），因此与目标系统已装了什么无关；Desktop 目标上 apt 只会挑缺的/需升级的包。注意：

- Desktop ISO 自带的 `/pool`（约 360 个包，主要是驱动/语言包/引导相关）**不含** openssh-server、curl、git、Docker 等，不能代替捆绑。
- 桌面本身（GNOME 等）来自 ISO 的 `minimal*.squashfs` 分层镜像，装机阶段本来就不联网。
- 输出 ISO ≈ 6 GB（+ 捆绑约 0.6–0.8 GB），**只能写 U 盘**（≥ 8 GB），DVD 装不下。
- 已验证（2026-11）：把 24.04.5.1 Desktop 的 `casper/minimal.squashfs` 解包成 rootfs，在**无网络命名空间**里按 late-commands 顺序执行 `enable-offline-apt.sh` → `run-all.sh` → `restore-online-apt.sh`，9 个脚本全部成功（openssh-server / curl / git / Docker 29 / Jenkins + JDK 21 / Node 24 / grok / opencode / openmausbot），`dpkg --audit` 干净。完整图形装机 E2E 另行在实体机/KVM 上验证。

### 限制与已知问题

- **只支持 24.04+ Desktop**。22.04 Desktop 是 Ubiquity（preseed），没有 `casper/install-sources.yaml`，脚本会直接报错退出。
- Desktop 安装器是图形界面，串口（`console=ttyS0`）看不到进度；`qemu-smoke.sh` 只能靠装完后读盘断言。Desktop 建议 `QEMU_MEM=8192 QEMU_DISK=40G`。冒烟前会检查 ISO 的 `interactive-sections`：非空（默认停选盘）直接退出并提示 `--auto-disk`；装完后会在 `/usr/bin`、`/usr/sbin`、`/usr/local/bin` 核对 `git`/`gh`/`rg`/`docker`/`nvidia-ctk`/`node`/`unity`/`godot`/`gitea`/`sshd` 等，并检查 `gitea.service` 已 enable、`/etc/gitea/app.ini` 含 `INSTALL_LOCK = true`。
- 带 interactive-sections 时 Subiquity 忽略 `reporting`；旧版桌面安装器在部分交互时「确认页」可能显示空白（[ubuntu-desktop-provision#926](https://github.com/canonical/ubuntu-desktop-provision/issues/926)，2026-08 已有人报告修复），返回再前进即可。
- `drivers` / `codecs` / `oem` 未设置，沿用 Subiquity 默认值。
- UEFI：24.04 Desktop 的 ESP 里只有 `bootx64/grubx64/mmx64.efi`，没有 grub.cfg 副本，所以改 `/boot/grub/grub.cfg` 即同时对 BIOS/UEFI 生效（已在 24.04.5.1 Desktop ISO 上确认）。

参考：[Autoinstall 参考](https://canonical-subiquity.readthedocs-hosted.com/en/latest/reference/autoinstall-reference.html)（`source.id`、`ssh.install-server`、`interactive-sections`），[Providing autoinstall](https://github.com/canonical/subiquity/blob/main/doc/tutorial/providing-autoinstall.rst)（投递方式与优先级）。

---

## 注入后 ISO 里到底改了什么

改动全在 ISO 根目录，不碰任何引导二进制：

```
/nocloud/user-data        # subiquity autoinstall 配置
/nocloud/meta-data        # NoCloud 数据源的实例标识
/provision/*.sh           # 软件预装脚本 + provision.env
/boot/grub/grub.cfg       # linux 行追加 autoinstall ds=nocloud\;s=/cdrom/nocloud/
/boot/grub/loopback.cfg   # 同上（Ventoy / 多启动 U 盘走这个）
/autoinstall.yaml         # 仅 Desktop：同一份配置的兜底副本
```

装到一半出问题，可以单独重跑某个脚本：

```bash
sudo bash /opt/provision/20-docker.sh
cat /var/log/autoinstall/20-docker.log
```

`ds=nocloud\;s=/cdrom/nocloud/`（GRUB 中分号必须转义）里的 `/cdrom` 是安装器把 ISO 挂载的位置——这也是为什么种子必须放在 ISO 内部，而不是第二块 U 盘上。

---

## 参数一览

| 参数 | 说明 |
|---|---|
| `--iso` / `--out` | 输入/输出路径，必填 |
| `--password-hash` | **推荐**。`openssl passwd -6 '密码'` 的结果 |
| `--password` | 明文，脚本自动哈希；会进 shell 历史，仅调试用 |
| `--username` | 默认 `ubuntu`（`git` 与 Gitea 系统用户冲突，会被拒绝） |
| （都不传密码） | `--password` / `--password-hash` 都没给时，使用**默认密码 `ubuntu1990`**（构建时告警），Gitea 管理员同样是 `ubuntu` / `ubuntu1990`。这是公开的默认值，**装完请立即改**：`passwd`，并在 Gitea 网页里改管理员密码 |
| `--packages` | 逗号分隔、**不要空格**（如 `vim,curl,htop`）；走 subiquity 的 apt（第三方包走 `software/`） |
| `--mirror` | 内网源务必替换，否则每台机器都从公网拉 |
| `--no-provision` | 不执行 `software/`，只做裸装机 |
| `--skip "30 70"` | 跳过脚本：编号前缀或完整名均可（`30` / `30-jenkins`） |
| `--strict` | 任一软件装失败就中止安装（默认记日志继续） |
| `--offline` | apt `fallback: offline-install`（`updates` 仍为 Subiquity 合法值 `security`；无 `none`） |
| `--force-fetch` | 配合 `--fetch-offline`：忽略捆绑 fingerprint，强制重建离线包 |
| `--offline-bundle DIR` | 使用已抓取的离线捆绑目录；构建前会 `validate-offline-bundle` |
| `--debs DIR` | 把目录下 `.deb` 打进 `/pool` 并离线安装 |
| `--storage-layout` | `direct`（默认）/ `lvm` / `zfs`。作为选盘页的**预选布局**；默认仍要你在 UI 确认后才继续 |
| `--auto-disk` | **危险**。跳过硬盘选择，按 `match size: largest` 自动抹最大盘。默认关闭；仅给 QEMU/CI 无人值守。物理机请保持默认。开启后 `shutdown: poweroff`（关机不重启），避免 U 盘未拔时循环抹盘 |
| `--network` | `dhcp`（默认）/ `none`。默认写入 netplan match `en*`/`eth*` 的 DHCP（`optional: true`），并用 late-command 落盘 `/etc/netplan/50-autoinstall-dhcp.yaml`（mode 600）+ 禁用 cloud-init 网络改写，保证**离线无网卡装机**后首启插网也能 DHCP。`none` 则不写。静态 IP 后续再加。 |
| `--ssh-allow-pw` | 默认 `true`。设为 `false` 时**必须**同时提供 `--ssh-authorized-keys`，否则构建直接失败；与 `10-openssh.sh` 保持一致 |
| `--ssh-authorized-keys FILE` | 公钥文件（每行一把，忽略空行/注释），写入 `ssh.authorized-keys`，并经 `/nocloud/write-authorized-keys.sh` late-command 再写入用户 `~/.ssh/authorized_keys`（防 Subiquity 漏写）；建议配合 `--ssh-allow-pw false` |
| `--iso-sha256 HEX` | 可选源 ISO SHA256；不匹配立即失败 |
| `--iso-sha256sums FILE` | 按 ISO basename 在 SHA256SUMS 文件中查找校验和；优先于 `--iso-sha256` |
| `--pin-node N` | Node 主版本（默认 24）；环境变量 `PIN_NODE_MAJOR` |
| `--pin-grok / --pin-opencode / --pin-openmausbot VER` | npm 包版本（默认 latest）；亦可用 `PIN_GROK` / `PIN_OPENCODE` / `PIN_OPENMAUSBOT` |
| `--pin-unity-cli VER` | Unity CLI 版本（默认拉 stable，若无则 beta）；亦可用 `PIN_UNITY_CLI` |
| `--pin-gitea VER` | Gitea 版本（默认 `latest`，从 `dl.gitea.com/gitea/version.json` 解析；亦可 `PIN_GITEA=28.3.0`） |
| `--gitea-admin-user U` | Gitea 管理员用户名，默认 = `--username` |
| `--gitea-admin-password P` | Gitea 管理员密码（至少 8 位），默认 = `--password` 明文；只给了 `--password-hash` 时装机写入 `/root/gitea-admin-password` |
| `--gitea-admin-email E` | Gitea 管理员邮箱，默认 `<用户名>@localhost` |
| `--edition` | `auto`（默认）/ `server` / `desktop`。`auto` 读 ISO 的 `casper/install-sources.yaml`（`variant: desktop/server`），退回 `.disk/info`；显式指定优先 |
| `--desktop-source` | 仅 desktop：`minimal`（默认，`ubuntu-desktop-minimal`）/ `standard`（`ubuntu-desktop`）/ 任意 source id；会对照 ISO 的 install-sources.yaml 校验 |
| `--realname` | `identity.realname`（登录界面显示名）；desktop 默认等于 `--username` |
| `--menu-regex` | 要注入的菜单标题正则。默认 server `Try or Install`；desktop `^(Try or Install Ubuntu\|Ubuntu \(safe graphics\))$` |


### 默认 DHCP 网络

默认 `--network dhcp`：

1. autoinstall `network:` 使用 netplan v2，对 `en*` / `eth*` 做 match，`dhcp4`/`dhcp6` + `optional: true`（无网线不拖慢开机）。
2. late-commands 额外写入 `/etc/netplan/50-autoinstall-dhcp.yaml`（`chmod 600`），并写 `cloud.cfg.d/99-disable-network-config.cfg` 关闭 cloud-init 网络覆盖；同时删除可能由 Subiquity 在**无 NIC 安装**时生成的空/按名 `00-installer-config.yaml`。

背景：未显式写 `network:` 时，Subiquity 会把安装时探测到的网卡写进目标系统；`-nic none` 全离线装机后首启就没有 DHCP。本默认修复该问题。

用 `--network none` 可恢复「不注入网络段」的旧行为。


### 默认停在硬盘选择（安全）

默认 `interactive-sections: [storage]`：装机**停在选盘页**，其它步骤（用户名、时区、网络、SSH、软件预装）仍自动。`storage.layout`（含 `match.size: largest`）会作为 Subiquity 界面上的**预选项**，但不会自动开写，需你确认。

- 物理机 / 多盘机：**保持默认**，自己选目标盘。
- QEMU / CI 无人值守：构建时加 `--auto-disk`（等同 `interactive-sections: []`），才会按 largest 直接抹盘。

确认后 `late-commands`（含 `/provision`、离线捆绑、DHCP netplan、authorized_keys）照常执行。


### 完整性与版本复现

- 推荐先验证官方 `SHA256SUMS.gpg`（用 Ubuntu CD Image signing key），再传 `--iso-sha256sums SHA256SUMS`；脚本只验证 SHA256，不替代 GPG 签名验证。
- `--pin-grok` / `--pin-opencode` / `--pin-openmausbot` / `--pin-gitea` 给具体版本可避免 `latest` 漂移。默认仍为 `latest`。
- `--pin-node 24` 只钉主版本；NodeSource、Docker、Jenkins 仍跟随其稳定仓库，尚未做完整 apt 版本锁。
- Jenkins apt 源自 2026-01 起需 `jenkins.io-2026.key`（2023 密钥已过期）；本仓库脚本已切换。若要求严格复现，应使用内网快照源并固定 `.deb` 版本。当前默认行为不变，不承诺 bit-for-bit 可复现。
- `apt.primary` 暂保留 legacy 格式以兼容 22.04 的旧版 Subiquity（且安装器刷新关闭）；24.04-only 项目可迁移到 `mirror-selection.primary`。

### 快速校验与 CI

```bash
bash test/local-check.sh
```

覆盖 Python 语法、grub 转义/幂等/旧参数修复、user-data YAML、默认 interactive storage / `--auto-disk`、公钥、pool-before-provision 顺序与 skip 前缀、`qemu-smoke` 对交互选盘 ISO 的拒绝（迷你 ISO + `--guard-only`，无需真开机），以及 Desktop 24.04（基于真实 24.04.5.1 Desktop ISO 抽出的 grub.cfg / loopback.cfg / install-sources.yaml 夹具）的版本识别、菜单注入与渲染语义。`.github/workflows/ci.yml` 在 PR/push 上运行 ShellCheck、这些校验、包装脚本 dry-run，以及用 `test/make-fake-iso.sh` 拼的假 ISO（只有 grub.cfg / install-sources.yaml / .disk/info，几百 KB）端到端跑一遍 `build-iso.sh`（Server + Desktop）。同一个 workflow 的 `container-smoke` job（PR 与 main）经 `scripts/aib.sh` 自动本地构建镜像，在容器里再跑一遍假 ISO 端到端；包装脚本 dry-run 同时测 bash 与 PowerShell（ubuntu runner 自带 pwsh）。镜像不推送到任何 registry。BIOS/UEFI/QEMU 与 Secure Boot 验证见下文，不在轻量 CI 下载真实 ISO。

### 全离线模式（`--offline` + `--offline-bundle`）

目标：装机过程**零外网请求**，装完仍有 Docker / Jenkins / Node 24 / Grok / OpenCode / OpenMausBot / Unity CLI / Godot / Gitea。

```bash
# 1) 构建期联网抓取捆绑（按发行版缓存，可复用）
./tools/fetch-offline-bundle.sh --release noble --out cache/offline-bundles/noble-amd64 \
  --packages "vim,curl,htop,net-tools"

# jammy (22.04) 同理:
# ./tools/fetch-offline-bundle.sh --release jammy --out cache/offline-bundles/jammy-amd64

# 2) 烧进 ISO（QEMU 无人值守冒烟请加 --auto-disk；物理机不要加）
./build-iso.sh --iso ubuntu-24.04.x-live-server-amd64.iso \
  --out out/ubuntu-24.04-offline.iso \
  --password-hash "$(openssl passwd -6 'Ch@ngeMe')" \
  --offline --offline-bundle cache/offline-bundles/noble-amd64 \
  --packages "vim,curl,htop,net-tools" \
  --auto-disk

# 或一步：--fetch-offline 自动抓取后再打包
# ./build-iso.sh ... --offline --fetch-offline --packages "vim,curl" --auto-disk

# 3) 无网卡冒烟（需本机 qemu；ISO 需用 --auto-disk 构建）
bash test/qemu-smoke.sh out/ubuntu-24.04-offline.iso --offline-nic
```

原理简述：

| 阶段 | 行为 |
|---|---|
| `fetch-offline-bundle.sh` | 在 `ubuntu:24.04`/`22.04` 容器内解析完整 deb 依赖闭包（Ubuntu + Docker + NVIDIA Container Toolkit + Jenkins + NodeSource），`dpkg-scanpackages` 生成本地 apt 源；同时把第三方 **keyring + `.list`/`.sources`** 存进 `apt-sources/`；宿主机 `npm` 打全局 prefix 树；另存 Node 官方 tarball、Unity CLI 二进制（`unity-cli/`，约 128 MB）、Godot 4.7.2 zip（`godot/`，约 75 MB）与 Gitea linux-amd64 二进制（`gitea/`，约 115 MB，官方 sha256 校验）兜底 |
| ISO | 写入 `/offline/{apt,apt-sources,npm,node,unity-cli,godot,gitea,manifest.json}` |
| 装机 late-commands | 拷到 `/opt/offline`，临时只启用 `deb [trusted=yes] file:/opt/offline/apt ./`，再跑 `software/`（`OFFLINE=1`） |
| `software/*.sh` | 离线时不 curl、不加远程源；npm CLI 从 `prefix.tar.gz` 解压；Unity CLI 从 `unity-cli/` 安装；Godot 从 `godot/` 安装；Gitea 从 `gitea/` 安装 |
| `restore-online-apt.sh` | 卸掉离线 pin、恢复 Ubuntu 官方源后，把捆绑内 **全部** `apt-sources/` 种子写回（Docker CE / GitHub CLI / NVIDIA toolkit / Jenkins / NodeSource；与在线脚本同一批 URL/密钥）。装机时可能仍无网，此处不做 `apt update`；联网后即可收安全更新。纯在线构建不会调用本脚本 |

体积与缓存：

- 捆绑按 `cache/offline-bundles/<release>-<arch>/` 存放；`manifest.json` 含 `fingerprint`（schema 3：release/arch/pins/seeds，含 `apt-sources`）。指纹一致才复用，否则或旧格式需 `--force` 重建。构建时 `validate-offline-bundle.sh` 会核对 apt 种子包、`apt-sources/` keyring+list，以及 `unity-cli/`、`godot/`、`gitea/` 等目录；失败则提示 `--force` / `--force-fetch`。
- `--fetch-offline` 用 **ISO 识别到的 release**（非仅文件名）选 jammy/noble；加 `--force-fetch` 等价于给 fetch 传 `--force`。
- npm/`node` 打包使用 `--owner=0 --group=0`；安装时 `tar --no-same-owner`，Node 解到 `/opt/node-…` 再 symlink，避免 `/usr/local` 属主变成 uid 1000。
- 全离线装完写回第三方 apt 源：`apt-sources/` 在 fetch 时按在线脚本同款材料抓取；`restore-online-apt.sh` **全量写回**捆绑内种子（不按 `--skip` 裁剪）。旧捆绑缺 `apt-sources/` 时需 `--force` 重建。
- `provision.env` 全部 `printf %q` 写入，避免 `--packages "vim, htop"` 这类值在 source 时把包名当命令执行。
- 实测（本仓库验证机，2026-11）：**noble+npm ≈ 648 MB**（150 debs + npm prefix ≈329 MB 压缩）；**jammy apt-only（--skip-npm）≈ 312 MB**（127 debs）。含 OpenMausBot 时 npm 树是大头；U 盘请预留 ≥ 镜像+捆绑余量。
- `--packages` 会并进捆绑；全离线时 autoinstall 的 `packages:` 置空，改由 `00-base.sh` 从本地 apt 安装，避免安装器阶段无索引。

兼容：`--debs DIR` 旧局部离线仍可用；与全离线捆绑互斥场景下优先 `--offline-bundle`。

### 离线限制（重要）

> 若使用上文「全离线模式」，可忽略本段。

**无捆绑**时的旧 `--offline` 只影响 autoinstall apt fallback；第三方脚本仍会联网。当前这套软件栈里：

- GitHub CLI / Docker / NVIDIA Container Toolkit / Jenkins / NodeSource 走各自第三方仓库 → 需要下载 `.deb` 后配 `--debs`
- Grok / OpenCode / OpenMausBot 是 **npm 全局包** → 需要预建 npm 缓存（`npm cache add`）或打成 tarball 后离线 `npm install -g ./xxx.tgz`
- Unity CLI 是 CDN 二进制（`public-cdn.cloud.unity3d.com`）→ 全离线捆绑的 `unity-cli/`；无捆绑时脚本会联网下载
- Godot 是官方 zip（GitHub releases / downloads.godotengine.org，固定 **4.7.2**）→ 全离线捆绑的 `godot/`；无捆绑时脚本会联网下载；**不含** export templates
- Gitea 是官方二进制（`dl.gitea.com`，默认 latest，可用 `--pin-gitea`）→ 全离线捆绑的 `gitea/`；无捆绑时脚本会联网下载并用官方 `.sha256` 校验

真正要全离线，建议改为「内网镜像源 + 自建 npm registry（Verdaccio）」，比往 ISO 里塞依赖靠谱得多。

---

## 验收标准（别跳过）

1. `--dry-run` 的 YAML 能被 `yaml.safe_load` 解析（脚本已内置校验）。
2. `xorriso -indev out.iso -report_el_torito plain` 里 **BIOS 与 UEFI 两个引导项都在**。
3. 虚拟机 BIOS + UEFI 各装一次，`virt-cat` 读到的 `/var/log/autoinstall/manifest.txt` 里 git / gh / rg / docker / nvidia-ctk / node / grok / opencode / openmausbot / unity / godot / gitea 都有版本号。
4. `provision-failed.txt` 为空。
5. 重启后 `systemctl status docker jenkins ssh gitea` 都是 active；浏览器打开 `http://<IP>:3000/` 能进（开放注册），用构建时的管理员账号即可登录。

---

## 常见失败与定位

| 现象 | 原因 | 处理 |
|---|---|---|
| 卡在 `Subiquity` 欢迎页，配置没被读到 | grub 参数没进去，或路径写错 | `--dry-run` 看注入后的 `linux` 行；确认是 `/cdrom/nocloud/` 带尾斜杠 |
| 报 YAML 解析错 | 渲染后缩进被破坏 | 用 `--dry-run` 输出贴到 `python3 -c "import yaml;yaml.safe_load(open('u.yaml'))"` |
| `apt` 阶段长时间卡住 | 无网但没加 `--offline` | 加 `--offline`，或换内网 `--mirror` |
| 装完重启又装一遍 | U 盘仍在启动顺序首位 | 装机后拔盘，或在 BIOS 里把硬盘提到前面 |
| Ventoy 启动不生效 | 走的是 `loopback.cfg` | 确认输出里有 `loopback.cfg` 的 patch 日志；新版 Ventoy 需在菜单按 `F6` 用 grub2 模式 |
| 装完 SSH 登不进 | `allow-pw: false` 且无公钥 | 构建期已拒绝该组合；补 `--ssh-authorized-keys` 或 `--ssh-allow-pw true` |
| 报 `no disk found` / 抹错盘 | 多盘/RAID，或误开 `--auto-disk` | **默认会停在选盘页**，直接在 UI 选对盘。无人值守才加 `--auto-disk`；仍自动失败时可改 `storage.layout.match`（serial/path），勿盲目依赖 `size: largest` |
| `jenkins.service` 起不来 | Java 版本不对 | 看 `/var/log/autoinstall/30-jenkins.log`；确认装的是 21 或 17 |
| `npm install` 超时 / 404 | 公网 registry 不通 | 换 `registry.npmmirror.com`，或改走内网 Verdaccio |
| `docker` 命令要 sudo | 组权限未生效 | 重新登录（组变更需新会话） |
| `docker run --gpus` 失败 | **未装 GPU 驱动**（本镜像只预装 Toolkit） | 在目标机另行安装 NVIDIA 驱动后再用；无 GPU 的 VM 只能验证 `nvidia-ctk --version` / daemon.json |
| `unity` 能跑但装不了 Editor / 未登录 | **镜像只预装 CLI** | 装机后 `unity auth login`，再 `unity install <ver>`；许可证另激活 |
| 浏览器打不开 Gitea / 克隆地址是 localhost | 服务未起，或 `ROOT_URL` 仍是默认 | `systemctl status gitea`；确认本机防火墙未拦 3000 端口（脚本**不**改防火墙）。网页显示的地址要改的话，编辑 `/etc/gitea/app.ini` 的 `ROOT_URL` / `DOMAIN` / `SSH_DOMAIN` 后 `systemctl restart gitea` |
| 忘记 Gitea 管理员密码 | 只给了 `--password-hash` 构建 | 看 `/root/gitea-admin-password`（root 0600）；若用了 `--password`，密码与系统用户相同（装完请改掉） |
| `git@host:...` SSH 克隆被拒 | `AllowUsers` 没包含 `git`，或没把公钥加到 Gitea | 系统 OpenSSH + 用户 `git`；在 Gitea 里给用户添加 SSH 公钥。sshd 默认没有 `AllowUsers` |
| `openmausbot` 打不开窗口 | 它是 Electron 应用 | 服务器上只能用 `openmausbot serve` |
| 装完没有服务自启 | `policy-rc.d` 没删掉 | 确认 `99-cleanup.sh` 跑过；检查 `/usr/sbin/policy-rc.d` 不存在 |

---

## 版本差异备忘

- **22.04 / 24.04**：`preseed` 已彻底废弃，只有 autoinstall；ISO 挂载点都是 `/cdrom`。
- **24.04**：仍是 casper + subiquity，`/boot/grub/grub.cfg` 与 `loopback.cfg` 结构不变，菜单文案为 `Try or Install Ubuntu Server`，默认正则能匹配。
- **22.04 注意**：`openjdk-21-jre-headless` 不一定有，脚本会自动退到 17，Jenkins 仍可用。
- **Desktop 版**：24.04+ 支持（`--edition desktop` 或自动识别），菜单 `Try or Install Ubuntu` / `Ubuntu (safe graphics)` 都会注入，自动补 `identity.realname` 与 `source.id`；22.04 Desktop（Ubiquity）不支持。
- **镜像点版本升级**：直接拿新 ISO 重跑脚本，`xorriso -boot_image any replay` 会自动适配新的引导布局。

---

## 附录：UEFI 启动没读到配置怎么办

绝大多数 22.04/24.04 ISO 的 `boot/grub/efi.img` 里，`EFI/boot/grub.cfg` 只是 `source /boot/grub/grub.cfg`，所以改主文件就够了。少数版本会把菜单**复制**一份进 efi.img，此时 BIOS 生效、UEFI 不生效。手工兜底：

```bash
xorriso -osirrox on -indev ubuntu.iso -extract /boot/grub/efi.img ./efi.img

sudo apt install -y mtools
mcopy -i efi.img ::/EFI/boot/grub.cfg ./efi-grub.cfg
python3 tools/patch-grub.py --file ./efi-grub.cfg --menu-regex 'Try or Install' --timeout 3
mcopy -o -i efi.img ./efi-grub.cfg ::/EFI/boot/grub.cfg

xorriso -indev ubuntu.iso -outdev out.iso \
        -map ./nocloud /nocloud \
        -map ./grub.cfg /boot/grub/grub.cfg \
        -map ./efi.img  /boot/grub/efi.img \
        -boot_image any replay -commit
```

先跑 `--uefi` 的冒烟测试，确认菜单里带着 `autoinstall` 再上物理机。

---

## 落盘前最后确认

- 口令是哈希，不是明文；哈希本身也别提交到公开仓库。若用 `--password` 构建，Gitea 管理员明文会短暂出现在 ISO 的 `/provision/gitea-admin.secret`（0600），装机后从目标机删除；拿到 ISO 的人在安装前仍可能读到，请勿把此类 ISO 公开分发。
- 没有任何 API key / 私钥进镜像。SSH **公钥**可通过 `--ssh-authorized-keys` 注入，属于公开信息；私钥绝不注入。
- 目标机磁盘 ≥ 25 GB，且装机时能访问 cli.github.com / docker.com / nvidia.github.io / pkg.jenkins.io / deb.nodesource.com / npm registry / unity.com（install.sh）与 `public-cdn.cloud.unity3d.com`（Unity CLI 二进制）、`github.com/godotengine/godot` 或 `downloads.godotengine.org`（Godot 4.7.2），以及 `dl.gitea.com`（Gitea 二进制与 sha256）。全离线捆绑可免除这些外网依赖。

这条线一旦破，后面所有「镜像管理」都失去意义。
