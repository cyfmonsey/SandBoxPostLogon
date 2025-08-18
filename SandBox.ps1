# C:\Tools\PostLogon-Install.ps1
# Logs to C:\Windows\Temp\PostLogon-Install.log

$LogPath = 'C:\Windows\Temp\PostLogon-Install.log'

# --- LOGGING ---------------------------------------------------------------
New-Item -ItemType Directory -Path (Split-Path $LogPath) -Force | Out-Null
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level.ToUpper(), $Message
    Add-Content -Path $LogPath -Value $line
    Write-Host $line
}
try { Start-Transcript -Path $LogPath -Append | Out-Null } catch { Write-Log "Transcript failed to start: $($_.Exception.Message)" 'WARN' }

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Log "=== Post-Logon start ==="
Write-Log ("Host: {0}  OS: {1}  Arch: {2}  PS: {3}" -f $env:COMPUTERNAME, (Get-CimInstance Win32_OperatingSystem).Version, $ENV:PROCESSOR_ARCHITECTURE, $PSVersionTable.PSVersion)

# --- HELPERS ---------------------------------------------------------------
function Test-Endpoint443 {
    param([Parameter(Mandatory)] [string]$Host)
    try {
        if (Get-Command Test-NetConnection -ErrorAction SilentlyContinue) {
            $t = Test-NetConnection -ComputerName $Host -Port 443 -WarningAction SilentlyContinue
            return ($t.TcpTestSucceeded -eq $true)
        } else {
            # Fallback quick check
            $req = [System.Net.HttpWebRequest]::Create("https://$Host/")
            $req.Method = 'HEAD'
            $req.Timeout = 5000
            $resp = $req.GetResponse()
            $resp.Close()
            return $true
        }
    } catch { return $false }
}

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [int]$RetryCount = 3,
        [int]$InitialDelaySec = 3,
        [string]$What = 'operation'
    )
    $delay = $InitialDelaySec
    for ($i=1; $i -le $RetryCount; $i++) {
        try {
            Write-Log "$What (attempt $i/$RetryCount)..."
            return & $ScriptBlock
        } catch {
            Write-Log "$What failed (attempt $i): $($_.Exception.Message)" 'WARN'
            if ($i -lt $RetryCount) {
                Start-Sleep -Seconds $delay
                $delay = [Math]::Min($delay * 2, 30)
            } else {
                throw
            }
        }
    }
}

function Invoke-RemoteScript {
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$Name = $(Split-Path $Url -Leaf),
        [int]$TimeoutSec = 60
    )
    Write-Log ">>> $Name from $Url"
    $hostName = ([uri]$Url).Host
    if (-not (Test-Endpoint443 -Host $hostName)) {
        throw "Cannot reach $hostName:443"
    }
    $ua = "PostLogon-Install/1.0 (+Windows; PowerShell $($PSVersionTable.PSVersion))"

    Invoke-WithRetry -What "$Name download+exec" -ScriptBlock {
        $code = Invoke-RestMethod -Uri $Url -Headers @{ 'User-Agent' = $ua } -TimeoutSec $TimeoutSec
        if (-not $code -or -not ($code -is [string]) -or $code.Trim().Length -lt 10) {
            throw "Empty/short payload for $Name"
        }
        # Execute in current session to preserve context
        $ExecutionContext.InvokeCommand.InvokeScript($false, ([scriptblock]::Create($code)), $null, $null) | Out-Null
    }
    Write-Log "<<< $Name done"
}

function Test-VCppInstalled {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($p in $paths) {
        Get-ChildItem $p -ErrorAction SilentlyContinue | ForEach-Object {
            $d = Get-ItemProperty $_.PsPath -ErrorAction SilentlyContinue
            if ($null -ne $d.DisplayName -and $d.DisplayName -match 'Microsoft Visual C\+\+ 2015-2022.*x64') {
                return @{
                    Installed = $true
                    DisplayName = $d.DisplayName
                    Version = $d.DisplayVersion
                }
            }
        }
    }
    return @{ Installed = $false }
}

