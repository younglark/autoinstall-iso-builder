# 把 autoinstall 烧进 Ubuntu ISO

一条命令产出一块「插上就自己装完」的 U 盘，装完即带全套预装软件。

适用：Ubuntu Server **22.04 / 24.04**（24.04 Desktop 亦可，改 `--menu-regex`）。

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
| `00-base.sh` | 基础依赖 | `policy-rc.d` 拦住 chroot 里的服务启动；修 `resolv.conf`；apt 非交互 |
| `10-openssh.sh` | openssh-server | 幂等兜底，启用 `ssh.service` |
| `20-docker.sh` | Docker CE | 官方仓库（非 `docker.io`），含 compose v2 / buildx，**配了日志轮转** |
| `30-jenkins.sh` | Jenkins LTS | 优先 JDK 21（不够退 17），jenkins 用户加入 docker 组 |
| `40-nodejs.sh` | Node.js 24 | NodeSource 优先，官方 tarball 兜底 |
| `50-grok.sh` | xAI Grok Build | `@xai-official/grok`，**官方包**，不是社区的 `@vibe-kit/grok-cli` |
| `60-opencode.sh` | OpenCode | `opencode-ai` |
| `70-openmausbot.sh` | OpenMausBot | npm CLI + 一个**故意未启用**的 systemd 单元 |
| `99-cleanup.sh` | 收尾 | 恢复 `resolv.conf`、删 `policy-rc.d`、清 apt 缓存、写清单 |

### 两个版本约束，别忽略

- **Node 必须是 24**。Grok 要 ≥20、opencode 要 ≥18、OpenMausBot 要 **≥24**——最后这个决定了版本下限。Ubuntu 24.04 自带的 Node 18 不够用，所以 `40-nodejs.sh` 走 NodeSource 而不是 `apt install nodejs`。
- **Jenkins 要 Java 17/21**。装成 Java 11 会启动失败，脚本里做了 21→17 的探测回退。

### 密钥一律不进镜像

这三个 AI CLI 都需要凭据，但**镜像里一个都不放**：

| 工具 | 首次使用 |
|---|---|
| Grok | `export XAI_API_KEY=xai-...`（CI 里走环境变量） |
| OpenCode | `opencode auth login` |
| OpenMausBot | 填 `/etc/openmausbot/env`（0600），再 `systemctl enable --now openmausbot` |

理由很直接：镜像会被复制、被外传，烤进去的 key 等于公开。而且 OpenMausBot 本身还依赖「本机已登录的 claude / codex / grok CLI」，这层也必须在跑起来之后才配对。

### 容量与依赖提醒

- 目标盘预留 **≥ 25 GB**（Docker 镜像 + Jenkins workspace 很吃空间）；这套预装本身约占 1.2–1.5 GB。
- OpenMausBot 是 Electron 应用，npm 包会拉下较大体积的运行时；服务器上只用 `openmausbot serve`，不需要 X11。
- 首次开机后要跑一次 `apt-get update`——`99-cleanup.sh` 为了缩体积清掉了 `/var/lib/apt/lists`。

### 增删软件

加：在 `software/` 放一个 `80-你的东西.sh`，按现有脚本的约定（`set -euo pipefail`、结尾自带校验命令、失败即非零退出）即可，无需改主脚本。

减：`--skip "30 70"` 跳过 Jenkins 和 OpenMausBot；`--skip "30-jenkins 70-openmausbot"` 等价。整套不要就 `--no-provision`。

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

# 3. 先在虚拟机跑一遍（务必做，别直接上物理机）
bash test/qemu-smoke.sh out/ubuntu-24.04.1-ci-node.iso
bash test/qemu-smoke.sh out/ubuntu-24.04.1-ci-node.iso --uefi
```

> WSL2 里操作 `/mnt/c/...` 下的文件会慢 3–5 倍，建议把 ISO 放在 `~/` 下再跑。
>
> npm 在国内会很慢：先 `npm config set registry https://registry.npmmirror.com --location=global`，或在 `40-nodejs.sh` 后加一行。

---

## 注入后 ISO 里到底改了什么

改动全在 ISO 根目录，不碰任何引导二进制：

