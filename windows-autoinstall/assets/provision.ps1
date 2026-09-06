$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$appPrefix = "__APP_PREFIX_PS__"
$computerName = $env:COMPUTERNAME
$administratorUsername = "__ADMIN_USERNAME_PS__"

$mutex = [System.Threading.Mutex]::new($false, "Global\$($appPrefix)Provision")
if (-not $mutex.WaitOne(0)) {
    exit 0
}

$root = "C:\ProgramData\$appPrefix"
$config = Join-Path $root "config"
$state = Join-Path $root "state"
$log = Join-Path $root "provision.log"

New-Item -ItemType Directory -Force -Path $state | Out-Null
& icacls.exe $root /inheritance:r /grant:r "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F"
if ($LASTEXITCODE -ne 0) {
    throw "Could not secure $root"
}
Start-Transcript -LiteralPath $log -Append

function Invoke-External {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )

    Write-Host "Running: $FilePath $($ArgumentList -join ' ')"
    $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Wait -PassThru
    if ($process.ExitCode -notin @(0, 1641, 3010)) {
        throw "$FilePath exited with code $($process.ExitCode)"
    }
}

function Configure-Wifi {
    $profile = Join-Path $config "wifi-profile.xml"
    $ssid = (Get-Content -LiteralPath (Join-Path $config "wifi-ssid") -Raw).Trim()

    $locationPolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy"
    New-Item -Path $locationPolicy -Force | Out-Null
    Set-ItemProperty `
        -Path $locationPolicy `
        -Name "LetAppsAccessLocation" `
        -Type DWord `
        -Value 1
    $locationService = "HKLM:\SYSTEM\CurrentControlSet\Services\lfsvc\Service\Configuration"
    New-Item -Path $locationService -Force | Out-Null
    Set-ItemProperty -Path $locationService -Name "Status" -Type DWord -Value 1
    Set-Service -Name lfsvc -StartupType Manual
    Start-Service -Name lfsvc

    & netsh.exe wlan add profile "filename=$profile" user=all | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "The Wi-Fi profile could not be imported yet. Ethernet remains available."
        return $false
    }

    & netsh.exe wlan connect name="$ssid" ssid="$ssid" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "The Wi-Fi profile was imported, but association has not completed yet."
        return $false
    }
    return $true
}

function Install-OpenSshServer {
    if (Get-Service -Name sshd -ErrorAction SilentlyContinue) {
        return
    }

    $installer = Join-Path $root "packages\OpenSSH-Win64.msi"
    if (-not (Test-Path -LiteralPath $installer)) {
        throw "Bundled OpenSSH installer is missing: $installer"
    }
    Invoke-External msiexec.exe @("/i", $installer, "/qn", "/norestart")
    if (-not (Get-Service -Name sshd -ErrorAction SilentlyContinue)) {
        throw "Bundled OpenSSH installation completed without creating the sshd service"
    }
}

function Install-Tailscale {
    if (-not (Get-Service -Name Tailscale -ErrorAction SilentlyContinue)) {
        $installer = Join-Path $root "packages\Tailscale-amd64.msi"
        if (-not (Test-Path -LiteralPath $installer)) {
            throw "Bundled Tailscale installer is missing: $installer"
        }
        Invoke-External msiexec.exe @(
            "/i",
            $installer,
            "/qn",
            "/norestart",
            "TS_UNATTENDEDMODE=always",
            "TS_NOLAUNCH=1"
        )
    }

    Set-Service -Name Tailscale -StartupType Automatic
    Start-Service -Name Tailscale
}

