# Requires admin for winget/Store/VC++ installs
# Logs to C:\Windows\Temp\PostLogon-Install.log

$log = 'C:\Windows\Temp\PostLogon-Install.log'
New-Item -ItemType Directory -Path (Split-Path $log) -Force | Out-Null
Start-Transcript -Path $log -Append | Out-Null
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$jobs = @(
  @{ Name = 'Install-Winget'; Url = 'https://raw.githubusercontent.com/ThioJoe/Windows-Sandbox-Tools/refs/heads/main/Installer%20Scripts/Install-Winget.ps1' },
  @{ Name = 'Install-Microsoft-Store'; Url = 'https://raw.githubusercontent.com/ThioJoe/Windows-Sandbox-Tools/refs/heads/main/Installer%20Scripts/Install-Microsoft-Store.ps1' },
  @{ Name = 'Install VC Redist'; Url = 'https://raw.githubusercontent.com/ThioJoe/Windows-Sandbox-Tools/refs/heads/main/Installer%20Scripts/Install%20VC%20Redist.ps1' },
  @{ Name = 'Sandbox Startup'; Url = 'https://raw.githubusercontent.com/ThioJoe/Windows-Sandbox-Tools/refs/heads/main/Startup%20Scripts/SandboxStartup.ps1' }
)

Write-Host "Starting post-logon installs at $(Get-Date -Format s)"

foreach ($j in $jobs) {
  try {
    Write-Host ">>> $($j.Name)"
    irm $j.Url | iex
    Write-Host "<<< $($j.Name) done"
  } catch {
    Write-Warning "$($j.Name) failed: $($_.Exception.Message)"
  }
}

Write-Host "All tasks finished at $(Get-Date -Format s)"
Stop-Transcript | Out-Null
