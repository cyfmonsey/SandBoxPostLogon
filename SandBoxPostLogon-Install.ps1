# C:\Tools\PostLogon-Install.ps1
# Logs to C:\Windows\Temp\PostLogon-Install.log

$log = 'C:\Windows\Temp\PostLogon-Install.log'
New-Item -ItemType Directory -Path (Split-Path $log) -Force | Out-Null
Start-Transcript -Path $log -Append | Out-Null
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Invoke-RemoteScript {
    param(
        [Parameter(Mandatory)] [string]$Url,
        [string]$Name = $(Split-Path $Url -Leaf)
    )
    Write-Host ">>> $Name"
    try {
        irm $Url | iex
        Write-Host "<<< $Name done"
    } catch {
        Write-Warning "$Name failed: $($_.Exception.Message)"
        throw
    }
}

function Test-VCppInstalled {
    # 2015–2022 redist puts an MSI product code under Uninstall; check x64
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($p in $paths) {
        Get-ChildItem $p -ErrorAction SilentlyContinue | ForEach-Object {
            $d = Get-ItemProperty $_.PsPath -ErrorAction SilentlyContinue
            if ($d.DisplayName -match 'Microsoft Visual C\+\+ 2015-2022.*x64') { return $true }
            if ($d.DisplayName -match 'Microsoft Visual C\+\+ 2015-2022.*\(x64\)') { return $true }
        }
    }
    return $false
}

function Install-VCppQuiet {
    param(
        [int]$TimeoutSeconds = 600
    )
    if (Test-VCppInstalled) {
        Write-Host "VC++ 2015–2022 (x64) already installed — skipping."
        return
    }

    $vcUrl  = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'  # Official evergreen link
    $vcExe  = Join-Path $env:TEMP 'vc_redist.x64.exe'
    $vcLog  = 'C:\Windows\Temp\vc_redist_install.log'

    Write-Host "Downloading VC++ redist: $vcUrl"
    Invoke-WebRequest -Uri $vcUrl -OutFile $vcExe -UseBasicParsing

    $args = "/quiet /norestart /log `"$vcLog`""
    Write-Host "Starting VC++ installer (quiet) ..."
    $p = Start-Process -FilePath $vcExe -ArgumentList $args -PassThru -WindowStyle Hidden

    $ok = $p.WaitForExit($TimeoutSeconds * 1000)
    if (-not $ok) {
        Write-Warning "VC++ installer timed out after $TimeoutSeconds seconds. Killing process..."
        try { $p.Kill() } catch {}
        throw "VC++ install hang/timeout"
    }

    $code = $p.ExitCode
    # Common codes: 0=success, 1638=another version present, 3010=success reboot required
    if ($code -in 0, 1638, 3010) {
        Write-Host "VC++ installer finished with code $code."
        if ($code -eq 3010) { Write-Host "Reboot required (3010)." }
    } else {
        throw "VC++ installer failed with exit code $code. See $vcLog"
    }
}

Write-Host "Starting post-logon tasks at $(Get-Date -Format s)"

# 1) Winget
Invoke-RemoteScript -Name 'Install-Winget' -Url 'https://raw.githubusercontent.com/ThioJoe/Windows-Sandbox-Tools/refs/heads/main/Installer%20Scripts/Install-Winget.ps1'

# 2) Microsoft Store
Invoke-RemoteScript -Name 'Install-Microsoft-Store' -Url 'https://raw.githubusercontent.com/ThioJoe/Windows-Sandbox-Tools/refs/heads/main/Installer%20Scripts/Install-Microsoft-Store.ps1'

# 3) VC++ (quiet, with timeout & logging) — replaces the hanging step
try {
    Install-VCppQuiet -TimeoutSeconds 600
} catch {
    Write-Warning "Primary VC++ install path failed: $($_.Exception.Message)"
    Write-Warning "Falling back to ThioJoe VC++ script (may hang again):"
    Invoke-RemoteScript -Name 'Install VC Redist (fallback)' -Url 'https://raw.githubusercontent.com/ThioJoe/Windows-Sandbox-Tools/refs/heads/main/Installer%20Scripts/Install%20VC%20Redist.ps1'
}

# 4) Sandbox startup (your added step)
Invoke-RemoteScript -Name 'Sandbox Startup' -Url 'https://raw.githubusercontent.com/ThioJoe/Windows-Sandbox-Tools/refs/heads/main/Startup%20Scripts/SandboxStartup.ps1'

Write-Host "All tasks finished at $(Get-Date -Format s)"
Stop-Transcript | Out-Null