function Connect-Tailscale {
    $authKeyFile = Join-Path $config "tailscale-auth-key"
    if (-not (Test-Path -LiteralPath $authKeyFile)) {
        throw "Tailscale auth key is missing: $authKeyFile"
    }

    $tailscale = Join-Path $env:ProgramFiles "Tailscale\tailscale.exe"
    if (-not (Test-Path -LiteralPath $tailscale)) {
        throw "Could not find tailscale.exe"
    }

    $taskName = "$appPrefix-TailscaleEnroll"
    $helperScript = Join-Path $state "tailscale-enroll.ps1"
    $resultFile = Join-Path $state "tailscale-enroll-result.txt"
    $errorFile = Join-Path $state "tailscale-enroll-error.txt"
    Remove-Item -LiteralPath $resultFile, $errorFile -Force -ErrorAction SilentlyContinue

    $helperContent = @'
$ErrorActionPreference = "Stop"
try {
    & "@@TAILSCALE@@" up `
        "--auth-key=file:@@AUTH_KEY@@" `
        "--hostname=@@HOSTNAME@@" `
        "--timeout=2m" `
        --unattended
    if ($LASTEXITCODE -ne 0) {
        throw "tailscale up exited with code $LASTEXITCODE"
    }
    $status = & "@@TAILSCALE@@" status --json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $status.BackendState -ne "Running") {
        throw "Tailscale backend is not running after enrollment"
    }
    Set-Content -LiteralPath "@@RESULT@@" -Value "ready" -Encoding Ascii
} catch {
    Set-Content -LiteralPath "@@ERROR@@" -Value $_.Exception.ToString() -Encoding UTF8
    exit 1
}
'@
    $helperContent = $helperContent.Replace("@@TAILSCALE@@", $tailscale)
    $helperContent = $helperContent.Replace("@@AUTH_KEY@@", $authKeyFile)
    $helperContent = $helperContent.Replace("@@HOSTNAME@@", $computerName)
    $helperContent = $helperContent.Replace("@@RESULT@@", $resultFile)
    $helperContent = $helperContent.Replace("@@ERROR@@", $errorFile)
    Set-Content -LiteralPath $helperScript -Value $helperContent -Encoding Ascii

    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$helperScript`""
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5)
    $principal = New-ScheduledTaskPrincipal `
        -UserId "$computerName\$administratorUsername" `
        -LogonType S4U `
        -RunLevel Highest
    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Force | Out-Null

    try {
        Write-Host "Enrolling $computerName in Tailscale as $administratorUsername"
        Start-ScheduledTask -TaskName $taskName
        for ($attempt = 1; $attempt -le 150; $attempt++) {
            if (Test-Path -LiteralPath $resultFile) {
                return
            }
            if (Test-Path -LiteralPath $errorFile) {
                throw (Get-Content -LiteralPath $errorFile -Raw)
            }
            Start-Sleep -Seconds 1
        }
        throw "Tailscale enrollment did not finish within 150 seconds"
    } finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item `
            -LiteralPath $helperScript, $resultFile, $errorFile `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

