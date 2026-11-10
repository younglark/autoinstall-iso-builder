# =============================================================================
# wrapper-dry-run.ps1 — 不需要 docker: 用 aib.ps1 --dry-run 断言参数/路径改写 (Windows 盘符路径)
#   pwsh -File test/wrapper-dry-run.ps1      或 Windows PowerShell 5.1: powershell -File ...
# =============================================================================
$ErrorActionPreference = 'Stop'
$script:Fail = 0
$Aib = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts') 'aib.ps1'
$OnWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows

function Expect($name, $hay, $needle) {
  if ($hay.Contains($needle)) { Write-Output "[pass] $name" } else { Write-Output "[fail] ${name}: 缺少 [$needle] in: $hay"; $script:Fail = 1 }
}
function Reject($name, $hay, $needle) {
  if (-not $hay.Contains($needle)) { Write-Output "[pass] $name" } else { Write-Output "[fail] ${name}: 不应出现 [$needle] in: $hay"; $script:Fail = 1 }
}
function Run-Aib { $r = & $Aib @args; if ($LASTEXITCODE -ne 0) { throw "aib.ps1 exit $LASTEXITCODE" }; return ($r -join "`n") }

foreach ($v in 'AIB_IMAGE', 'AIB_PLATFORM', 'AIB_DOCKER_ARGS', 'AIB_BUILD_ARGS', 'APT_MIRROR') { Remove-Item -Path "Env:$v" -ErrorAction SilentlyContinue }
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("aib-dry-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$proj = Join-Path $work 'proj'
$isos = Join-Path $work 'isos dir'
New-Item -ItemType Directory -Force -Path $proj, $isos | Out-Null
Push-Location $proj
try {
  $projFull = (Get-Location).ProviderPath.TrimEnd('\', '/')
  $isosFull = [System.IO.Path]::GetFullPath($isos).TrimEnd('\', '/')
  $isoArg = Join-Path $isosFull 'u.iso'
  $keyArg = Join-Path $isosFull 'k.pub'
  $outArg = Join-Path 'out' 'n1.iso'   # Windows 上是 out\n1.iso

  $out = Run-Aib --dry-run build --iso $isoArg --out $outArg --password 'p@ss word' --gitea-admin-password 'g1tea secret' --jenkins-admin-password 'j3nkins secret' --ssh-authorized-keys $keyArg --hostname n1
  Expect 'cwd 挂到 /work' $out "source=$projFull,target=/work"
  Expect 'cwd 外 ISO 父目录挂载' $out "source=$isosFull,target=/mnt/aib1"
  Expect 'ISO 参数改写' $out '--iso /mnt/aib1/u.iso'
  Expect '同目录复用挂载' $out '/mnt/aib1/k.pub'
  Reject '不重复挂载' $out '/mnt/aib2'
  Expect '--out 反斜杠转正斜杠' $out '--out /work/out/n1.iso'
  Expect '默认本地镜像' $out 'autoinstall-iso-builder:local build'
  Expect '默认打印自动构建命令' $out 'docker build -t autoinstall-iso-builder:local --build-arg UBUNTU_VERSION=24.04'
  Reject '无 ghcr 默认' $out 'ghcr.io'
  Expect '明文密码打码' $out "--password '***'"
  Reject '明文密码不泄露' $out 'p@ss'
  Expect 'Gitea 密码打码' $out "--gitea-admin-password '***'"
  Reject 'Gitea 密码不泄露' $out 'g1tea'
  Expect 'Jenkins 密码打码' $out "--jenkins-admin-password '***'"
  Reject 'Jenkins 密码不泄露' $out 'j3nkins'
  Reject 'build 不强制平台' $out '--platform'
  if (Test-Path (Join-Path $proj 'out')) { Write-Output '[fail] dry-run 不应创建目录'; $script:Fail = 1 } else { Write-Output '[pass] dry-run 不创建目录' }

  $out = Run-Aib --dry-run fetch-offline --release 22.04 --out (Join-Path $work 'bundles\jammy')
  Expect 'fetch 强制 amd64' $out '--platform linux/amd64'
  Expect 'jammy 本地变体' $out 'autoinstall-iso-builder:local-jammy'
  Expect 'jammy 用 22.04 构建' $out 'UBUNTU_VERSION=22.04 --platform linux/amd64'

  $out = Run-Aib --dry-run build --iso u.iso --out o.iso --x11vnc --disable-wayland --vnc-password 'vnc s3cret'
  Expect '--x11vnc 透传' $out '--x11vnc --disable-wayland'
  Expect 'VNC 密码打码' $out "--vnc-password '***'"
  Reject 'VNC 密码不泄露' $out 's3cret'
  $out = Run-Aib --dry-run fetch-offline --release noble --apt-cache (Join-Path $work 'debcache')
  Expect '--apt-cache 改写' $out '--apt-cache /mnt/aib1/debcache'

  $out = Run-Aib --dry-run --local --rebuild check-iso (Join-Path '..' 'x.iso')
  Expect '--rebuild 先构建' $out '# --rebuild'
  Expect 'check-iso 路径改写' $out 'check-iso /mnt/aib1/x.iso'
  $out = Run-Aib --dry-run --image example.org/me/aib build --iso a.iso --out b.iso
  Expect '--image 原样使用' $out 'example.org/me/aib build'
  Reject '--image 不自动构建' $out 'docker build'

  if ($OnWindows) {
    # 盘符路径 / 不同盘符 / 大小写不敏感
    $out = Run-Aib --dry-run build --iso 'Z:\Some Dir\ubuntu.iso' --out ($projFull.ToUpper() + '\out\a.iso')
    Expect '其他盘符挂载' $out "source=Z:\Some Dir,target=/mnt/aib1"
    Expect '盘符路径改写' $out '--iso /mnt/aib1/ubuntu.iso'
    Expect '大小写不敏感命中 cwd' $out '--out /work/out/a.iso'
    Reject 'Windows 不传 AIB_UID' $out 'AIB_UID='
  }

  $out = Run-Aib --dry-run --docker-arg --network=host local-check
  Expect '--docker-arg 透传' $out '--network=host autoinstall-iso-builder:local local-check'

  & $Aib --dry-run --bogus build *> $null
  if ($LASTEXITCODE -ne 0) { Write-Output '[pass] 未知包装选项报错' } else { Write-Output '[fail] 未知包装选项应报错'; $script:Fail = 1 }
} finally {
  Pop-Location
  Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
if ($script:Fail -ne 0) { Write-Output 'wrapper dry-run (ps1): FAILED'; exit 1 }
Write-Output 'wrapper dry-run (ps1): ALL PASS'
