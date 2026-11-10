# 收尾: 删除 Setup 缓存的答案文件 (可能含账户 / AutoLogon 密码), 关闭 AutoLogon
# Learn: Setup 把答案文件缓存到 %WINDIR%\Panther, 交付前应删除; AutoLogon 应在交付前关闭
# Learn LogonCount known issue: LogonCount=1 实际可能多自动登录一次, 所以这里显式把计数清零
$ErrorActionPreference = 'Continue'
$rc = 0
$targets = @(
    "$env:WINDIR\Panther\unattend.xml",
    "$env:WINDIR\Panther\Unattend.xml",
    "$env:WINDIR\Panther\autounattend.xml",
    "$env:WINDIR\Panther\Unattend\unattend.xml",
    "$env:WINDIR\Panther\Unattend\autounattend.xml",
    "$env:WINDIR\System32\Sysprep\unattend.xml",
    "$env:WINDIR\System32\Sysprep\Panther\unattend.xml",
    "$env:SystemDrive\unattend.xml",
    "$env:SystemDrive\autounattend.xml"
) | Select-Object -Unique
foreach ($f in $targets) {
    if (Test-Path -LiteralPath $f) {
        try { Remove-Item -LiteralPath $f -Force -ErrorAction Stop; "removed $f" }
        catch { "FAILED to remove ${f}: $($_.Exception.Message)"; $rc = 1 }
    }
}
$left = Get-ChildItem -Path "$env:WINDIR\Panther" -Recurse -Include 'unattend*.xml', 'autounattend*.xml' -File -ErrorAction SilentlyContinue
if ($left) { "still present:"; $left.FullName; $rc = 1 } else { 'no cached unattend/autounattend xml under Panther' }

$wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
try {
    Set-ItemProperty -Path $wl -Name AutoAdminLogon -Value '0' -Type String
    Set-ItemProperty -Path $wl -Name AutoLogonCount -Value 0 -Type DWord
    Remove-ItemProperty -Path $wl -Name DefaultPassword -ErrorAction SilentlyContinue
    'AutoLogon disabled (AutoAdminLogon=0, AutoLogonCount=0, DefaultPassword removed)'
} catch { "FAILED to disable AutoLogon: $($_.Exception.Message)"; $rc = 1 }
if ((Get-ItemProperty -Path $wl -ErrorAction SilentlyContinue).PSObject.Properties.Name -contains 'DefaultPassword') { 'DefaultPassword still present'; $rc = 1 }
exit $rc
