<#
.SYNOPSIS
  aib.ps1 — 在 Windows (PowerShell 5.1 / 7+) 上用容器运行 autoinstall-iso-builder。

.DESCRIPTION
  .\scripts\aib.ps1 [包装选项] <子命令> [子命令参数...]

  包装选项 (必须写在子命令之前):
    (默认)          用本地镜像 autoinstall-iso-builder:local (抓 22.04 捆绑用 :local-jammy);
                    不存在时自动用本仓库 Dockerfile docker build (首次约 3-10 分钟, 之后秒级)
    --rebuild       强制重新 docker build 本地镜像 (git pull 更新仓库后用; 仍复用未变的层缓存)
    --image REF     改用指定的完整镜像引用 (自建/内网仓库), 不再自动构建 (或环境变量 AIB_IMAGE)
    --local         兼容旧用法, 等同默认 (无操作)
    --platform P    覆盖 docker --platform (默认: 需要 apt 解析的步骤强制 linux/amd64)
    --docker-arg A  追加一个 docker run 参数, 可重复 (如 --docker-arg --network=host);
                    也可用环境变量 AIB_DOCKER_ARGS (按空白切分)
    (环境变量 AIB_BUILD_ARGS 追加到自动 docker build, 如 --network=host; APT_MIRROR 换 apt 源, Dockerfile 默认已是清华源)
    --dry-run       只打印将执行的 docker 命令, 不运行 (不需要 docker)
    -h, --help

  子命令: build | fetch-offline | validate-offline | check-iso | local-check | shell | help | version

  路径处理: 当前目录挂到容器 /work; --iso/--out/--offline-bundle 等路径参数若在当前目录外,
  自动把其父目录挂到 /mnt/aibN 并改写参数 (C:\Users\me\Downloads\x.iso -> /mnt/aib1/x.iso)。
  需要 Docker Desktop (Linux containers 模式, WSL2 后端)。

.EXAMPLE
  .\scripts\aib.ps1 build --iso C:\isos\ubuntu-24.04.3-live-server-amd64.iso --out out\node01.iso --hostname node01 --password-hash '$6$...'
#>
# 注意: 故意不用 param()——子命令参数形如 --iso, 交给 $args 原样转发。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

function Show-Usage {
  $text = Get-Content -LiteralPath $PSCommandPath -Raw -Encoding UTF8
  $m = [regex]::Match($text, '(?s)\.DESCRIPTION\r?\n(.*?)\r?\n\.EXAMPLE')
  if ($m.Success) { Write-Output $m.Groups[1].Value } else { Write-Output 'aib.ps1 [--rebuild] [--image R] [--platform P] [--docker-arg A] [--dry-run] <subcommand> [args...]' }
}
function Fail([string]$msg) { [Console]::Error.WriteLine("[aib] 错误: $msg"); exit 1 }
function Info([string]$msg) { [Console]::Error.WriteLine("[aib] $msg") }

$OnWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
$Image = if ($env:AIB_IMAGE) { $env:AIB_IMAGE } else { '' }   # 空 = 本地构建的镜像
$Platform = if ($env:AIB_PLATFORM) { $env:AIB_PLATFORM } else { '' }
$Rebuild = $false
$DryRun = $false
$ExtraDockerArgs = New-Object System.Collections.Generic.List[string]
if ($env:AIB_DOCKER_ARGS) { foreach ($x in ($env:AIB_DOCKER_ARGS -split '\s+')) { if ($x) { $ExtraDockerArgs.Add($x) } } }

