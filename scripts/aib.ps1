<#
.SYNOPSIS
  aib.ps1 — 在 Windows (PowerShell 5.1 / 7+) 上用容器运行 autoinstall-iso-builder。

.DESCRIPTION
  .\scripts\aib.ps1 [包装选项] <子命令> [子命令参数...]

  包装选项 (必须写在子命令之前):
    --image REF     镜像仓库, 默认 ghcr.io/younglark/autoinstall-iso-builder (或环境变量 AIB_IMAGE)
    --tag TAG       镜像 tag, 默认 latest (或 AIB_TAG); 抓 jammy 捆绑时自动用 <tag>-jammy
    --local         用本仓库 Dockerfile 现场 docker build (tag: autoinstall-iso-builder:local)
    --pull          运行前强制 docker pull
    --platform P    覆盖 docker --platform (默认: 需要 apt 解析的步骤强制 linux/amd64)
    --docker-arg A  追加一个 docker run 参数, 可重复 (如 --docker-arg --network=host);
                    也可用环境变量 AIB_DOCKER_ARGS (按空白切分)
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
  if ($m.Success) { Write-Output $m.Groups[1].Value } else { Write-Output 'aib.ps1 [--image R] [--tag T] [--local] [--pull] [--platform P] [--dry-run] <subcommand> [args...]' }
}
function Fail([string]$msg) { [Console]::Error.WriteLine("[aib] 错误: $msg"); exit 1 }
function Info([string]$msg) { [Console]::Error.WriteLine("[aib] $msg") }

$OnWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
$Image = if ($env:AIB_IMAGE) { $env:AIB_IMAGE } else { 'ghcr.io/younglark/autoinstall-iso-builder' }
$Tag = if ($env:AIB_TAG) { $env:AIB_TAG } else { 'latest' }
$Platform = if ($env:AIB_PLATFORM) { $env:AIB_PLATFORM } else { '' }
$LocalBuild = $false
$Pull = $false
$DryRun = $false
$ExtraDockerArgs = New-Object System.Collections.Generic.List[string]
if ($env:AIB_DOCKER_ARGS) { foreach ($x in ($env:AIB_DOCKER_ARGS -split '\s+')) { if ($x) { $ExtraDockerArgs.Add($x) } } }

$all = @($args | ForEach-Object { [string]$_ })
$i = 0
# 注意: 不用 switch——switch 里的 continue/break 作用于 switch 本身而非 while
while ($i -lt $all.Count) {
  $a = $all[$i]
  if ($a -ceq '--image' -or $a -ceq '--tag' -or $a -ceq '--platform' -or $a -ceq '--docker-arg') {
    if ($i + 1 -ge $all.Count) { Fail "$a 需要参数" }
    $v = $all[$i + 1]
    if ($a -ceq '--image') { $Image = $v } elseif ($a -ceq '--tag') { $Tag = $v } elseif ($a -ceq '--platform') { $Platform = $v } else { $ExtraDockerArgs.Add($v) }
    $i += 2
  } elseif ($a -ceq '--local') { $LocalBuild = $true; $i++ }
  elseif ($a -ceq '--pull') { $Pull = $true; $i++ }
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
$ImageRef = if ($LocalBuild) { "autoinstall-iso-builder:local$Variant" } else { "${Image}:${Tag}$Variant" }

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
foreach ($v in @('PIN_NODE_MAJOR', 'PIN_GROK', 'PIN_OPENCODE', 'PIN_OPENMAUSBOT', 'PIN_UNITY_CLI', 'UBUNTU_MIRROR', 'UNITY_CLI_CDN_BASE')) {
  $val = [Environment]::GetEnvironmentVariable($v)
  if ($val) { $Docker.AddRange([string[]]@('-e', "$v=$val")) }
}
foreach ($x in $ExtraDockerArgs) { $Docker.Add($x) }
$Docker.Add($ImageRef)
$Docker.Add($SubCmd)
foreach ($x in $NewArgs) { $Docker.Add($x) }

$Build = $null
if ($LocalBuild) {
  $repoRoot = Split-Path -Parent $PSScriptRoot
  $ubuntu = if ($Variant -eq '-jammy') { '22.04' } else { '24.04' }
  $Build = New-Object System.Collections.Generic.List[string]
  $Build.AddRange([string[]]@('build', '-t', $ImageRef, '--build-arg', "UBUNTU_VERSION=$ubuntu"))
  if ($Platform) { $Build.AddRange([string[]]@('--platform', $Platform)) }
  $Build.Add($repoRoot)
}

function Format-Cmd($list) {
  $out = New-Object System.Collections.Generic.List[string]
  $out.Add('docker')
  $prev = ''
  foreach ($x in $list) {
    $s = if ($prev -ceq '--password') { '***' } else { $x }
    if ($s -match '^[A-Za-z0-9_./:=,@+%\\-]+$') { $out.Add($s) } else { $out.Add("'" + ($s -replace "'", "''") + "'") }
    $prev = $x
  }
  return ($out -join ' ')
}

if ($DryRun) {
  if ($Build) { Write-Output (Format-Cmd $Build) }
  if ($Pull -and -not $LocalBuild) {
    $p = @('pull'); if ($Platform) { $p += @('--platform', $Platform) }; $p += $ImageRef
    Write-Output (Format-Cmd $p)
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
  Info "本地构建镜像 $ImageRef"
  & docker @Build
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} elseif ($Pull) {
  $p = @('pull'); if ($Platform) { $p += @('--platform', $Platform) }; $p += $ImageRef
  & docker @p
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
if ($NeedsAmd64 -and ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64')) {
  Info 'ARM 主机: apt 解析步骤以 linux/amd64 仿真运行, 会比较慢'
}
& docker @Docker
exit $LASTEXITCODE
