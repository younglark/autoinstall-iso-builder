# =============================================================================
# aib-win run-all.ps1 — 首次登录时由 FirstLogonCommands 调用 (管理员、提权)
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\aib\run-all.ps1
#
# - 按文件名顺序执行 C:\aib\scripts\*.ps1, 每个脚本单独子进程 + 单独日志 C:\aib\logs\<name>.log
# - 单个脚本失败不影响后续 (对应 Ubuntu 侧 software/run-all.sh); 结果汇总到 C:\aib\logs\summary.txt
# - 成功的脚本写 C:\aib\state\<name>.done, 重跑时跳过 (幂等); 99-* 收尾脚本每次都跑
# - 不处理任何密码 (payload 里没有密码)
# =============================================================================
$ErrorActionPreference = 'Continue'
$Root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$Scripts = Join-Path $Root 'scripts'
$Logs    = Join-Path $Root 'logs'
$State   = Join-Path $Root 'state'
New-Item -ItemType Directory -Force -Path $Logs, $State | Out-Null
$Summary = Join-Path $Logs 'summary.txt'

function Write-Summary([string]$msg) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Add-Content -Path $Summary -Value $line -Encoding UTF8
    Write-Host $line
}

Write-Summary "run-all start (root=$Root, user=$env:USERNAME, computer=$env:COMPUTERNAME)"
$ok = 0; $failed = @(); $skipped = 0
$list = Get-ChildItem -Path $Scripts -Filter '*.ps1' -File -ErrorAction SilentlyContinue | Sort-Object Name
foreach ($s in $list) {
    $name = [IO.Path]::GetFileNameWithoutExtension($s.Name)
    $done = Join-Path $State "$name.done"
    if ((Test-Path $done) -and ($name -notlike '99-*')) {
        Write-Summary "[skip] $name (already done)"
        $skipped++
        continue
    }
    $log = Join-Path $Logs "$name.log"
    Write-Summary "[run ] $name -> $log"
    $rc = 1
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $s.FullName *> $log
        $rc = $LASTEXITCODE
        if ($null -eq $rc) { $rc = 0 }
    } catch {
        Add-Content -Path $log -Value "run-all: exception: $_" -Encoding UTF8
        $rc = 1
    }
    if ($rc -eq 0) {
        Set-Content -Path $done -Value (Get-Date -Format o) -Encoding UTF8
        Write-Summary "[ ok ] $name"
        $ok++
    } else {
        Write-Summary "[FAIL] $name (exit $rc), see $log"
        $failed += $name
    }
}
Write-Summary ("run-all done: ok={0} failed={1} skipped={2} {3}" -f $ok, $failed.Count, $skipped, ($failed -join ','))
exit 0
