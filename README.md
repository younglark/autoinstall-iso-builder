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
| `12-avahi-mdns.sh` | Avahi（mDNS） | 预装了 Gitea 或 Jenkins 时启用：装 `avahi-daemon` + `libnss-mdns`（Desktop 自带则跳过 apt；Server 补装，离线走捆绑），enable `avahi-daemon`，让局域网能用 `<主机名>.local` 访问本机；ufw **已启用**时放行 `5353/udp`，不会主动启用 ufw。详见下文「Gitea / Jenkins 的访问地址」 |
| `15-github-cli.sh` | GitHub CLI (`gh`) | 官方 apt 源（cli.github.com）；**不**执行 `gh auth` |
| `20-docker.sh` | Docker CE | 官方仓库（非 `docker.io`），含 compose v2 / buildx，**配了日志轮转** |
| `24-nvidia-driver.sh` | NVIDIA 驱动 595（open）+ Intel VA-API | **每台机器都装，不检测硬件**（`--no-nvidia-driver` 或 `--skip 24` 关闭）。Ubuntu 官方 `nvidia-driver-595-open` + Canonical 签名的预编译模块 `linux-modules-nvidia-595-open-<flavour>` + **同版本**内核 meta（不走 DKMS，Secure Boot 下可直接加载，不登记 MOK）；另装 `intel-media-va-driver-non-free`、`vainfo`。模块和内核版本对不上时**跳过并记日志**，不让装机失败。详见下文 |
| `25-nvidia-container-toolkit.sh` | NVIDIA Container Toolkit | 官方仓库；`nvidia-ctk` 合并 Docker runtime（保留 daemon.json 日志轮转）；GPU 驱动由 `24-nvidia-driver.sh` 装 |
| `30-jenkins.sh` | Jenkins LTS | 优先 JDK 21（不够退 17），jenkins 用户加入 docker 组；**零配置**：跳过安装向导、装机时建好管理员、预装 Pipeline / Git / Gitea / Docker Pipeline / Docker Cloud / Rebuild / AnsiColor / Parameterized Trigger 等插件（含全部依赖），监听 **0.0.0.0:8080**，Jenkins URL 设为 `http://<主机名>.local:8080/` |
| `35-microsoft-edge.sh` | Microsoft Edge 稳定版 | **仅 Desktop + amd64 默认安装**（Server / 非 amd64 自动跳过，`--skip 35` 也可跳过）。官方 apt 源 `packages.microsoft.com/repos/edge`；设为默认浏览器（`update-alternatives` + 系统/用户 `mimeapps.list`）；GNOME 收藏夹用 Edge 替换 Firefox（Firefox **保留**）；策略关掉首次运行提示，**不**关闭自动更新 |
| `36-x11vnc-xorg.sh` | 关 Wayland（**Desktop 默认**）+ 可选 x11vnc | 仅 Desktop（Server 跳过）。GDM 登录界面、锁屏、会话都走 Xorg；装了远程桌面时关掉合盖/空闲挂起。`--remote-desktop x11vnc` 时在这里装 x11vnc。`--wayland` 保留 Wayland；`--skip 36` 也可跳过。详见下文「远程桌面」 |
| `37-flclash.sh` | FlClash（ClashMeta 图形客户端） | **仅 Desktop 默认安装**（Server / 非 amd64·arm64 自动跳过；`--no-flclash` 或 `--skip 37` 也可跳过）。官方 GitHub Release 的 linux `.deb`（同级 `SHA256SUMS` 校验），**始终安装最新稳定版**。**只装应用**：不写订阅、不设系统代理、不启用 TUN、不装开机自启。详见下文 |
| `38-rustdesk.sh` | RustDesk（**Desktop 默认远程桌面**） | 仅 Desktop + amd64/arm64。官方 GitHub Release 的 `.deb`（钉扎 1.5.1，sha256 校验，`--pin-rustdesk` 可改）；开启局域网 **IP 直连**（`21118/tcp`）、只用**固定密码**（默认 = `--password`），开机即可从登录界面、锁屏、会话连。`--remote-desktop x11vnc\|none` 换掉或不装；`--skip 38` 也可跳过。详见下文「远程桌面」 |
| `39-grok-bot.sh` | Grok Bot 桌面版 | **仅 Desktop 默认安装**（Server / 非 amd64·arm64 自动跳过；`--no-grok-bot` 或 `--skip 39` 也可跳过）。官方 linux `.deb`（发布 feed 的最新版，sha256 用签名 apt 索引或内置值校验；`--grok-bot-version` / `--grok-bot-url` + `--grok-bot-sha256` 可钉扎）；保留官方 apt 源，之后随 `apt upgrade` 更新。**只装应用**：不登录、不预置配置。失败只记 SKIP，不影响装机。详见下文 |
| `40-nodejs.sh` | Node.js 24 | NodeSource 优先，官方 tarball 兜底 |
| `45-gitea.sh` | Gitea（最新稳定版，可 `--pin-gitea`） | 官方 linux-amd64 二进制（sha256 校验）→ `/usr/local/bin/gitea`；系统用户 `git`；SQLite；**装机阶段写好配置并创建管理员**，开机 `gitea.service` 自启。监听 **0.0.0.0:3000**（不与 Jenkins 8080 冲突），`ROOT_URL` 为 `http://<主机名>.local:3000/`，开放注册，LFS 开，`OFFLINE_MODE`。SSH 克隆走系统 OpenSSH：`git@host:user/repo.git` |
| `50-grok.sh` | xAI Grok Build | `@xai-official/grok`，**官方包**，不是社区的 `@vibe-kit/grok-cli` |
| `60-opencode.sh` | OpenCode | `opencode-ai` |
| `70-openmausbot.sh` | OpenMausBot | npm CLI + 一个**故意未启用**的 systemd 单元 |
| `80-unity-cli.sh` | Unity CLI | 官方 CDN 二进制装到 `/usr/local/bin/unity`；**不含 Editor / 登录 / 许可证** |
| `85-godot.sh` | Godot Engine 4.7.2 | 官方 Linux x86_64 标准编辑器 zip → `/opt/godot/4.7.2/` + `/usr/local/bin/godot`；**不含 export templates** |
| `99-cleanup.sh` | 收尾 | 恢复 `resolv.conf`、删 `policy-rc.d`、清 apt 缓存、写清单 |

### NVIDIA 驱动（默认每台机器都装）

`software/24-nvidia-driver.sh` 不做硬件检测，每台机器都装（没有 N 卡的机器只是多了用户态库和一个不会被加载的模块）。不装网卡驱动。

| 包 | 说明 |
|---|---|
| `nvidia-driver-595-open` | 用户态驱动（restricted）。分支号可改：`--nvidia-driver-version N`（环境变量 `PIN_NVIDIA_DRIVER`） |
| `linux-modules-nvidia-595-open-<flavour>` | Canonical 编译并签名的内核模块 meta。它 `Provides: nvidia-dkms-595-open`，所以 apt 不会装 dkms、不会现场编译 |
| `linux-<flavour>` | 与模块 meta **同版本**的内核 meta（例：`linux-generic-hwe-24.04` 7.0.0-42 ↔ `linux-modules-nvidia-595-open-generic-hwe-24.04` 7.0.0-42 → 内核 `7.0.0-42-generic`）。装完下次开机进这个内核 |
| `nvidia-settings`、`nvidia-prime` | 仅 Desktop（设置面板、混合显卡 `prime-select`） |
| `intel-media-va-driver-non-free`、`vainfo` | Intel 核显 VA-API 硬解/硬编（前者仅 amd64；multiverse） |

- **flavour**：按目标机已装的内核 meta 判断（`linux-generic-hwe-24.04` → `generic-hwe-24.04`，`linux-generic` → `generic`，`linux-oem-24.04` → `oem-24.04`），`--nvidia-kernel-flavour F` 可指定。Desktop 24.04 默认是 HWE，Server 默认是 GA。
- **版本必须一致**：模块 meta 的版本要能找到同版本的 `linux-<flavour>` / `linux-image-<flavour>` / `linux-headers-<flavour>`。内核 meta 候选比模块新（模块还没跟上）时，锁到模块那一版一起装。找不到同版本内核、已装内核比模块还新（会降级）、该 flavour 没有预编译模块、或者 apt 模拟时会拉进 DKMS，都只打一行 `nvidia-driver: SKIP: …` 并以 0 退出，不装驱动，装机照常完成。看 `/var/log/autoinstall/24-nvidia-driver.log`。
- **Secure Boot**：不登记 MOK，只提示。预编译模块由 Canonical 签名，Ubuntu shim 信任，开不开 Secure Boot 都能加载。
- **Wayland**：驱动包不改 `/etc/gdm3/custom.conf`。gdm 的 `61-gdm.rules` 遇到 NVIDIA 只会写 `WaylandEnable false` 或 `PreferredDisplayServer`，不会打开 Wayland，所以 Desktop 默认的 `WaylandEnable=false`（`36` 钩子写入）保持不变。钩子再兜底检查一次：若某版 gdm 规则会写 `WaylandEnable true`，就在 `/etc/udev/rules.d/61-gdm.rules` 放一份去掉那一行的同名规则。
- **装完验证**：重启后 `nvidia-smi`、`vainfo`；`docker run --rm --gpus all ubuntu nvidia-smi`（Container Toolkit 由 `25` 装）。
- **全离线**：捆绑里带驱动、预编译模块、同版本内核（默认 HWE + GA 两套 flavour）及依赖闭包；`validate-offline-bundle.sh` 检查每个 flavour 的模块 meta、内核 meta、内核 ABI 版本一致。`linux-firmware`（约 600 MB）不进捆绑，用目标机已装的那份。