```
/nocloud/user-data        # subiquity autoinstall 配置
/nocloud/meta-data        # NoCloud 数据源的实例标识
/provision/*.sh           # 软件预装脚本 + provision.env
/boot/grub/grub.cfg       # linux 行追加 autoinstall ds=nocloud\;s=/cdrom/nocloud/
/boot/grub/loopback.cfg   # 同上（Ventoy / 多启动 U 盘走这个）
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
| `--packages` | 逗号分隔的发行版包名，走 subiquity 的 apt（第三方包走 `software/`） |
| `--mirror` | 内网源务必替换，否则每台机器都从公网拉 |
| `--no-provision` | 不执行 `software/`，只做裸装机 |
| `--skip "30 70"` | 跳过脚本：编号前缀或完整名均可（`30` / `30-jenkins`） |
| `--strict` | 任一软件装失败就中止安装（默认记日志继续） |
| `--offline` | apt `fallback: offline-install`（`updates` 仍为 Subiquity 合法值 `security`；无 `none`） |
| `--debs DIR` | 把目录下 `.deb` 打进 `/pool` 并离线安装 |
| `--storage-layout` | `direct`（默认）/ `lvm` / `zfs` |
| `--network` | `dhcp`（默认）/ `none`。默认写入 netplan match `en*`/`eth*` 的 DHCP（`optional: true`），并用 late-command 落盘 `/etc/netplan/50-autoinstall-dhcp.yaml`（mode 600）+ 禁用 cloud-init 网络改写，保证**离线无网卡装机**后首启插网也能 DHCP。`none` 则不写。静态 IP 后续再加。 |
| `--ssh-allow-pw` | 未注入公钥时**必须为 true**，否则装完登不进去；与 `10-openssh.sh` 保持一致 |
| `--ssh-authorized-keys FILE` | 公钥文件（每行一把，忽略空行/注释），写入 `ssh.authorized-keys`，并经 `/nocloud/write-authorized-keys.sh` late-command 再写入用户 `~/.ssh/authorized_keys`（防 Subiquity 漏写）；建议配合 `--ssh-allow-pw false` |
| `--iso-sha256 HEX` | 可选源 ISO SHA256；不匹配立即失败 |
| `--iso-sha256sums FILE` | 按 ISO basename 在 SHA256SUMS 文件中查找校验和；优先于 `--iso-sha256` |
| `--pin-node N` | Node 主版本（默认 24）；环境变量 `PIN_NODE_MAJOR` |
| `--pin-grok / --pin-opencode / --pin-openmausbot VER` | npm 包版本（默认 latest）；亦可用 `PIN_GROK` / `PIN_OPENCODE` / `PIN_OPENMAUSBOT` |
| `--menu-regex` | 要注入的菜单标题正则；Desktop 版用 `Try or Install Ubuntu` |


### 默认 DHCP 网络

默认 `--network dhcp`：

1. autoinstall `network:` 使用 netplan v2，对 `en*` / `eth*` 做 match，`dhcp4`/`dhcp6` + `optional: true`（无网线不拖慢开机）。
2. late-commands 额外写入 `/etc/netplan/50-autoinstall-dhcp.yaml`（`chmod 600`），并写 `cloud.cfg.d/99-disable-network-config.cfg` 关闭 cloud-init 网络覆盖；同时删除可能由 Subiquity 在**无 NIC 安装**时生成的空/按名 `00-installer-config.yaml`。

背景：未显式写 `network:` 时，Subiquity 会把安装时探测到的网卡写进目标系统；`-nic none` 全离线装机后首启就没有 DHCP。本默认修复该问题。

用 `--network none` 可恢复「不注入网络段」的旧行为。

### 完整性与版本复现

- 推荐先验证官方 `SHA256SUMS.gpg`（用 Ubuntu CD Image signing key），再传 `--iso-sha256sums SHA256SUMS`；脚本只验证 SHA256，不替代 GPG 签名验证。
- `--pin-grok 具体版本` / `--pin-opencode 具体版本` / `--pin-openmausbot 具体版本` 可避免 `latest` 漂移。默认仍为 `latest`，以保持原有行为。
- `--pin-node 24` 只钉主版本；NodeSource、Docker、Jenkins 仍跟随其稳定仓库，尚未做完整 apt 版本锁。
- Jenkins apt 源自 2026-01 起需 `jenkins.io-2026.key`（2023 密钥已过期）；本仓库脚本已切换。若要求严格复现，应使用内网快照源并固定 `.deb` 版本。当前默认行为不变，不承诺 bit-for-bit 可复现。
- `apt.primary` 暂保留 legacy 格式以兼容 22.04 的旧版 Subiquity（且安装器刷新关闭）；24.04-only 项目可迁移到 `mirror-selection.primary`。

### 快速校验与 CI

```bash
bash test/local-check.sh
```

覆盖 Python 语法、grub 转义/幂等/旧参数修复、user-data YAML、公钥、pool-before-provision 顺序与 skip 前缀。`.github/workflows/ci.yml` 在 PR/push 上运行 ShellCheck 与这些校验。完整 `build-iso.sh --dry-run` 仍需真实 ISO；BIOS/UEFI/QEMU 与 Secure Boot 验证见下文，不在轻量 CI 下载 ISO。

### 全离线模式（`--offline` + `--offline-bundle`）

目标：装机过程**零外网请求**，装完仍有 Docker / Jenkins / Node 24 / Grok / OpenCode / OpenMausBot。

```bash
# 1) 构建期联网抓取捆绑（按发行版缓存，可复用）
./tools/fetch-offline-bundle.sh --release noble --out cache/offline-bundles/noble-amd64 \
  --packages "vim,curl,htop,net-tools"