$all = @($args | ForEach-Object { [string]$_ })
$i = 0
# 注意: 不用 switch——switch 里的 continue/break 作用于 switch 本身而非 while
while ($i -lt $all.Count) {
  $a = $all[$i]
  if ($a -ceq '--image' -or $a -ceq '--platform' -or $a -ceq '--docker-arg') {
    if ($i + 1 -ge $all.Count) { Fail "$a 需要参数" }
    $v = $all[$i + 1]
    if ($a -ceq '--image') { $Image = $v } elseif ($a -ceq '--platform') { $Platform = $v } else { $ExtraDockerArgs.Add($v) }
    $i += 2
  } elseif ($a -ceq '--local') { $i++ }
  elseif ($a -ceq '--rebuild') { $Rebuild = $true; $i++ }
  elseif ($a -ceq '--dry-run') { $DryRun = $true; $i++ }
  elseif (@('-h', '--help', '-?', '/?') -contains $a) { Show-Usage; exit 0 }
  elseif ($a -ceq '--') { $i++; break }
  elseif ($a.StartsWith('-')) { Fail "未知包装选项: $a (子命令参数请写在子命令之后)" }
  else { break }
}
if ($i -ge $all.Count) { Show-Usage; exit 1 }
$SubCmd = $all[$i]
$SubArgs = @()
if ($i + 1 -lt $all.Count) { $SubArgs = @($all[($i + 1)..($all.Count - 1)]) }

