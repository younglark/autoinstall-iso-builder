# 记录装机环境, 方便排查 (不含任何密码)
$ErrorActionPreference = 'Stop'
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
"time        : $(Get-Date -Format o)"
"computer    : $env:COMPUTERNAME"
"user        : $env:USERNAME"
"os          : $($os.Caption) $($os.Version) build $($os.BuildNumber)"
"edition     : $((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID)"
"displayver  : $((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').DisplayVersion)"
"model       : $($cs.Manufacturer) $($cs.Model)"
"memory (GB) : $([math]::Round($cs.TotalPhysicalMemory / 1GB, 1))"
"locale      : $((Get-WinSystemLocale).Name) / UI $((Get-WinUILanguageOverride).Name) / culture $((Get-Culture).Name)"
"timezone    : $((Get-TimeZone).Id)"
try { "secureboot  : $(Confirm-SecureBootUEFI)" } catch { "secureboot  : unknown ($($_.Exception.Message))" }
try { $t = Get-Tpm; "tpm         : present=$($t.TpmPresent) ready=$($t.TpmReady)" } catch { "tpm         : unknown" }
"--- disks"
Get-Disk | Format-Table -AutoSize Number, FriendlyName, BusType, PartitionStyle, @{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}} | Out-String -Width 200
"--- volumes"
Get-Volume | Format-Table -AutoSize DriveLetter, FileSystemLabel, FileSystem, @{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}} | Out-String -Width 200
"--- net"
Get-NetAdapter | Format-Table -AutoSize Name, InterfaceDescription, Status, LinkSpeed | Out-String -Width 200
"--- devices with problems (missing drivers)"
Get-PnpDevice -PresentOnly | Where-Object { $_.Status -ne 'OK' } | Format-Table -AutoSize Class, FriendlyName, Status, InstanceId | Out-String -Width 250
if (Test-Path 'C:\Windows\Temp\aib-payload-copy.log') {
    "--- specialize payload copy log"
    Get-Content 'C:\Windows\Temp\aib-payload-copy.log'
}
exit 0