function Configure-RemoteAdministration {
    $policy = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
    New-Item -Path $policy -Force | Out-Null
    Set-ItemProperty -Path $policy -Name "ConsentPromptBehaviorAdmin" -Type DWord -Value 0
    Set-ItemProperty -Path $policy -Name "PromptOnSecureDesktop" -Type DWord -Value 0
    Set-ItemProperty -Path $policy -Name "EnableInstallerDetection" -Type DWord -Value 0
    Set-ItemProperty -Path $policy -Name "EnableLUA" -Type DWord -Value 1
    Set-ItemProperty -Path $policy -Name "LocalAccountTokenFilterPolicy" -Type DWord -Value 1

    Invoke-External powercfg.exe @("/change", "standby-timeout-ac", "0")
    Invoke-External powercfg.exe @("/change", "hibernate-timeout-ac", "0")

    $sshRoot = "C:\ProgramData\ssh"
    New-Item -ItemType Directory -Force -Path $sshRoot | Out-Null
    Copy-Item `
        -LiteralPath (Join-Path $config "ssh-public-key") `
        -Destination (Join-Path $sshRoot "administrators_authorized_keys") `
        -Force
    & icacls.exe (Join-Path $sshRoot "administrators_authorized_keys") `
        /inheritance:r `
        /grant:r "SYSTEM:F" `
        /grant "Administrators:F"
    if ($LASTEXITCODE -ne 0) {
        throw "Could not secure the administrators_authorized_keys file"
    }

    @(
        "Port 22",
        "PubkeyAuthentication yes",
        "PasswordAuthentication no",
        "KbdInteractiveAuthentication no",
        "PermitEmptyPasswords no",
        "AllowUsers $administratorUsername",
        "Subsystem sftp sftp-server.exe",
        "",
        "Match Group administrators",
        "       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys"
    ) | Set-Content -LiteralPath (Join-Path $sshRoot "sshd_config") -Encoding Ascii

    $openSshPolicy = "HKLM:\SOFTWARE\OpenSSH"
    New-Item -Path $openSshPolicy -Force | Out-Null
    Set-ItemProperty `
        -Path $openSshPolicy `
        -Name "DefaultShell" `
        -Type String `
        -Value "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"

    $sshd = @(
        "$env:WINDIR\System32\OpenSSH\sshd.exe",
        "$env:ProgramFiles\OpenSSH\sshd.exe"
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $sshd) {
        throw "Could not find sshd.exe"
    }
    & $sshd -t
    if ($LASTEXITCODE -ne 0) {
        throw "OpenSSH rejected the generated sshd_config"
    }
    Set-Service -Name sshd -StartupType Automatic
    Start-Service -Name sshd

    $firewallRuleName = "$appPrefix SSH"
    Get-NetFirewallRule `
        -DisplayName $firewallRuleName `
        -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule
    New-NetFirewallRule `
        -DisplayName $firewallRuleName `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalPort 22 `
        -Profile Any `
        -RemoteAddress @("LocalSubnet", "100.64.0.0/10", "fd7a:115c:a1e0::/48") | Out-Null

    $terminalServer = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server"
    $rdpListener = Join-Path $terminalServer "WinStations\RDP-Tcp"
    Set-ItemProperty -Path $terminalServer -Name "fDenyTSConnections" -Type DWord -Value 0
    Set-ItemProperty -Path $rdpListener -Name "UserAuthentication" -Type DWord -Value 1
    Set-Service -Name TermService -StartupType Automatic
    Start-Service -Name TermService

    Get-NetFirewallRule `
        -Name "RemoteDesktop-UserMode-In-*" `
        -ErrorAction SilentlyContinue |
        Disable-NetFirewallRule
    $rdpFirewallRuleName = "$appPrefix RDP"
    Get-NetFirewallRule `
        -DisplayName $rdpFirewallRuleName `
        -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule
    New-NetFirewallRule `
        -DisplayName $rdpFirewallRuleName `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalPort 3389 `
        -Profile Any `
        -RemoteAddress @("LocalSubnet", "100.64.0.0/10", "fd7a:115c:a1e0::/48") | Out-Null
}

function Remove-RemoteSetupSecrets {
    foreach ($path in @(
        (Join-Path $config "ssh-public-key"),
        (Join-Path $config "tailscale-auth-key"),
        "C:\Windows\Panther\unattend.xml",
        "C:\Windows\Panther\Unattend\unattend.xml",
        "C:\Windows\System32\Sysprep\unattend.xml"
    )) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

try {
    $wifiProfile = Join-Path $config "wifi-profile.xml"
    $wifiConfigured = if (Test-Path -LiteralPath $wifiProfile) {
        Configure-Wifi
    } else {
        $true
    }

    $remoteReady = Join-Path $state "remote-ready.txt"
    if (-not (Test-Path -LiteralPath $remoteReady)) {
        Install-OpenSshServer
        Install-Tailscale
        Configure-RemoteAdministration
        Connect-Tailscale
        @(
            "Remote administration is ready.",
            "Host: $computerName",
            "SSH user: $administratorUsername",
            "SSH authentication: the embedded public key only",
            "Password authentication over SSH: disabled",
            "Tailscale: enrolled in unattended mode as $computerName",
            "Local password: retained only in the recovery report on the build Mac",
            "Activation: no product key was injected; Windows may use the device's existing digital or firmware license."
        ) | Set-Content -LiteralPath $remoteReady -Encoding UTF8
        Remove-RemoteSetupSecrets
    }

    if ($wifiConfigured) {
        Remove-Item -LiteralPath (Join-Path $config "wifi-ssid") -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $wifiProfile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $state "last-error.txt") -Force -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName "$appPrefix-Provision" -Confirm:$false -ErrorAction SilentlyContinue
    } else {
        Write-Warning "SSH is ready over Ethernet. The startup task remains registered to retry Wi-Fi."
    }
} catch {
    Set-Content `
        -LiteralPath (Join-Path $state "last-error.txt") `
        -Value $_.Exception.ToString() `
        -Encoding UTF8
    Write-Warning $_.Exception.ToString()
    exit 1
} finally {
    try {
        Stop-Transcript
    } finally {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}