function Install-VCppQuiet {
    param([int]$TimeoutSeconds = 600)
    $check = Test-VCppInstalled
    if ($check.Installed) {
        Write-Log "VC++ already installed ($($check.DisplayName) v$($check.Version)) — skipping."
        return 0
    }

    $vcUrl  = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'  # evergreen
    $vcExe  = Join-Path $env:TEMP 'vc_redist.x64.exe'
    $vcLog  = 'C:\Windows\Temp\vc_redist_install.log'

    Write-Log "Downloading VC++ redist: $vcUrl"
    Invoke-WithRetry -What "Download vc_redist.x64.exe" -ScriptBlock {
        Invoke-WebRequest -Uri $vcUrl -OutFile $vcExe -UseBasicParsing -TimeoutSec 120
    }

    $args = "/quiet /norestart /log `"$vcLog`""
    Write-Log "Starting VC++ installer (quiet) ..."
    $p = Start-Process -FilePath $vcExe -ArgumentList $args -PassThru -WindowStyle Hidden

    $ok = $p.WaitForExit($TimeoutSeconds * 1000)
    if (-not $ok) {
        Write-Log "VC++ installer timed out after $TimeoutSeconds sec — terminating..." 'WARN'
        try { $p.Kill() } catch {}
        throw "VC++ install hang/timeout"
    }

    $code = $p.ExitCode
    Write-Log "VC++ installer exit code: $code"
    switch ($code) {
        0     { Write-Log "VC++ install successful." }
        1638  { Write-Log "Another version present (1638) — treating as OK." }
        3010  { Write-Log "Success, reboot required (3010)." }
        default { throw "VC++ installer failed with exit code $code. See $vcLog" }
    }

    # Re-check after install
    $post = Test-VCppInstalled
    if (-not $post.Installed) {
        Write-Log "VC++ not detected post-install — check $vcLog" 'WARN'
    } else {
        Write-Log "VC++ detected: $($post.DisplayName) v$($post.Version)"
    }
    return $code
}

# --- MAIN -------------------------------------------------------------------
$failures = @()

Write-Log "Starting post-logon tasks at $(Get-Date -Format s)"

# 1) Winget
try {
    Invoke-RemoteScript -Name 'Install-Winget' -Url 'https://raw.githubusercontent.com/ThioJoe/Windows-Sandbox-Tools/refs/heads/main/Installer%20Scripts/Install-Winget.ps1'
} catch { Write-Log "Install-Winget failed: $($_.Exception.Message)" 'ERROR'; $failures += 'Install-Winget' }

# 2) Microsoft Store
try {
    Invoke-RemoteScript -Name 'Install-Microsoft-Store' -Url 'https://raw.githubusercontent.com/ThioJoe/Windows-Sandbox-Tools/refs/heads/main/Installer%20Scripts/Install-Microsoft-Store.ps1'
} catch { Write-Log "Install-Microsoft-Store failed: $($_.Exception.Message)" 'ERROR'; $failures += 'Install-Microsoft-Store' }

# 3) VC++ (quiet, with timeout & logging)
try {
    Install-VCppQuiet -TimeoutSeconds 600 | Out-Null
} catch {
    Write-Log "Primary VC++ path failed: $($_.Exception.Message)" 'WARN'
    Write-Log "Falling back to ThioJoe VC++ script…" 'WARN'
    try {
        Invoke-RemoteScript -Name 'Install VC Redist (fallback)' -Url 'https://raw.githubusercontent.com/ThioJoe/Windows-Sandbox-Tools/refs/heads/main/Installer%20Scripts/Install%20VC%20Redist.ps1'
    } catch {
        Write-Log "Fallback VC++ script failed: $($_.Exception.Message)" 'ERROR'
        $failures += 'VC++ Redist'
    }
}

# 4) Sandbox startup
try {
    Invoke-RemoteScript -Name 'Sandbox Startup' -Url 'https://raw.githubusercontent.com/ThioJoe/Windows-Sandbox-Tools/refs/heads/main/Startup%20Scripts/SandboxStartup.ps1'
} catch { Write-Log "Sandbox Startup failed: $($_.Exception.Message)" 'ERROR'; $failures += 'SandboxStartup' }

# --- SUMMARY / EXIT ---------------------------------------------------------
if ($failures.Count -gt 0) {
    Write-Log ("Completed with failures: {0}" -f ($failures -join ', ')) 'ERROR'
    Write-Log "=== Post-Logon end (FAILED) ==="
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
} else {
    Write-Log "All tasks completed successfully."
    Write-Log "=== Post-Logon end (OK) ==="
    try { Stop-Transcript | Out-Null } catch {}
    exit 0
}