$sep = [System.IO.Path]::DirectorySeparatorChar
$cmp = if ($OnWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
$Cwd = (Get-Location).ProviderPath.TrimEnd('\', '/')
if ($Cwd -eq '') { $Cwd = [string]$sep }

$PathOpts = @('--iso', '--out', '--offline-bundle', '--ssh-authorized-keys', '--debs', '--iso-sha256sums', '--cache-root', '--bundle')
$OutOpts = @('--out', '--offline-bundle', '--cache-root')
$MountSrcs = New-Object System.Collections.Generic.List[string]
$MountDsts = New-Object System.Collections.Generic.List[string]

function Get-FullPath([string]$p) {
  # PowerShell 5.1 兼容: Combine 遇到绝对路径会直接返回第二个参数
  $joined = [System.IO.Path]::Combine((Get-Location).ProviderPath, $p)
  return [System.IO.Path]::GetFullPath($joined).TrimEnd('\', '/')
}

function ConvertTo-ContainerPath([string]$hostPath, [bool]$isOut) {
  $abs = Get-FullPath $hostPath
  if ([string]::Equals($abs, $Cwd, $cmp)) { return '/work' }
  $prefix = $Cwd + $sep
  if ($abs.StartsWith($prefix, $cmp)) {
    return '/work/' + ($abs.Substring($prefix.Length) -replace '\\', '/')
  }
  $parent = [System.IO.Path]::GetDirectoryName($abs)
  $leaf = [System.IO.Path]::GetFileName($abs)
  if ($isOut -and -not $DryRun -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
  for ($k = 0; $k -lt $MountSrcs.Count; $k++) {
    if ([string]::Equals($MountSrcs[$k], $parent, $cmp)) { return $MountDsts[$k] + '/' + $leaf }
  }
  $dst = '/mnt/aib' + ($MountSrcs.Count + 1)
  $MountSrcs.Add($parent)
  $MountDsts.Add($dst)
  return $dst + '/' + $leaf
}

function Get-ArgValue([string]$name) {
  $v = 'x'
  for ($k = 0; $k + 1 -lt $SubArgs.Count; $k++) { if ($SubArgs[$k] -ceq $name) { $v = $SubArgs[$k + 1] } }
  return $v
}

# ---------------------------------------------------------------- 改写参数
$NewArgs = New-Object System.Collections.Generic.List[string]
$j = 0
while ($j -lt $SubArgs.Count) {
  $a = $SubArgs[$j]
  if (($PathOpts -ccontains $a) -and ($j + 1 -lt $SubArgs.Count)) {
    $NewArgs.Add($a)
    $NewArgs.Add((ConvertTo-ContainerPath $SubArgs[$j + 1] ($OutOpts -ccontains $a)))
    $j += 2
    continue
  }
  $NewArgs.Add($a)
  $j++
}
if ($SubCmd -eq 'check-iso' -and $NewArgs.Count -ge 1) {
  $NewArgs[0] = ConvertTo-ContainerPath $NewArgs[0] $false
}

# ---------------------------------------------------------------- 镜像 / 平台
$Variant = ''
$NeedsAmd64 = $false
if ($SubCmd -in @('fetch-offline', 'fetch')) {
  $NeedsAmd64 = $true
  if ((Get-ArgValue '--release') -in @('jammy', '22.04')) { $Variant = '-jammy' }
} elseif ($SubCmd -eq 'build' -and (($SubArgs -ccontains '--fetch-offline') -or ($SubArgs -ccontains '--force-fetch'))) {
  $NeedsAmd64 = $true
  $isoLeaf = [System.IO.Path]::GetFileName((Get-ArgValue '--iso'))
  if ($isoLeaf -match '22\.04|jammy') { $Variant = '-jammy' }
}
if (-not $Platform -and $NeedsAmd64) { $Platform = 'linux/amd64' }
function Get-NormArch([string]$a) {
  switch -Regex ($a) { '^(x86_64|amd64|x64)$' { return 'amd64' } '^(aarch64|arm64)$' { return 'arm64' } default { return $a.ToLower() } }
}
$hostArch = $env:PROCESSOR_ARCHITECTURE
try { $hostArch = [string][System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture } catch { }
$hostArch = Get-NormArch $hostArch
# 只有强制平台与本机架构不同 (如 ARM 机器抓捆绑) 才加架构后缀
$ArchSuffix = ''
if ($Platform) {
  $wantArch = Get-NormArch ($Platform -replace '^.*/', '')
  if ($wantArch -ne $hostArch) { $ArchSuffix = "-$wantArch" }
}
$AutoBuild = -not $Image
if ($Rebuild -and -not $AutoBuild) { Fail '--rebuild 只作用于本地镜像, 不能与 --image 同用' }
$ImageRef = if ($AutoBuild) { "autoinstall-iso-builder:local$Variant$ArchSuffix" } else { $Image }

# ---------------------------------------------------------------- docker 命令
$Docker = New-Object System.Collections.Generic.List[string]
$Docker.AddRange([string[]]@('run', '--rm'))
if (-not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected) { $Docker.Add('-it') }
if ($Platform) { $Docker.AddRange([string[]]@('--platform', $Platform)) }
if ($Cwd.Contains(',')) { Fail "当前目录含逗号, docker --mount 不支持: $Cwd" }
$Docker.AddRange([string[]]@('--mount', "type=bind,source=$Cwd,target=/work", '-w', '/work'))
for ($k = 0; $k -lt $MountSrcs.Count; $k++) {
  if ($MountSrcs[$k].Contains(',')) { Fail "路径含逗号, docker --mount 不支持: $($MountSrcs[$k])" }
  $Docker.AddRange([string[]]@('--mount', "type=bind,source=$($MountSrcs[$k]),target=$($MountDsts[$k])"))
}
# 在 Linux 上用 pwsh 时同样修正属主 (Windows/macOS 的 Docker Desktop 无需)
if (($PSVersionTable.PSVersion.Major -ge 6) -and $IsLinux) {
  $uid = (& id -u).Trim(); $gid = (& id -g).Trim()
  if ($uid -ne '0') { $Docker.AddRange([string[]]@('-e', "AIB_UID=$uid", '-e', "AIB_GID=$gid")) }
}
foreach ($v in @('PIN_NODE_MAJOR', 'PIN_GROK', 'PIN_OPENCODE', 'PIN_OPENMAUSBOT', 'PIN_UNITY_CLI', 'PIN_GITEA', 'UBUNTU_MIRROR', 'UNITY_CLI_CDN_BASE')) {
  $val = [Environment]::GetEnvironmentVariable($v)
  if ($val) { $Docker.AddRange([string[]]@('-e', "$v=$val")) }
}
foreach ($x in $ExtraDockerArgs) { $Docker.Add($x) }
$Docker.Add($ImageRef)
$Docker.Add($SubCmd)
foreach ($x in $NewArgs) { $Docker.Add($x) }

$Build = $null
$Revision = ''
$repoRoot = Split-Path -Parent $PSScriptRoot
if (Get-Command git -ErrorAction SilentlyContinue) {
  $r = (& git -C $repoRoot rev-parse HEAD 2>$null)
  if ($LASTEXITCODE -eq 0 -and $r) { $Revision = ([string]$r).Trim() }
}
if ($AutoBuild) {
  if (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'Dockerfile'))) { Fail "找不到 $repoRoot\Dockerfile; 请在完整仓库里运行, 或用 --image 指定镜像" }
  $ubuntu = if ($Variant -eq '-jammy') { '22.04' } else { '24.04' }
  $Build = New-Object System.Collections.Generic.List[string]
  $Build.AddRange([string[]]@('build', '-t', $ImageRef, '--build-arg', "UBUNTU_VERSION=$ubuntu"))
  if ($Platform) { $Build.AddRange([string[]]@('--platform', $Platform)) }
  if ($env:AIB_BUILD_ARGS) { foreach ($x in ($env:AIB_BUILD_ARGS -split '\s+')) { if ($x) { $Build.Add($x) } } }
  if ($env:APT_MIRROR) { $Build.AddRange([string[]]@('--build-arg', "APT_MIRROR=$($env:APT_MIRROR)")) }
  # 只打 label, 不传 build-arg (build-arg 变化会让 apt 层缓存失效)
  if ($Revision) { $Build.AddRange([string[]]@('--label', "aib.revision=$Revision")) }
  $Build.Add($repoRoot)
}

function Format-Cmd($list) {
  $out = New-Object System.Collections.Generic.List[string]
  $out.Add('docker')
  $prev = ''
  foreach ($x in $list) {
    $s = if (($prev -ceq '--password') -or ($prev -ceq '--gitea-admin-password') -or ($prev -ceq '--jenkins-admin-password')) { '***' } else { $x }
    if ($s -match '^[A-Za-z0-9_./:=,@+%\\-]+$') { $out.Add($s) } else { $out.Add("'" + ($s -replace "'", "''") + "'") }
    $prev = $x
  }
  return ($out -join ' ')
}

if ($DryRun) {
  if ($Build) {
    if ($Rebuild) { Write-Output '# --rebuild: 先构建镜像' } else { Write-Output '# 本地镜像不存在时先构建:' }
    Write-Output (Format-Cmd $Build)
  }
  Write-Output (Format-Cmd $Docker)
  exit 0
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  Fail '未找到 docker。请安装 Docker Desktop (设置里启用 WSL2 后端, 使用 Linux containers)'
}
& docker info *> $null
if ($LASTEXITCODE -ne 0) { Fail 'docker 守护进程不可用 (Docker Desktop 是否已启动?)' }
$osType = (& docker info --format '{{.OSType}}' 2>$null)
if ($osType -and $osType.Trim() -ne 'linux') { Fail "Docker 当前是 $osType containers 模式; 请在 Docker Desktop 托盘菜单切换到 Linux containers" }

if ($Build) {
  $doBuild = $Rebuild
  if (-not $doBuild) {
    & docker image inspect $ImageRef *> $null
    if ($LASTEXITCODE -ne 0) {
      Info "本地镜像 $ImageRef 不存在, 首次构建 (约 3-10 分钟, 取决于网络; Dockerfile 默认清华 apt 源, 换源可设 `$env:APT_MIRROR)"
      $doBuild = $true
    } elseif ($Revision) {
      $haveRev = (& docker image inspect -f '{{ index .Config.Labels "aib.revision" }}' $ImageRef 2>$null)
      if ($haveRev) { $haveRev = ([string]$haveRev).Trim() }
      if ($haveRev -and $haveRev -ne '<no value>' -and $haveRev -ne $Revision) {
        Info "提示: 本地镜像构建于 $($haveRev.Substring(0, [Math]::Min(7, $haveRev.Length))), 仓库已是 $($Revision.Substring(0, 7)); 如脚本有更新请加 --rebuild"
      }
    }
  } else {
    Info "重新构建本地镜像 $ImageRef"
  }
  if ($doBuild) {
    & docker @Build | Out-Host
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  }
}
if ($NeedsAmd64 -and ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64')) {
  Info 'ARM 主机: apt 解析步骤以 linux/amd64 仿真运行, 会比较慢'
}
& docker @Docker
exit $LASTEXITCODE