### Microsoft Edge（仅 Desktop）

默认只在 Desktop 预装（`--skip 35` / `--skip 35-microsoft-edge` 可跳过；Server 与非 amd64 自动跳过）。装的是官方 `microsoft-edge-stable`，**不卸载 Firefox**。装机时会：

- 把 Edge 设为 `x-www-browser` / `gnome-www-browser`，并写入 `/etc/xdg/mimeapps.list`、`/usr/share/applications/{mimeapps,defaults}.list`、`/etc/skel/.config/mimeapps.list` 以及装机用户的 `~/.config/mimeapps.list`（`text/html`、`http`/`https`/`about`/`unknown`）。无图形会话时 `xdg-settings` 可能写不上，mimeapps 仍生效。
- 若存在 GNOME schemas，用 Edge 替换收藏夹里的 Firefox（`90_autoinstall-microsoft-edge.gschema.override`）。
- 写入 `/etc/opt/edge/policies/managed/10-autoinstall.json`：`HideFirstRunExperience=true`、`DefaultBrowserSettingEnabled=false`，避免首次运行弹窗；**不**关闭自动更新。
- 全离线时从捆绑安装，装完由 `restore-online-apt.sh` 写回 Microsoft apt 源，联网后可更新。

### FlClash（仅 Desktop）