# jammy (22.04) 同理:
# ./tools/fetch-offline-bundle.sh --release jammy --out cache/offline-bundles/jammy-amd64

# 2) 烧进 ISO
./build-iso.sh --iso ubuntu-24.04.x-live-server-amd64.iso \
  --out out/ubuntu-24.04-offline.iso \
  --password-hash "$(openssl passwd -6 'Ch@ngeMe')" \
  --offline --offline-bundle cache/offline-bundles/noble-amd64 \
  --packages "vim,curl,htop,net-tools"

# 或一步：--fetch-offline 自动抓取后再打包
# ./build-iso.sh ... --offline --fetch-offline --packages "vim,curl"

# 3) 无网卡冒烟（需本机 qemu）
bash test/qemu-smoke.sh out/ubuntu-24.04-offline.iso --offline-nic
```

原理简述：

| 阶段 | 行为 |
|---|---|
| `fetch-offline-bundle.sh` | 在 `ubuntu:24.04`/`22.04` 容器内解析完整 deb 依赖闭包（Ubuntu + Docker + Jenkins + NodeSource），`dpkg-scanpackages` 生成本地 apt 源；宿主机 `npm` 打全局 prefix 树；另存 Node 官方 tarball 兜底 |
| ISO | 写入 `/offline/{apt,npm,node,manifest.json}` |
| 装机 late-commands | 拷到 `/opt/offline`，临时只启用 `deb [trusted=yes] file:/opt/offline/apt ./`，再跑 `software/`（`OFFLINE=1`） |
| `software/*.sh` | 离线时不 curl、不加远程源；npm CLI 从 `prefix.tar.gz` 解压 |

体积与缓存：

- 捆绑按 `cache/offline-bundles/<release>-<arch>/` 存放；有 `manifest.json` 时默认复用（`--force` 重建）。
- 实测（本仓库验证机，2026-11）：**noble+npm ≈ 648 MB**（150 debs + npm prefix ≈329 MB 压缩）；**jammy apt-only（--skip-npm）≈ 312 MB**（127 debs）。含 OpenMausBot 时 npm 树是大头；U 盘请预留 ≥ 镜像+捆绑余量。
- `--packages` 会并进捆绑；全离线时 autoinstall 的 `packages:` 置空，改由 `00-base.sh` 从本地 apt 安装，避免安装器阶段无索引。

兼容：`--debs DIR` 旧局部离线仍可用；与全离线捆绑互斥场景下优先 `--offline-bundle`。

### 离线限制（重要）

> 若使用上文「全离线模式」，可忽略本段。

**无捆绑**时的旧 `--offline` 只影响 autoinstall apt fallback；第三方脚本仍会联网。当前这套软件栈里：

- Docker / Jenkins / NodeSource 走各自第三方仓库 → 需要下载 `.deb` 后配 `--debs`
- Grok / OpenCode / OpenMausBot 是 **npm 全局包** → 需要预建 npm 缓存（`npm cache add`）或打成 tarball 后离线 `npm install -g ./xxx.tgz`

真正要全离线，建议改为「内网镜像源 + 自建 npm registry（Verdaccio）」，比往 ISO 里塞依赖靠谱得多。

---

## 验收标准（别跳过）

1. `--dry-run` 的 YAML 能被 `yaml.safe_load` 解析（脚本已内置校验）。
2. `xorriso -indev out.iso -report_el_torito plain` 里 **BIOS 与 UEFI 两个引导项都在**。
3. 虚拟机 BIOS + UEFI 各装一次，`virt-cat` 读到的 `/var/log/autoinstall/manifest.txt` 里 docker / node / grok / opencode / openmausbot 都有版本号。
4. `provision-failed.txt` 为空。
5. 重启后 `systemctl status docker jenkins ssh` 三个都是 active。

---

## 常见失败与定位

| 现象 | 原因 | 处理 |
|---|---|---|
| 卡在 `Subiquity` 欢迎页，配置没被读到 | grub 参数没进去，或路径写错 | `--dry-run` 看注入后的 `linux` 行；确认是 `/cdrom/nocloud/` 带尾斜杠 |
| 报 YAML 解析错 | 渲染后缩进被破坏 | 用 `--dry-run` 输出贴到 `python3 -c "import yaml;yaml.safe_load(open('u.yaml'))"` |
| `apt` 阶段长时间卡住 | 无网但没加 `--offline` | 加 `--offline`，或换内网 `--mirror` |
| 装完重启又装一遍 | U 盘仍在启动顺序首位 | 装机后拔盘，或在 BIOS 里把硬盘提到前面 |
| Ventoy 启动不生效 | 走的是 `loopback.cfg` | 确认输出里有 `loopback.cfg` 的 patch 日志；新版 Ventoy 需在菜单按 `F6` 用 grub2 模式 |
| 装完 SSH 登不进 | `allow-pw: false` 且无公钥 | `--ssh-allow-pw true` |
| 报 `no disk found` | 目标机是多盘/RAID | 改 `user-data.tmpl` 的 `storage.match`，别用 `size: largest` |
| `jenkins.service` 起不来 | Java 版本不对 | 看 `/var/log/autoinstall/30-jenkins.log`；确认装的是 21 或 17 |
| `npm install` 超时 / 404 | 公网 registry 不通 | 换 `registry.npmmirror.com`，或改走内网 Verdaccio |
| `docker` 命令要 sudo | 组权限未生效 | 重新登录（组变更需新会话） |
| `openmausbot` 打不开窗口 | 它是 Electron 应用 | 服务器上只能用 `openmausbot serve` |
| 装完没有服务自启 | `policy-rc.d` 没删掉 | 确认 `99-cleanup.sh` 跑过；检查 `/usr/sbin/policy-rc.d` 不存在 |

---

## 版本差异备忘

- **22.04 / 24.04**：`preseed` 已彻底废弃，只有 autoinstall；ISO 挂载点都是 `/cdrom`。
- **24.04**：仍是 casper + subiquity，`/boot/grub/grub.cfg` 与 `loopback.cfg` 结构不变，菜单文案为 `Try or Install Ubuntu Server`，默认正则能匹配。
- **22.04 注意**：`openjdk-21-jre-headless` 不一定有，脚本会自动退到 17，Jenkins 仍可用。
- **Desktop 版**：24.04+ 支持 autoinstall，菜单文案是 `Try or Install Ubuntu`，建议补 `identity.realname`。
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

- 口令是哈希，不是明文；哈希本身也别提交到公开仓库。
- 没有任何 API key / 私钥进镜像。SSH **公钥**可通过 `--ssh-authorized-keys` 注入，属于公开信息；私钥绝不注入。
- 目标机磁盘 ≥ 25 GB，且装机时能访问 docker.com / pkg.jenkins.io / deb.nodesource.com / npm registry。

这条线一旦破，后面所有「镜像管理」都失去意义。
