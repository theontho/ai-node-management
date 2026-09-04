$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$appPrefix = "__APP_PREFIX_PS__"
$computerName = "__COMPUTER_NAME_PS__"
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

    & netsh.exe wlan add profile "filename=$profile" user=all | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "The Wi-Fi profile could not be imported yet. Ethernet remains available."
        return $false
    }

    & netsh.exe wlan connect name="$ssid" ssid="$ssid" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "The Wi-Fi profile was imported, but association has not completed yet."
    }
    return $true
}

function Install-OpenSshServer {
    if (Get-Service -Name sshd -ErrorAction SilentlyContinue) {
        return
    }

    $capabilityName = "OpenSSH.Server~~~~0.0.1.0"
    for ($attempt = 1; $attempt -le 60; $attempt++) {
        $capability = Get-WindowsCapability -Online -Name $capabilityName
        if ($capability.State -eq "Installed") {
            return
        }

        try {
            Write-Host "Installing Microsoft OpenSSH Server capability, attempt $attempt"
            Add-WindowsCapability -Online -Name $capabilityName | Out-Null
        } catch {
            Write-Warning "OpenSSH installation attempt $attempt failed: $($_.Exception.Message)"
        }

        if ((Get-WindowsCapability -Online -Name $capabilityName).State -eq "Installed") {
            return
        }
        Start-Sleep -Seconds 30
    }
    throw "Microsoft OpenSSH Server could not be installed after 30 minutes"
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
    if (-not (Get-NetFirewallRule -DisplayName $firewallRuleName -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule `
            -DisplayName $firewallRuleName `
            -Direction Inbound `
            -Action Allow `
            -Protocol TCP `
            -LocalPort 22 `
            -Profile Any `
            -RemoteAddress LocalSubnet | Out-Null
    }
}

function Remove-RemoteSetupSecrets {
    foreach ($path in @(
        (Join-Path $config "ssh-public-key"),
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
        Configure-RemoteAdministration
        @(
            "Remote administration is ready.",
            "Host: $computerName",
            "SSH user: $administratorUsername",
            "SSH authentication: the embedded public key only",
            "Password authentication over SSH: disabled",
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