默认只在 Desktop 预装 [FlClash](https://github.com/chen08209/FlClash)（GPL-3.0，ClashMeta 图形客户端）。Server 与非 amd64/arm64 自动跳过。装的是官方 GitHub Release 的 `FlClash-<版>-linux-<架构>.deb`，用同一发布里的 `SHA256SUMS` 校验（没有 sums 时记录并校验下载文件的 sha256）。**始终跟随最新稳定版**（GitHub `releases/latest`，不含预发布）。

**只装应用，不做任何代理配置**：不写入订阅/配置文件、不设系统代理、不启用 TUN、不安装或启用 `flclash-helper.service`（应用在用户需要时会自己写）。装完从应用菜单打开，由用户自行添加配置。

跳过：`--no-flclash`，或 `--skip 37` / `--skip 37-flclash`。卸装：

```bash
sudo apt remove FlClash
```

若曾在应用内开启系统代理或 TUN，请先在应用里关掉再卸载。全离线时 deb 与 apt 依赖（`libayatana-appindicator3-1`、`libsecret-1-0` 及其闭包）都在捆绑里，装机不访问 GitHub。

### Grok Bot 桌面版（仅 Desktop）

Desktop 默认预装 Grok Bot 桌面版（官方 linux `.deb`，`grok-bot` 包，装到 `/opt/Grok Bot`，命令 `/usr/bin/grok-bot`）。Server 与非 amd64/arm64 自动跳过。

- **版本**：默认 `latest` = 发布 feed `https://api2.cursor.sh/updates/api/download/stable/linux-x64/sand`（arm64 是 `linux-arm64`）给出的当前版本和 `debUrl`（`downloads.cursor.com`）。写这段时是 `0.79.4`。
- **校验**：deb 的 sha256 依次取 `--grok-bot-sha256` → `tools/grok-bot-release.sh` 里内置的已知版本值（目前 0.79.4 amd64/arm64）→ 官方签名 apt 索引（`gpgv` 用仓库里的 `tools/grok-bot-archive-key.asc` 校验 `InRelease`，再查 `Packages`）。还会核对 deb 的包名、版本、架构。拿不到可信 sha256 就不装。
- **钉扎**：`--grok-bot-version X.Y.Z`（必须是内置已知版本或 feed 当前版本；官方 feed / apt 仓库只保留最新版），或 `--grok-bot-url URL --grok-bot-sha256 SHA`（完全钉扎，可指向自建镜像）。
- **安装**：`apt-get install --no-install-recommends ./grok-bot_*.deb`，依赖（GTK3、NSS、libsecret 等）由 apt 解析；deb 的 Recommends（`libappindicator3-1`，托盘图标；noble / jammy 源里都有）一起装，其它包仍不装 Recommends。若已有包 Provides 它（Desktop 上 FlClash 依赖的 `libayatana-appindicator3-1` Provides 且 Conflicts/Replaces 这个真包），则不再另装真包，避免 apt 冲突。Recommends 装不上时退回只装 deb（告警，不 SKIP）。官方 postinst 会装 AppArmor profile（24.04 限制非特权 user namespace，Electron 沙箱需要它）；chroot 里检测不到 AppArmor 时由钩子补放 `/etc/apparmor.d/grok-bot`。
- **只装应用**：不登录、不写账号或配置、不设开机自启。装完从应用菜单打开 Grok Bot，由用户自己登录。
- **失败不致命**：下载、校验或安装失败都只打印 `SKIP: Grok Bot 未安装: …`，原因写进 `/var/log/autoinstall/grok-bot.skip`，`99-cleanup` 汇总里显示 `grok-bot (skipped: …)`；装机继续。
- **apt 源与更新**：官方 postinst 写 `/etc/apt/sources.list.d/grok-bot.sources`（`https://downloads.cursor.com/aptrepo`，`Signed-By: /usr/share/keyrings/grok-bot.gpg`），这里**保留**它，装完 `sudo apt update && sudo apt upgrade` 即可更新 Grok Bot。离线装机时钩子先把它挪进 `enable-offline-apt.sh` 的 `sources.list.d.offline-bak/`，装机过程中的 `apt-get update` 不会去连外网；`restore-online-apt.sh` 收尾时原样挪回。清华源改写只动 Ubuntu 源，不碰它。装完仍无网时 `apt-get update` 对它只告警，不报错。
- **跳过 / 卸载**：`--no-grok-bot`，或 `--skip 39` / `--skip 39-grok-bot`。卸载：`sudo apt remove grok-bot`（postrm 会删掉 apt 源和 key）。

> **国内网络**：`api2.cursor.sh` 和 `downloads.cursor.com` 在国内可能很慢或被拦截（deb 约 110 MB），在线装机时容易拖慢甚至 SKIP。建议用全离线捆绑（`--fetch-offline`）：deb 和依赖都在构建机上预先下载并校验，装机时不连这两个域名。也可以用 `--grok-bot-url` + `--grok-bot-sha256` 指向内网镜像。

### 远程桌面：关闭 Wayland + RustDesk（Desktop 默认开启）

Desktop **默认**关闭 Wayland 并预装 [RustDesk](https://github.com/rustdesk/rustdesk)，开机就能在局域网里按 IP 直连，不用加任何参数；Server 不受影响（不装远程桌面，不改 GDM）。关 Wayland 由 `software/36-x11vnc-xorg.sh` 落地，RustDesk 由 `software/38-rustdesk.sh` 落地，所以 Desktop 默认路径不能和 `--no-provision` 同用（加了 `--wayland` 就可以，此时不装远程桌面）。

和 x11vnc 比，RustDesk 用视频编码（VP9 / AV1，有硬编时 H.264 / H.265）传画面，拖窗口、滚网页明显更流畅，还有剪贴板、文件传输和声音。x11vnc 留作可选。

| 默认 / 参数 | 效果 |
|---|---|
| （默认，Desktop） | 往 `/etc/gdm3/custom.conf` 的 `[daemon]` 写 `WaylandEnable=false`（幂等，其它键保留），GDM 登录界面、锁屏和用户会话全部走 Xorg；预装 RustDesk（离线从捆绑装），开机即可连，不用先登录；关掉合盖/空闲挂起 |
| `--remote-desktop M` | `rustdesk`（默认）/ `x11vnc`（VNC，5900，不加密）/ `none`（不装远程桌面，仍关 Wayland）。Server 上告警并忽略 |
| `--rustdesk-password P` | RustDesk 固定密码（≥6 位）。默认 = `--password` 明文（都没给就是默认密码 `ubuntu1990`，构建时告警）；只给了 `--password-hash` 时装机生成随机密码写入 `/root/rustdesk-password`（root 0600） |
| `--rustdesk-server H` | 自建 RustDesk 服务器（hbbs/hbbr）主机，可带端口，写入 `custom-rendezvous-server` 和 `relay-server`，可经自建服务器按 ID 连。默认不设 |
| `--rustdesk-allow-id` | 恢复 RustDesk 公共 ID 服务器（可跨网络按 ID 连）。**默认关闭：只支持局域网 `<机器IP>:21118` 直连**，ID / 中继 / API 服务器都指向 `127.0.0.1`，不向公共服务器注册，外网无法按 ID 连入 |
| `--pin-rustdesk VER` | RustDesk 版本，默认 `1.5.1`（真机验证过）。非默认版本用 GitHub Release API 给的官方 sha256 校验 |
| `--wayland` | 保留 Wayland，不改合盖/空闲挂起。RustDesk 照装但告警：Wayland 下**连不了登录界面**，会话里每次连接都要在本机点同意共享屏幕。不能和 `--remote-desktop x11vnc` 同用 |
| `--vnc-password P` | 只用于 `--remote-desktop x11vnc`：VNC 密码（≥6 位）。默认 = `--password` 明文；只给了 `--password-hash` 时装机生成随机密码写入 `/root/x11vnc-password`。其它情况告警并忽略 |
| `--skip 36` / `--skip 38` | 跳过关 Wayland / 跳过 RustDesk |

旧参数 `--disable-wayland` 和 `--x11vnc` **已移除**，再传会直接报错并提示改用 `--wayland` / `--remote-desktop x11vnc`。

```bash
# Desktop 默认: 关 Wayland + RustDesk, 单独指定 RustDesk 密码
./build-iso.sh --iso ubuntu-24.04.5.1-desktop-amd64.iso --out out/desk.iso \
  --password 'Ch@ngeMe' --rustdesk-password 'Rd#2026x'
# 改用 x11vnc
./build-iso.sh --iso ubuntu-24.04.5.1-desktop-amd64.iso --out out/desk-vnc.iso \
  --password 'Ch@ngeMe' --remote-desktop x11vnc --vnc-password 'Vnc#2026'
# 保留 Wayland, 不装远程桌面
./build-iso.sh --iso ubuntu-24.04.5.1-desktop-amd64.iso --out out/desk-wl.iso \
  --password 'Ch@ngeMe' --wayland --remote-desktop none
```

全离线时，Desktop 默认要求捆绑里有 `rustdesk/`（钉扎版本的 deb + sha256），并且 `rustdesk` 包和它的 apt 依赖（`libxdo3`、`gstreamer1.0-pipewire` 等）都在本地 apt 池里（构建时校验）。加入 RustDesk 后 fingerprint 变了，老捆绑要用 `--fetch-offline --force-fetch` 重建（apt deb 会从缓存复用）。`--remote-desktop x11vnc` 时要求捆绑里有 `x11vnc` + `xauth`。

#### RustDesk（默认）

**怎么连**：**默认只支持局域网 IP 直连**。在另一台电脑上装 RustDesk 客户端，ID 输入框里填 `<机器IP>:21118`（**带上端口**），点连接，输固定密码。登录界面、锁屏、会话都能连（RustDesk 自己跟随 GDM 的 Xorg）。

默认**不能按 ID 连**：`custom-rendezvous-server` / `relay-server` / `api-server` 都指向本机 `127.0.0.1`（本机没有 hbbs/hbbr，连接立即被拒），机器不会注册到 RustDesk 公共服务器（`rs-ny.rustdesk.com`），外网拿到 ID 也连不进来。要跨网络按 ID 连：构建时加 `--rustdesk-allow-id`（公共服务器）或 `--rustdesk-server H`（自建服务器）。装机脚本不记录 RustDesk ID；需要时用 `sudo rustdesk --get-id` 查看。

依据（RustDesk 1.5.1 源码）：`Config::get_rendezvous_servers()` 在 `custom-rendezvous-server` 非空时只返回它，否则才用内置的 `rs-ny.rustdesk.com`（`libs/hbb_common/src/config.rs`）；中继地址由 rendezvous 服务器下发或取 `relay-server`；API 地址取 `api-server`，空时由 `custom-rendezvous-server` 推出（`src/common.rs` `get_api_server`）；直连监听 `direct_server()` 只看 `direct-server` / `direct-access-port`，与 rendezvous 无关（`src/rendezvous_mediator.rs`）。`stop-service=Y` 会连直连监听一起关掉，不能用。官方没有「只允许直连」的开关。

**装机时做了什么**

- 从官方 GitHub Release 装 `rustdesk-<版>-x86_64.deb`（arm64 是 `aarch64`），sha256 与写死在 `tools/rustdesk-release.sh` 里的官方值比对；启用官方的 `rustdesk.service`（root 运行 `rustdesk --service`）。拉 GitHub 慢的话可以设 `RUSTDESK_DL_BASE` 指向同结构的镜像（sha256 仍按官方值校验），或者用全离线捆绑。
- RustDesk 1.5 的固定密码是加盐哈希存储的，只能通过运行中的服务设置，chroot 里做不到。所以装机时只把明文放进 `/etc/aib/rustdesk.secret`（root 0600），选项写进 `/etc/aib/rustdesk.options`，并预置 `/root/.config/rustdesk/RustDesk2.toml` 的 `[options]`；**首次开机**由一次性服务 `aib-rustdesk-setup.service`（`After=rustdesk.service`）调用 RustDesk 自己的 CLI：
  - `rustdesk --option direct-server Y` + `direct-access-port 21118`：局域网 IP 直连；
  - `rustdesk --option verification-method use-permanent-password`：只认固定密码（不用临时密码）；
  - `rustdesk --option approve-mode password`：不弹「接受连接」确认框，无人值守也能连；
  - 默认 `custom-rendezvous-server 127.0.0.1` / `relay-server 127.0.0.1` / `api-server http://127.0.0.1`（只允许局域网直连，见上）；给了 `--rustdesk-server` 时这两项改成自建服务器；`--rustdesk-allow-id` 时不写（用公共服务器）；
  - `rustdesk --password …`：设固定密码。

  设置之前先等 RustDesk 就绪（最多 180 秒）：`rustdesk.service` active、有 `rustdesk --service` 进程、配置目录 `/root/.config/rustdesk` 存在、主 IPC socket `/tmp/RustDesk-0/ipc` 已建立。服务没起来时调 CLI 会出现「设置固定密码失败: No such file or directory」这类假失败，`--get-id` 也会读到本地临时 ID，所以这里不调用 `--get-id`。每个选项都读回确认；密码最多试 5 次，返回 `Done!` 后删除明文，写 `/var/lib/aib/rustdesk-setup.done`，以后不再运行；还失败就 30 秒后由 systemd 重试。日志里不记录 ID 和明文密码。
- 明文密码不进 `provision.env` 和日志；构建时只放进 ISO 里的 `/provision/rustdesk.secret`（0600）。设置那一刻密码会出现在 `rustdesk --password` 的命令行参数里（RustDesk CLI 只支持这种方式），首次开机那一瞬间本机其它进程理论上能用 `ps` 看到。
- 防火墙：只在 ufw **已启用**时放行 `21118/tcp`（装机时和首次开机各检查一次），不会主动打开 ufw。

**安全提醒**

- 21118 直连端口在局域网内谁都能连，只靠固定密码保护；不要映射到公网。外网请走 VPN 或自建服务器（`--rustdesk-server`）。
- 默认模式下 RustDesk 仍会做 IPv6 STUN 探测（DNS 查询 `stun.l.google.com` 等，只为获知本机公网 IPv6，不注册 ID、不开放入站）；这是 RustDesk 内置行为，没有配置项能关。
- 默认密码是公开的，装完立即改：`sudo rustdesk --password '<新密码>'`。
- 排查：`systemctl status rustdesk aib-rustdesk-setup`、`journalctl -u aib-rustdesk-setup`、`sudo rustdesk --option direct-server`（应输出 `Y`）、`sudo rustdesk --option custom-rendezvous-server`（默认应输出 `127.0.0.1`）。

#### x11vnc（`--remote-desktop x11vnc`）

构建时会醒目告警：VNC 流量不加密、局域网内可直接连 5900 端口；若 VNC 密码回落到公开的默认值 `ubuntu1990`，装完务必修改。

- systemd 服务 `x11vnc.service`（`After=display-manager.service`，`Restart=always`，开机自启）运行 `/usr/local/sbin/aib-x11vnc-follow`。
- 关掉 Wayland 以后，GDM 登录界面是一个 Xorg（`:0`，vt1），登录后用户会话是另一个 Xorg（`:1`，vt2），GNOME 锁屏就在用户会话的 X 里。所以 x11vnc 不能钉死在 `:0`：启动器每 2 秒看一次**当前活动 VT**（`/sys/class/tty/tty0/active`）上的 Xorg，从它的命令行取 `-auth` 和显示号；变了就重启 x11vnc。
- 24.04 的 Xorg 是 rootless 的（登录界面属 `gdm`，会话属登录用户），root 跑的 x11vnc 挂不上它的共享内存（MIT-SHM）。所以启动器用 `setpriv` 以 **auth 文件属主**的身份跑 x11vnc（`-display :N -auth … -rfbauth /run/aib-x11vnc/pass-<用户> -rfbport 5900 -forever -shared -repeat -xkb`），密码文件给每个用户复制一份（0400），日志在 `/run/aib-x11vnc/x11vnc-<用户>.log`。不再加 `-noshm` / `-nowf` / `-noxdamage`，画面更新快很多。
- 效果：开机停在登录界面能连上并远程输密码登录；登录后自动跟到会话（客户端断开重连一下即可）；锁屏时连上看到的就是锁屏，远程输密码解锁；注销后回到登录界面也能连。
- 密码：构建时明文只放进 ISO 里 `/provision/x11vnc.secret`（0600），装机时用 `x11vnc -storepasswd` 写成 `/etc/x11vnc.pass`（root 0600）后删除，不进 `provision.env` 和日志。VNC 协议**只校验前 8 个字符**。
- 防火墙：只在 ufw **已启用**时放行 `5900/tcp`（装机时和服务启动时各检查一次），不会主动打开 ufw。
- 怎么连：macOS 用 Finder「前往 → 连接服务器」输入 `vnc://<机器IP>:5900`（自带屏幕共享，偏慢），推荐 [TigerVNC](https://tigervnc.org/) 或 RealVNC Viewer；Windows 用 TigerVNC / RealVNC Viewer / TightVNC，地址 `<机器IP>:5900`。x11vnc 没有视频编码，拖窗口、看视频不会很流畅。
- 安全：VNC 流量**不加密**，只在可信局域网用；外网走 VPN 或 SSH 隧道 `ssh -L 5900:localhost:5900 <用户>@<机器IP>`。默认密码装完立即改：`sudo x11vnc -storepasswd /etc/x11vnc.pass && sudo systemctl restart x11vnc`。排查：`systemctl status x11vnc`、`journalctl -u x11vnc`、`/run/aib-x11vnc/x11vnc-*.log`。

#### 合盖 / 空闲不挂起（RustDesk 和 x11vnc 都有）

为了「随时能连」：logind drop-in `/etc/systemd/logind.conf.d/90-autoinstall-x11vnc.conf` 设 `HandleLidSwitch=ignore`（合盖不挂起）；GDM 登录界面（`/etc/dconf/db/gdm.d/`）和用户默认值（gschema override）都关掉空闲自动挂起。**锁屏和熄屏保持不变**（一连上屏幕就会亮）。文件名沿用原来的 x11vnc 命名。`--remote-desktop none` 或 `--wayland` 时不改。

**以后想换回 Wayland**

```bash
sudo systemctl disable --now x11vnc            # 用了 x11vnc 的话: 它只能接 Xorg, 先停掉
sudo sed -i 's/^WaylandEnable=false/WaylandEnable=true/' /etc/gdm3/custom.conf   # 或直接删掉这一行
sudo systemctl restart gdm3                     # 会注销当前图形会话
```

RustDesk 在 Wayland 下连不了登录界面，会话里每次都要手动同意共享屏幕。合盖/空闲不挂起的设置不会自动撤销；需要的话删掉 `/etc/systemd/logind.conf.d/90-autoinstall-x11vnc.conf`、`/etc/dconf/db/gdm.d/90-autoinstall-no-suspend`（再 `sudo dconf update`）和 `/usr/share/glib-2.0/schemas/90_autoinstall-x11vnc-no-suspend.gschema.override`（再 `sudo glib-compile-schemas /usr/share/glib-2.0/schemas`）。

**限制**：关 Wayland 后多屏分别缩放、触控板手势会差一点；NVIDIA 显卡在 Xorg 下通常更稳。x11vnc 接的是本地屏幕（同一个会话），没有声音转发。

### 两个版本约束，别忽略

- **Node 必须是 24**。Grok 要 ≥20、opencode 要 ≥18、OpenMausBot 要 **≥24**——最后这个决定了版本下限。Ubuntu 24.04 自带的 Node 18 不够用，所以 `40-nodejs.sh` 走 NodeSource 而不是 `apt install nodejs`。
- **Jenkins 要 Java 17/21**。装成 Java 11 会启动失败，脚本里做了 21→17 的探测回退。

### Jenkins：装完即可用（零配置）

默认预装（`--skip 30` 可跳过）。装机 chroot 里就会：

- **跳过安装向导**：systemd drop-in `/etc/systemd/system/jenkins.service.d/50-autoinstall.conf` 设置 `JAVA_OPTS=-Djava.awt.headless=true -Djenkins.install.runSetupWizard=false`，并写入 `jenkins.install.InstallUtil.lastExecVersion` / `jenkins.install.UpgradeWizard.state`（= 安装的 Jenkins 版本），不会出现 “Unlock Jenkins / initialAdminPassword”。
- **管理员**：默认用户名 = `--username`（默认 `ubuntu`），密码 = `--password` 明文（都不传时为默认密码 `ubuntu1990`）；可用 `--jenkins-admin-user` / `--jenkins-admin-password` 覆盖。装机时把密码转成 **bcrypt** 哈希，写进 `/var/lib/jenkins/init.groovy.d/00-autoinstall-admin.groovy`（jenkins 0600，只含 `#jbcrypt:$2a$...`，**不含明文**）；首次启动时该脚本创建用户（Jenkins 自带用户库，**禁止自助注册**），授权为“登录用户可做任何事、匿名不可读”，成功后**自删**。只给了 `--password-hash` 时生成随机密码写入 **`/root/jenkins-admin-password`**（root、0600）。构建时的明文单独放在 ISO 的 `/provision/jenkins-admin.secret`（0600，不进 `provision.env` / 日志），装机用完即删。
- **插件**（含全部必需依赖）：默认 `workflow-aggregator git gitea docker-workflow credentials-binding timestamper rebuild ansicolor docker-plugin parameterized-trigger`，可用 `--jenkins-plugins "a b c"`（可写 `name:version`）替换。默认列表：

  | 插件 ID | 用途 |
  |---|---|
  | `workflow-aggregator` | Pipeline（Jenkinsfile / 声明式与脚本式流水线） |
  | `git` | Git SCM |
  | `gitea` | Gitea 集成（组织扫描、Webhook、PR 构建） |
  | `docker-workflow` | Pipeline 中的 `docker.image(...).inside` 等 |
  | `docker-plugin` | Docker Cloud：按需起 Docker 容器作为构建节点 |
  | `credentials-binding` | `withCredentials` 绑定凭据 |
  | `timestamper` | 控制台日志时间戳 |
  | `ansicolor` | 控制台 ANSI 颜色 |
  | `rebuild` | 用相同参数重新构建 |
  | `parameterized-trigger` | 带参数触发下游任务 |

  解析用仓库自带的 `tools/resolve-jenkins-plugins.py`（纯 Python 3 标准库，不需要 Java）：取 `https://updates.jenkins.io/update-center.actual.json?version=<Jenkins 版本>`，递归解析非 optional 依赖，只选 `requiredCore` ≤ 目标版本的插件版本（固定版本或推荐版不兼容时查 `plugin-versions.json`），下载 `.hpi` 并用 update center 的 **sha256** 校验，写 `plugins.lock`（每行 `name:version:sha256`）。在线构建：装机时在 chroot 里按本机 Jenkins 版本跑它，下载到 `/var/lib/jenkins/plugins`；全离线构建：fetch 时按捆绑里**同一个** Jenkins 版本解析到 `jenkins-plugins/`，装机直接拷贝。lock 都会留在 `/var/lib/jenkins/plugins.lock`。
- 补装 `fontconfig` / `libharfbuzz0b`（headless JRE 不带，缺了 Jenkins 启动时 AWT 字体初始化失败）和 `python3-bcrypt`（算哈希用）。

- **Jenkins URL**：装机时写入 `/var/lib/jenkins/jenkins.model.JenkinsLocationConfiguration.xml` 的 `jenkinsUrl` = `http://<主机名>.local:8080/`（或 `--service-url-host` 指定的主机），等同于“系统管理 → 系统配置 → Jenkins URL”，首页不再提示未配置。不依赖 JCasC 插件。

开机后浏览器打开 `http://<主机名>.local:8080/`（或 `http://<本机IP>:8080/`），用上面的管理员登录即可。**装完请尽快改掉管理员密码**（右上角用户名 → Security）。

### Gitea：装完即可用

默认预装（`--skip 45` / `--skip 45-gitea` 可跳过）。装机 chroot 里就会：

- 写入 `/etc/gitea/app.ini`（`INSTALL_LOCK=true`，SQLite，每台机器独立生成 `SECRET_KEY` / `INTERNAL_TOKEN` / JWT），并 `gitea migrate`；
- 创建管理员（默认用户名 = `--username`（默认 `ubuntu`），密码 = `--password` 明文（都不传时为默认密码 `ubuntu1990`）；可用 `--gitea-admin-user` / `--gitea-admin-password` / `--gitea-admin-email` 覆盖）。只给了 `--password-hash`、没有明文时，会生成随机密码并写入 **`/root/gitea-admin-password`**（root、0600）。构建时的明文密码单独放在 ISO 的 `/provision/gitea-admin.secret`（0600，不进 `provision.env` / 构建日志），装机用完即删。管理员 `must-change-password=false`，**装完请尽快改掉密码**；
- `systemctl enable gitea.service`（官方单元，`After=network-online.target`）。防火墙规则不动。

开机后浏览器打开 `http://<主机名>.local:3000/`（或 `http://<本机IP>:3000/`）即可（`HTTP_ADDR=0.0.0.0`，局域网可访问）。**开放注册**（`DISABLE_REGISTRATION=false`），局域网里的人都能自助注册；若只想管理员拉人，把该值改成 `true` 后 `sudo systemctl restart gitea`。

网页上显示的克隆地址是 `http://<主机名>.local:3000/<用户>/<仓库>.git` / `git@<主机名>.local:<用户>/<仓库>.git`（`app.ini` 的 `ROOT_URL`、`DOMAIN`、`SSH_DOMAIN`，装机时按目标机的主机名写入）。要换成 IP 或域名，构建时用 `--service-url-host`，或装完按下一节手动改。

SSH 克隆使用系统 OpenSSH（端口 22、用户 `git`，Gitea 维护 `~git/.ssh/authorized_keys`）。不要用 `--username git`（与该系统用户冲突）；若你事后在 sshd 里加了 `AllowUsers`，请把 `git` 加进去。

### Gitea / Jenkins 的访问地址（`<主机名>.local`）

装机时 `45-gitea.sh` / `30-jenkins.sh` 读取目标系统的 `/etc/hostname`（= 构建时 `--hostname`，默认 `ubuntu-node`），把对外 URL 写成：

| 服务 | 默认 URL | 写到哪里 |
|---|---|---|
| Gitea | `http://<主机名>.local:3000/` | `/etc/gitea/app.ini` `[server]` 段 `ROOT_URL`、`DOMAIN`、`SSH_DOMAIN` |
| Jenkins | `http://<主机名>.local:8080/` | `/var/lib/jenkins/jenkins.model.JenkinsLocationConfiguration.xml` 的 `jenkinsUrl` |

- `.local` 靠 mDNS：`12-avahi-mdns.sh` 会装好并启用 Avahi（Desktop 自带；Server 补装 `avahi-daemon` + `libnss-mdns`）。macOS / iOS 原生支持；Windows 10 / 11 一般能直接解析；Linux 桌面装了 `libnss-mdns` 即可。
- 想用 IP 或域名：构建时加 `--service-url-host 192.168.1.20`（或 `ci.example.com`、`localhost`），URL 变为 `http://192.168.1.20:3000/` 与 `http://192.168.1.20:8080/`。不要带 `http://` 或端口。
- 服务仍监听 `0.0.0.0`，用 IP 照样能打开网页；URL 只影响页面上显示的克隆地址、Webhook / 构建链接、邮件里的链接。
- 构建时会校验 `--hostname`：只能是小写字母、数字和中间的连字符，1–63 位，不能含点或下划线，不能以连字符开头或结尾（如 `ubuntu-node`、`node01`、`desk-01`）。不合法直接报错，不会自动改写。

**限制（v1 不做自动同步）**：

- **同一网络里每台机器要用不同的 `--hostname`**。同一张 ISO 装多台时主机名会重复，Avahi 会自动把后来者改成 `xxx-2.local`，而写进配置的 URL 还是 `xxx.local`，就会指到别的机器。每台单独构建，或装完按下面的命令改。
- **装完再改主机名，URL 不会跟着变**。改主机名后手动同步：

  ```bash
  NEW=new-host   # 新主机名
  sudo hostnamectl set-hostname "$NEW"
  # Gitea
  sudo sed -i -E -e "s|^ROOT_URL *=.*|ROOT_URL = http://$NEW.local:3000/|" \
                 -e "s|^DOMAIN *=.*|DOMAIN = $NEW.local|" \
                 -e "s|^SSH_DOMAIN *=.*|SSH_DOMAIN = $NEW.local|" /etc/gitea/app.ini
  sudo systemctl restart gitea
  # Jenkins (也可在网页“系统管理 → 系统配置 → Jenkins URL”里改)
  sudo sed -i "s|<jenkinsUrl>[^<]*</jenkinsUrl>|<jenkinsUrl>http://$NEW.local:8080/</jenkinsUrl>|" \
    /var/lib/jenkins/jenkins.model.JenkinsLocationConfiguration.xml
  sudo systemctl restart jenkins
  sudo systemctl restart avahi-daemon
  ```

  换成 IP / 域名同理，把 `$NEW.local` 换成目标主机即可。
- **Android、Docker 容器（包括 Jenkins 的 Docker agent）、跨网段 / VPN 访问时通常解析不了 `.local`**。流水线里克隆仓库建议用 IP，或构建时用 `--service-url-host` 指定 IP / 内网域名。
- ufw 已启用时 `12-avahi-mdns.sh` 会放行 `5353/udp`；Gitea 3000 / Jenkins 8080 端口仍不自动放行。

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

- 目标盘预留 **≥ 25 GB**（Docker 镜像 + Jenkins workspace 很吃空间）；这套预装本身约占 1.2–1.5 GB（另加 Godot 解压约 140 MB、Gitea 二进制约 115 MB、FlClash deb 约 40 MB、RustDesk deb 约 25 MB、Grok Bot deb 约 110 MB（装后约 370 MB），数据目录随后增长）。
- OpenMausBot 是 Electron 应用，npm 包会拉下较大体积的运行时；服务器上只用 `openmausbot serve`，不需要 X11。
- 首次开机后要跑一次 `apt-get update`——`99-cleanup.sh` 为了缩体积清掉了 `/var/lib/apt/lists`。

### 增删软件

加：在 `software/` 放一个 `85-你的东西.sh`，按现有脚本的约定（`set -euo pipefail`、结尾自带校验命令、失败即非零退出）即可，无需改主脚本。

减：`--skip "30 70"` 跳过 Jenkins 和 OpenMausBot；`--skip "30-jenkins 70-openmausbot"` 等价。Desktop 上不装 FlClash 用 `--no-flclash`（或 `--skip 37`），不装 Grok Bot 用 `--no-grok-bot`（或 `--skip 39`）。整套不要就 `--no-provision`（Desktop 上要同时加 `--wayland`，因为默认的关 Wayland + RustDesk 由 `36` / `38` 钩子落地；此时不装远程桌面）。

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
- 构建器镜像的 apt 源**默认已是清华 https**（`https://mirrors.tuna.tsinghua.edu.cn/ubuntu`；arm64 用 `ubuntu-ports`）。缺 `ca-certificates` 时会先走同一源的 http 装好 CA，再切回 https。要换源：`APT_MIRROR=http://archive.ubuntu.com/ubuntu ./scripts/aib.sh --rebuild ...`（PowerShell：`$env:APT_MIRROR='...'`）；空值 `APT_MIRROR=` 保留 Docker 基础镜像自带的官方源。此项只影响构建器镜像，不影响装完机器的源。DNS/代理受限时可用 `AIB_BUILD_ARGS="--network=host"` 给自动 `docker build` 追加参数。

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
docker build --build-arg APT_MIRROR=http://archive.ubuntu.com/ubuntu -t autoinstall-iso-builder:local .   # 换回官方源
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
               --packages "vim,tmux,net-tools"

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

`software/*.sh` 在 Desktop 目标上大体不用改：Desktop minimal 不带 curl/git/openssh-server，`00-base`/`10-openssh` 会补装；已装的包（ca-certificates、gnupg、jq 等）照旧跳过。GitHub CLI / Docker / NVIDIA Container Toolkit / Jenkins / Node / Gitea / Grok / OpenCode / OpenMausBot / Unity CLI / Godot 与 Server 相同（Toolkit **不含** GPU 驱动；Unity CLI **不含** Editor；Godot **不含** export templates）。**例外**：`35-microsoft-edge.sh` 只在 Desktop + amd64 安装，并把 Edge 设为默认浏览器（Firefox 保留）；`37-flclash.sh` 只在 Desktop + amd64/arm64 安装 FlClash（不配置代理）；`39-grok-bot.sh` 只在 Desktop + amd64/arm64 安装 Grok Bot（不登录）；Server 自动跳过。

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

## 默认 apt 源（清华镜像）

抓离线包、构建 ISO，以及装完机器上的 Ubuntu apt（含 `-security` 口袋），**默认都走清华大学开源镜像**：

- amd64 / i386：`https://mirrors.tuna.tsinghua.edu.cn/ubuntu`
- 其他架构（`fetch-offline-bundle.sh --arch` 非 amd64/i386 时）：`https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports`

默认用 **https**。干净的 `ubuntu:24.04` 容器、以及安装器 chroot 在装好 `ca-certificates` 之前，直接走 https 会因 TLS 证书无法校验而失败。因此在这些新鲜环境里会先用同一清华源的 **http** 执行 `apt-get update` 并安装 `ca-certificates`，再把源切回 https 继续（`tools/ubuntu-mirror.sh`）。apt 包本身仍由 GPG 签名校验；http 只用于这一步引导。装完系统上的 Ubuntu 源是 https。若用户传入清华的 http 地址，也会升为 https；其它主机的 `--mirror` / `--ubuntu-mirror` / `APT_MIRROR` 原样保留，不会改 scheme。

清华同步了 `noble-security` / `jammy-security`，因此不再单独指向 `security.ubuntu.com`。官方源把 security 口袋放到独立主机，功能和内容与镜像站的 `$release-security` 相同。

覆盖方式：

| 场景 | 怎么换 |
|---|---|
| 装完机器的 apt 源 | `./build-iso.sh --mirror URL`（例如官方 `http://archive.ubuntu.com/ubuntu`，或内网源） |
| 抓离线包时的 Ubuntu 源 | `./tools/fetch-offline-bundle.sh --ubuntu-mirror URL`，或环境变量 `UBUNTU_MIRROR` |
| `build-iso.sh --fetch-offline` | 把上面的 `--mirror` 原样传给抓包，两处保持一致 |
| 构建器 Docker 镜像的 apt | `APT_MIRROR=URL`（arm64 另有 `APT_PORTS_MIRROR`）；`APT_MIRROR=` 空值保留基础镜像自带官方源 |

**装完系统的源是合理的**：在线安装时 Subiquity 按 `apt.primary` 写出 sources，之后一直用 `--mirror`（默认清华）。全离线安装过程不访问镜像，装完由 `restore-online-apt.sh` 恢复安装器写下的同一份 Ubuntu 源，并写回 Docker / Jenkins 等第三方源。境外使用或需要官方源时，构建时加上 `--mirror http://archive.ubuntu.com/ubuntu` 即可。当前 ISO 构建以 amd64 为主；自行给非 amd64 抓离线包时，未指定 `--ubuntu-mirror` 会自动改用 `ubuntu-ports`。

第三方源（Docker CE、Jenkins、NodeSource、GitHub CLI、NVIDIA toolkit、Microsoft Edge）以及 npm / Jenkins 插件 / Gitea 二进制 / FlClash GitHub Release / Grok Bot（`downloads.cursor.com`），不走 Ubuntu 镜像，也不受 `--mirror` 影响。

## 参数一览

| 参数 | 说明 |
|---|---|
| `--iso` / `--out` | 输入/输出路径，必填 |
| `--password-hash` | **推荐**。`openssl passwd -6 '密码'` 的结果 |
| `--password` | 明文，脚本自动哈希；会进 shell 历史，仅调试用 |
| `--hostname` | 默认 `ubuntu-node`。必须是单个主机名标签：小写字母 / 数字 / 中间的连字符，1–63 位，不能含点或下划线（不合法直接报错）。Gitea / Jenkins URL 默认用 `<hostname>.local`，**每台机器请用不同的名字** |
| `--service-url-host H` | 覆盖 Gitea / Jenkins URL 的主机部分（IPv4、FQDN 或 `localhost`），如 `--service-url-host 192.168.1.20` → `http://192.168.1.20:3000/` 与 `:8080/`。Gitea、Jenkins 都 `--skip` 时忽略 |
| `--username` | 默认 `ubuntu`（`git` 与 Gitea 系统用户冲突，会被拒绝） |
| （都不传密码） | `--password` / `--password-hash` 都没给时，使用**默认密码 `ubuntu1990`**（构建时告警），Gitea / Jenkins 管理员同样是 `ubuntu` / `ubuntu1990`。这是公开的默认值，**装完请立即改**：`passwd`，并在 Gitea / Jenkins 网页里改管理员密码 |
| `--packages` | 逗号分隔、**不要空格**（如 `vim,curl,htop`）；走 subiquity 的 apt（第三方包走 `software/`） |
| `--mirror` | 默认清华 `https://mirrors.tuna.tsinghua.edu.cn/ubuntu`（含 `-security`；缺 CA 时先 http 引导），写入 autoinstall `apt.primary`，**装完系统 apt 也用这个源**。内网源或官方源请显式覆盖，例如 `--mirror http://archive.ubuntu.com/ubuntu`。`build-iso.sh --fetch-offline` 会把同一 URL 传给抓包 |
| `--no-provision` | 不执行 `software/`，只做裸装机 |
| `--skip "30 70"` | 跳过脚本：编号前缀或完整名均可（`30` / `30-jenkins`） |
| `--strict` | 任一软件装失败就中止安装（默认记日志继续） |
| `--offline` | apt `fallback: offline-install`（`updates` 仍为 Subiquity 合法值 `security`；无 `none`） |
| `--force-fetch` | 配合 `--fetch-offline`：忽略捆绑 fingerprint，强制重建离线包 |
| `--offline-bundle DIR` | 使用已抓取的离线捆绑目录；构建前会 `validate-offline-bundle` |
| `--keep-offline-bundle` | 全离线装机后保留 `/opt/offline`（约 2-3 GB）。默认在 `software/` 和 `restore-online-apt.sh` 都跑完后删除 |
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
| `--no-flclash` | 不预装 FlClash（等价 `--skip 37` / `--skip 37-flclash`）。Desktop 默认预装最新稳定版（官方 GitHub Release + `SHA256SUMS`） |
| `--no-grok-bot` | 不预装 Grok Bot 桌面版（等价 `--skip 39` / `--skip 39-grok-bot`）。Desktop 默认预装 |
| `--grok-bot-version V` | Grok Bot 版本，默认 `latest`（发布 feed 当前版本）；`X.Y.Z` 须是内置已知版本或 feed 当前版本（环境变量 `PIN_GROK_BOT`） |
| `--grok-bot-url URL` | 完全钉扎 Grok Bot deb 的下载地址（可用内网镜像），必须同时给 `--grok-bot-sha256`（环境变量 `GROK_BOT_DEB_URL`） |
| `--grok-bot-sha256 SHA` | Grok Bot deb 的期望 sha256（环境变量 `GROK_BOT_SHA256`） |
| `--no-nvidia-driver` | 不装 NVIDIA 驱动（等价 `--skip 24` / `--skip 24-nvidia-driver`）。默认每台机器都装，不检测硬件 |
| `--nvidia-driver-version N` | NVIDIA 驱动分支，默认 `595`（`PIN_NVIDIA_DRIVER`） |
| `--nvidia-kernel-flavour F` | 内核 flavour（如 `generic-hwe-24.04` / `generic`），默认装机时按已装内核自动判断；全离线时也要求捆绑里有它 |
| `--gitea-admin-user U` | Gitea 管理员用户名，默认 = `--username` |
| `--gitea-admin-password P` | Gitea 管理员密码（至少 8 位），默认 = `--password` 明文；只给了 `--password-hash` 时装机写入 `/root/gitea-admin-password` |
| `--gitea-admin-email E` | Gitea 管理员邮箱，默认 `<用户名>@localhost` |
| `--jenkins-admin-user U` | Jenkins 管理员用户名，默认 = `--username` |
| `--jenkins-admin-password P` | Jenkins 管理员密码（≤72 字节），默认 = `--password` 明文；只给了 `--password-hash` 时装机写入 `/root/jenkins-admin-password` |
| `--jenkins-plugins "a b c"` | 预装 Jenkins 插件（空格分隔，可 `name:version`，自动带依赖），默认 `workflow-aggregator git gitea docker-workflow credentials-binding timestamper rebuild ansicolor docker-plugin parameterized-trigger`；全离线时需与捆绑一致（不一致会提示 `--force-fetch`） |
| `--edition` | `auto`（默认）/ `server` / `desktop`。`auto` 读 ISO 的 `casper/install-sources.yaml`（`variant: desktop/server`），退回 `.disk/info`；显式指定优先 |
| `--desktop-source` | 仅 desktop：`minimal`（默认，`ubuntu-desktop-minimal`）/ `standard`（`ubuntu-desktop`）/ 任意 source id；会对照 ISO 的 install-sources.yaml 校验 |
| `--realname` | `identity.realname`（登录界面显示名）；desktop 默认等于 `--username` |
| `--wayland` | 仅 desktop：保留 Wayland，不改合盖/空闲挂起；不能与 `--remote-desktop x11vnc` 同用，与 RustDesk 同用时告警。**不加时 Desktop 默认**关 Wayland。旧的 `--disable-wayland` / `--x11vnc` 已移除，传了会报错 |
| `--remote-desktop M` | 仅 desktop：`rustdesk`（默认，IP 直连 21118，固定密码）/ `x11vnc`（VNC 5900，不加密）/ `none` |
| `--rustdesk-password P` | RustDesk 固定密码（≥6 位），默认 = `--password` 明文；只有哈希时装机随机生成 → `/root/rustdesk-password` |
| `--rustdesk-server H` | 自建 RustDesk 服务器主机（可带端口），默认不设 |
| `--rustdesk-allow-id` | RustDesk 恢复公共 ID 服务器；默认只允许局域网 `<IP>:21118` 直连 |
| `--pin-rustdesk VER` | RustDesk 版本，默认 `1.5.1`（环境变量 `PIN_RUSTDESK`） |
| `--vnc-password P` | x11vnc 密码（≥6 位，VNC 只用前 8 位），仅 `--remote-desktop x11vnc`；默认 = `--password` 明文；只有哈希时装机随机生成 → `/root/x11vnc-password` |
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
- `--pin-grok` / `--pin-opencode` / `--pin-openmausbot` / `--pin-gitea` 给具体版本可避免 `latest` 漂移。默认仍为 `latest`。FlClash 始终跟随最新稳定版，不能钉扎。Grok Bot 用 `--grok-bot-version` 或 `--grok-bot-url` + `--grok-bot-sha256` 钉扎。
- `--pin-node 24` 只钉主版本；NodeSource、Docker、Jenkins 仍跟随其稳定仓库，尚未做完整 apt 版本锁。
- Jenkins apt 源自 2026-01 起需 `jenkins.io-2026.key`（2023 密钥已过期）；本仓库脚本已切换。若要求严格复现，应使用内网快照源并固定 `.deb` 版本。当前默认行为不变，不承诺 bit-for-bit 可复现。
- `apt.primary` 暂保留 legacy 格式以兼容 22.04 的旧版 Subiquity（且安装器刷新关闭）；24.04-only 项目可迁移到 `mirror-selection.primary`。默认 URI 是清华源，详见下方「默认 apt 源」。

### 快速校验与 CI

```bash
bash test/local-check.sh
```

覆盖 Python 语法、grub 转义/幂等/旧参数修复、user-data YAML、默认 interactive storage / `--auto-disk`、公钥、pool-before-provision 顺序与 skip 前缀、`qemu-smoke` 对交互选盘 ISO 的拒绝（迷你 ISO + `--guard-only`，无需真开机），以及 Desktop 24.04（基于真实 24.04.5.1 Desktop ISO 抽出的 grub.cfg / loopback.cfg / install-sources.yaml 夹具）的版本识别、菜单注入与渲染语义。`.github/workflows/ci.yml` 在 PR/push 上运行 ShellCheck、这些校验、包装脚本 dry-run，以及用 `test/make-fake-iso.sh` 拼的假 ISO（只有 grub.cfg / install-sources.yaml / .disk/info，几百 KB）端到端跑一遍 `build-iso.sh`（Server + Desktop）。同一个 workflow 的 `container-smoke` job（PR 与 main）经 `scripts/aib.sh` 自动本地构建镜像，在容器里再跑一遍假 ISO 端到端；包装脚本 dry-run 同时测 bash 与 PowerShell（ubuntu runner 自带 pwsh）。需要 docker + 外网的 `test/container-x11vnc-reuse.sh`（可加 `--mirror URL`）手动跑：用抓包脚本同一段容器逻辑抓 x11vnc 两次，第二次必须「复用全部、新下载 0」；再在无网络容器里只用这份离线池装 x11vnc、跑 `36-x11vnc-xorg.sh`，并用两个伪装成 Xorg 的 Xvfb 验证从登录界面 `:0` 切到会话 `:1`。镜像不推送到任何 registry。BIOS/UEFI/QEMU 与 Secure Boot 验证见下文，不在轻量 CI 下载真实 ISO。

### 全离线模式（`--offline` + `--offline-bundle`）

目标：装机过程**零外网请求**，装完仍有 Docker / Jenkins / Node 24 / Grok / OpenCode / OpenMausBot / Unity CLI / Godot / Gitea / FlClash / Grok Bot（Desktop）。

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
| `fetch-offline-bundle.sh` | 在 `ubuntu:24.04`/`22.04` 容器内解析完整 deb 依赖闭包（Ubuntu + Docker + NVIDIA Container Toolkit + Jenkins + NodeSource + Microsoft Edge + x11vnc + Avahi（`avahi-daemon` / `libnss-mdns`）+ FlClash / RustDesk / Grok Bot 的 apt 依赖 + NVIDIA 驱动 / 预编译模块 / 同版本内核 / Intel VA-API，见下），`dpkg-scanpackages` 生成本地 apt 源；同时把第三方 **keyring + `.list`/`.sources`** 存进 `apt-sources/`；宿主机 `npm` 打全局 prefix 树；另存 Node 官方 tarball、Unity CLI 二进制（`unity-cli/`，约 128 MB）、Godot 4.7.2 zip（`godot/`，约 75 MB）与 Gitea linux-amd64 二进制（`gitea/`，约 115 MB，官方 sha256 校验）与 FlClash linux `.deb`（`flclash/`，约 40 MB，官方 GitHub `SHA256SUMS` 校验）、RustDesk `.deb`（`rustdesk/`，约 25 MB，钉扎版本 + 官方 sha256）、Grok Bot `.deb`（`grok-bot/`，约 110 MB，sha256 来自签名 apt 索引 / 内置值 / `--grok-bot-sha256`，写进 `manifest.json`；Recommends `libappindicator3-1` 也进 apt 池；`--no-grok-bot` 或 Server 构建（`--edition server`）不抓）兜底；并在宿主机用 `tools/resolve-jenkins-plugins.py` 按捆绑里 Jenkins 的版本解析插件闭包到 `jenkins-plugins/`（默认 87 个、约 74 MB，含 `plugins.lock`） |
| ISO | 写入 `/offline/{apt,apt-sources,npm,node,unity-cli,godot,gitea,jenkins-plugins,manifest.json}` |
| 装机 late-commands | 拷到 `/opt/offline`，临时只启用 `deb [trusted=yes] file:/opt/offline/apt ./`，再跑 `software/`（`OFFLINE=1`） |
| `software/*.sh` | 离线时不 curl、不加远程源；npm CLI 从 `prefix.tar.gz` 解压；Unity CLI 从 `unity-cli/` 安装；Godot 从 `godot/` 安装；Gitea 从 `gitea/` 安装；FlClash 从 `flclash/`、RustDesk 从 `rustdesk/`、Grok Bot 从 `grok-bot/` 安装（依赖来自本地 apt 池）；Jenkins 插件从 `jenkins-plugins/` 拷贝 |
| `restore-online-apt.sh` | 卸掉离线 pin、恢复安装器写入的 Ubuntu 源（即 `--mirror`，默认清华 https，含 `-security`）后，把捆绑内 **全部** `apt-sources/` 种子写回（Docker CE / GitHub CLI / NVIDIA toolkit / Jenkins / NodeSource / Microsoft Edge；与在线脚本同一批 URL/密钥）。装机时可能仍无网，此处不做 `apt update`；联网后即可收安全更新。纯在线构建不会调用本脚本 |
| 删除 `/opt/offline` | `restore-online-apt.sh` 之后的 late-command 删掉整个 `/opt/offline`（约 2-3 GB），大小记在 `/var/log/autoinstall/offline-bundle-removed.txt`。装好的软件运行时都不读它：apt 本地源已被 `restore-online-apt.sh` 撤掉，npm 全局树解压到 `/usr/local`，Node 解压到 `/opt/node-v*`，Jenkins 插件拷进 `JENKINS_HOME`，Gitea / Unity CLI / Godot 二进制和 FlClash / RustDesk / Grok Bot 的 deb 都已安装到系统目录。要保留（比如想在本机重跑 `software/`）：`--keep-offline-bundle` |

体积与缓存：

- 捆绑按 `cache/offline-bundles/<release>-<arch>/` 存放；`manifest.json` 含 `fingerprint`（schema 3：release/arch/pins/seeds，含 `apt-sources`、Jenkins 插件列表与解析器指纹）。指纹一致才复用，否则或旧格式需 `--force` 重建。构建时 `validate-offline-bundle.sh` 会核对 apt 种子包、`apt-sources/` keyring+list，以及 `unity-cli/`、`godot/`、`gitea/`、`jenkins-plugins/`（lock 里每个插件都在且 sha256 与 lock 一致、请求列表与 `--jenkins-plugins` 一致）等目录；失败则提示 `--force` / `--force-fetch`。
- **Avahi（2026-11 加入）**：`avahi-daemon` / `libnss-mdns` 没有计入指纹（Desktop 自带，旧捆绑照样能用）。**Server** 全离线构建且预装 Gitea 或 Jenkins 时，`build-iso.sh` 会让 validate 检查这两个包；之前抓的捆绑里没有，会报缺包，加 `--force-fetch`（或 `fetch-offline-bundle.sh --force`）重抓一次即可。
- **避免重复下载**（`--force` 也一样）：抓包前先按「空缓存」解析出本次需要的全部 deb（文件名 + 大小 + Packages 索引里的哈希），从本地 deb 缓存 `cache/apt-archives/<release>-<arch>/` 和旧捆绑的 `apt/` 里把**文件名、大小、哈希都一致**的直接放进 apt 的 archives 目录（apt 跳过下载前还会按索引里的 SHA256/SHA512 再校验一次，不一致就重下），apt 只下载缺的；新下的 deb 回写缓存。日志会打印「复用 N，新下载 M」。Unity CLI / Gitea / Godot / FlClash / Jenkins 插件 / Node tarball 在版本不变且校验和一致时也直接用旧捆绑里的文件。缓存只增不删，`--prune-apt-cache` 清掉本次没用到的；`--apt-cache DIR` 换位置，`--no-apt-cache` 不用缓存。指纹只看捆绑内容和参数，跟缓存无关；产出和不用缓存时一样（同一批 deb）。
- **NVIDIA 驱动（2026-11 加入）**：捆绑多了 `nvidia/`（`driver` + `flavours`，每行 `<flavour> <模块/内核 meta 版本> <内核 ABI>`），apt 池里多了 `nvidia-driver-595-open`、`nvidia-settings`、`nvidia-prime`、预编译模块、同版本内核（默认 `generic-hwe-24.04` 和 `generic` 两套，`fetch-offline-bundle.sh --nvidia-kernel-flavours "…"` 可改）、`intel-media-va-driver-non-free`、`vainfo` 及依赖闭包，约 **+0.8–1.0 GB**。`linux-firmware*`（约 600 MB）故意不收（目标机已装；要收就设 `FETCH_KEEP_LINUX_FIRMWARE=1`）。指纹变了，旧捆绑需 `--force-fetch` 重建（deb 走缓存复用）。不要驱动：`fetch-offline-bundle.sh --no-nvidia-driver` 配合 `build-iso.sh --no-nvidia-driver`。
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

- GitHub CLI / Docker / NVIDIA Container Toolkit / Jenkins / NodeSource / Microsoft Edge 走各自第三方仓库 → 需要下载 `.deb` 后配 `--debs`
- Grok / OpenCode / OpenMausBot 是 **npm 全局包** → 需要预建 npm 缓存（`npm cache add`）或打成 tarball 后离线 `npm install -g ./xxx.tgz`
- Unity CLI 是 CDN 二进制（`public-cdn.cloud.unity3d.com`）→ 全离线捆绑的 `unity-cli/`；无捆绑时脚本会联网下载
- Godot 是官方 zip（GitHub releases / downloads.godotengine.org，固定 **4.7.2**）→ 全离线捆绑的 `godot/`；无捆绑时脚本会联网下载；**不含** export templates
- Gitea 是官方二进制（`dl.gitea.com`，默认 latest，可用 `--pin-gitea`）→ 全离线捆绑的 `gitea/`；无捆绑时脚本会联网下载并用官方 `.sha256` 校验
- FlClash 是官方 GitHub Release 的 linux `.deb`（始终跟随最新稳定版）→ 全离线捆绑的 `flclash/` 以及 apt 池里的依赖；无捆绑时脚本会联网下载并用官方 `SHA256SUMS` 校验。仓库没有为 GitHub 资产配置国内代理，抓包/在线安装需要能访问 `github.com`
- Grok Bot 是官方 linux `.deb` → 全离线捆绑的 `grok-bot/`（deb + `sha256` + `version`）以及 apt 池里的依赖（Desktop 的 GTK 依赖大多已在池里，额外只多几 MB；捆绑总体约 +110 MB）。`validate-offline-bundle.sh` 在 Desktop 构建时（`--require-grok-bot`）检查 deb 的 sha256 / 版本和每个直接依赖都在池里（Recommends 缺了只告警）。加入 Grok Bot 后 fingerprint 变了，老捆绑要 `--fetch-offline --force-fetch` 重建（apt deb 从缓存复用）。抓包机需要能访问 `api2.cursor.sh` 和 `downloads.cursor.com`（国内可能很慢，可用 `--grok-bot-url` 指向镜像）
- **只给 Server 用的捆绑默认不带 Grok Bot**：`build-iso.sh` 抓包时把当前 edition 传给 `fetch-offline-bundle.sh --edition`；`server` 默认不抓 Grok Bot（省约 110 MB），Desktop（以及不带 `--edition` 直接跑抓包脚本，默认 `all`）照旧抓，`--no-grok-bot` 照旧关掉。Server 和 Desktop 默认共用同一个捆绑目录：Desktop 抓的捆绑（多带 `grok-bot/`）Server 构建直接复用；反过来 Server 抓的捆绑给 Desktop 用时指纹不同，要 `--force-fetch` 补抓（apt deb 从缓存复用）。

真正要全离线，建议改为「内网镜像源 + 自建 npm registry（Verdaccio）」，比往 ISO 里塞依赖靠谱得多。

---

## 验收标准（别跳过）

1. `--dry-run` 的 YAML 能被 `yaml.safe_load` 解析（脚本已内置校验）。
2. `xorriso -indev out.iso -report_el_torito plain` 里 **BIOS 与 UEFI 两个引导项都在**。
3. 虚拟机 BIOS + UEFI 各装一次，`virt-cat` 读到的 `/var/log/autoinstall/manifest.txt` 里 git / gh / rg / docker / nvidia-ctk / node / grok / opencode / openmausbot / unity / godot / gitea 都有版本号。
4. `provision-failed.txt` 为空。
5. 重启后 `systemctl status docker jenkins ssh gitea` 都是 active；浏览器打开 `http://<主机名>.local:3000/`（或 `http://<IP>:3000/`）能进（开放注册），页面上的克隆地址是 `<主机名>.local`，用构建时的管理员账号即可登录；`http://<IP>:8080/` 直接是 Jenkins 登录页（无安装向导），同一账号登录后“插件管理 → 已安装”里 Pipeline / Git / Gitea 等全部启用。

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
| `jenkins.service` 起不来 | Java 版本不对，或缺字体库 | 看 `/var/log/autoinstall/30-jenkins.log` 与 `journalctl -u jenkins`；确认装的是 21 或 17；`AWTProblem` / `libharfbuzz` 报错时 `apt install fontconfig libharfbuzz0b` |
| 忘记 Jenkins 管理员密码 | 只给了 `--password-hash` 构建 | 看 `/root/jenkins-admin-password`（root 0600）；若用了 `--password`，密码与系统用户相同 |
| Jenkins 匿名访问返回 403 / 无注册入口 | 设计如此 | 匿名不可读、禁止自助注册；需要开放时在“系统管理 → 安全”里调整 |
| `npm install` 超时 / 404 | 公网 registry 不通 | 换 `registry.npmmirror.com`，或改走内网 Verdaccio |
| `docker` 命令要 sudo | 组权限未生效 | 重新登录（组变更需新会话） |
| `docker run --gpus` 失败 | 驱动没装上（`--no-nvidia-driver`，或 `24` 因版本不匹配跳过），或装完还没重启 | 看 `/var/log/autoinstall/24-nvidia-driver.log` 里的 `SKIP:` 原因；重启后 `nvidia-smi`。无 GPU 的 VM 只能验证 `nvidia-ctk --version` / daemon.json |
| `unity` 能跑但装不了 Editor / 未登录 | **镜像只预装 CLI** | 装机后 `unity auth login`，再 `unity install <ver>`；许可证另激活 |
| 浏览器打不开 Gitea | 服务未起或防火墙 | `systemctl status gitea`；确认本机防火墙未拦 3000 端口（脚本**不**改防火墙） |
| `<主机名>.local` 打不开 / 解析失败 | 客户端不支持 mDNS（Android、容器、跨网段），主机名重名被 Avahi 改成 `xxx-2.local`，或装完改过主机名 | 先用 `http://<IP>:3000/` 确认服务正常；`avahi-resolve -n <主机名>.local`、`systemctl status avahi-daemon`；重名或改名按「Gitea / Jenkins 的访问地址」里的命令同步 URL；需要稳定地址时构建用 `--service-url-host` |
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

- 口令是哈希，不是明文；哈希本身也别提交到公开仓库。若用 `--password` 构建，Gitea / Jenkins 管理员明文会短暂出现在 ISO 的 `/provision/gitea-admin.secret` / `jenkins-admin.secret`（0600），装机后从目标机删除；拿到 ISO 的人在安装前仍可能读到，请勿把此类 ISO 公开分发。
- 没有任何 API key / 私钥进镜像。SSH **公钥**可通过 `--ssh-authorized-keys` 注入，属于公开信息；私钥绝不注入。
- 目标机磁盘 ≥ 25 GB，且装机时能访问 cli.github.com / docker.com / nvidia.github.io / pkg.jenkins.io / deb.nodesource.com / packages.microsoft.com（Desktop 上的 Microsoft Edge） / npm registry / unity.com（install.sh）与 `public-cdn.cloud.unity3d.com`（Unity CLI 二进制）、`github.com/godotengine/godot` 或 `downloads.godotengine.org`（Godot 4.7.2），`github.com/chen08209/FlClash`（Desktop 上的 FlClash linux `.deb` 与 `SHA256SUMS`）、`github.com/rustdesk/rustdesk`（Desktop 上的 RustDesk `.deb`；非默认版本还要 `api.github.com` 查 sha256）、`api2.cursor.sh` 与 `downloads.cursor.com`（Desktop 上的 Grok Bot `.deb` 和它的签名 apt 源；国内可能慢或被拦截），以及 `dl.gitea.com`（Gitea 二进制与 sha256）与 `updates.jenkins.io` 及其下载镜像（Jenkins 插件）。全离线捆绑可免除这些外网依赖。

这条线一旦破，后面所有「镜像管理」都失去意义。
