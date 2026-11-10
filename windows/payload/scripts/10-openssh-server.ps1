# 启用 OpenSSH Server (Microsoft Learn: Get started with OpenSSH for Windows)
# OpenSSH.Server 是按需功能 (FoD): 未预装时 Add-WindowsCapability 需要能访问 Windows Update; 离线会失败 (单独记日志, 不影响其它脚本)
$ErrorActionPreference = 'Stop'
$cap = Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*' | Select-Object -First 1
if (-not $cap) { throw 'OpenSSH.Server capability not found on this image' }
"capability: $($cap.Name) state=$($cap.State)"
if ($cap.State -ne 'Installed') {
    Add-WindowsCapability -Online -Name $cap.Name | Out-String
}
Set-Service -Name sshd -StartupType 'Automatic'
Start-Service sshd
if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    'firewall rule OpenSSH-Server-In-TCP created'
}
Get-Service sshd | Format-Table -AutoSize Name, Status, StartType | Out-String
exit 0
