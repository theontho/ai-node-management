[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$WorkerPasswordFile,
    [Parameter(Mandatory = $true)][string]$PairingAddress,
    [ValidateRange(1024, 65535)][int]$Port = 6768
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$orcaVersion = "1.4.196"
$gitVersion = "2.55.0.3"
$nodeVersion = "24.19.0"
$pythonVersion = "3.13.15"
$githubCliVersion = "2.100.0"
$copilotCliVersion = "1.0.82"
$orcaInstallerUrl = "https://github.com/stablyai/orca/releases/download/v$orcaVersion/orca-windows-setup.exe"
$orcaInstallerSha256 = "07D66D4177116F80F4AA1AF89C0BDADCC467DF2310DFF962C5F85298F8B8CF91"
$gitInstallerUrl = "https://github.com/git-for-windows/git/releases/download/v2.55.0.windows.3/Git-2.55.0.3-64-bit.exe"
$gitInstallerSha256 = "AF12577D0FDFF74243A5988197AA49B957D5044EDC17004F6DDF0768996F1DCA"
$nodeInstallerUrl = "https://nodejs.org/dist/v$nodeVersion/node-v$nodeVersion-x64.msi"
$nodeInstallerSha256 = "F0F66C2A80C08A30A5AB5179EE9EA9E45F9B46289436A8CC87FF833B852DB351"
$pythonInstallerUrl = "https://www.python.org/ftp/python/$pythonVersion/python-$pythonVersion-amd64.exe"
$pythonInstallerSha256 = "EDEC09C4853AEAE9AC36EFB8C9F95B6B8E2FEE65EEE56D9767A8B7C69C574403"
$githubCliInstallerUrl = "https://github.com/cli/cli/releases/download/v$githubCliVersion/gh_$($githubCliVersion)_windows_amd64.msi"
$githubCliInstallerSha256 = "989CDDA347F142CFA33C4457BE5FEC6C2E283A9A65525ADE49A36D2A6CDDB276"
$workerName = "orca-worker"
$taskName = "OrcaDevbox-Serve"
$firewallRuleName = "Orca Devbox Runtime"
$root = "C:\ProgramData\OrcaDevbox"
$workspaceRoot = "C:\Orca\workspaces"
$toolsRoot = Join-Path $root "tools"
$serveScript = Join-Path $root "serve.ps1"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-External {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )

    Write-Host "Running: $FilePath $($ArgumentList -join ' ')"
    $process = Start-Process `
        -FilePath $FilePath `
        -ArgumentList $ArgumentList `
        -Wait `
        -PassThru
    if ($process.ExitCode -notin @(0, 1641, 3010)) {
        throw "$FilePath exited with code $($process.ExitCode)"
    }
}

function Get-VerifiedInstaller {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Sha256,
        [Parameter(Mandatory = $true)][string]$FileName
    )

    $downloadRoot = Join-Path $PSScriptRoot "packages"
    $installer = Join-Path $downloadRoot $FileName
    $partial = "$installer.partial"
    New-Item -ItemType Directory -Force -Path $downloadRoot | Out-Null
    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue

    if (Test-Path -LiteralPath $installer -PathType Leaf) {
        $actualSha256 = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash
        if ($actualSha256 -eq $Sha256) {
            return $installer
        }
        Remove-Item -LiteralPath $installer -Force
    }

    Write-Host "Downloading $Name from $Uri"
    Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $partial
    $actualSha256 = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash
    if ($actualSha256 -ne $Sha256) {
        Remove-Item -LiteralPath $partial -Force
        throw "$Name checksum mismatch: expected $Sha256, got $actualSha256"
    }
    Move-Item -LiteralPath $partial -Destination $installer
    return $installer
}

function Grant-BatchLogonRight {
    param(
        [Parameter(Mandatory = $true)][string]$Sid
    )

    $policyId = [Guid]::NewGuid().ToString("N")
    $policyFile = Join-Path $env:TEMP "orca-devbox-$policyId.inf"
    $policyDatabase = Join-Path $env:TEMP "orca-devbox-$policyId.sdb"
    try {
        Invoke-External secedit.exe @(
            "/export",
            "/cfg", $policyFile,
            "/areas", "USER_RIGHTS",
            "/quiet"
        )
        $lines = @(Get-Content -LiteralPath $policyFile -Encoding Unicode)
        $lineIndex = -1
        for ($index = 0; $index -lt $lines.Count; $index++) {
            if ($lines[$index] -match "^SeBatchLogonRight\s*=") {
                $lineIndex = $index
                break
            }
        }
        if ($lineIndex -lt 0) {
            throw "Exported security policy is missing SeBatchLogonRight"
        }

        $entries = @(
            ($lines[$lineIndex] -split "=", 2)[1] -split "," |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ }
        )
        $sidEntry = "*$Sid"
        if ($entries -notcontains $sidEntry) {
            $entries += $sidEntry
            $lines[$lineIndex] = "SeBatchLogonRight = $($entries -join ',')"
            Set-Content `
                -LiteralPath $policyFile `
                -Value $lines `
                -Encoding Unicode
            Invoke-External secedit.exe @(
                "/configure",
                "/db", $policyDatabase,
                "/cfg", $policyFile,
                "/areas", "USER_RIGHTS",
                "/quiet"
            )
        }
    } finally {
        Remove-Item `
            -LiteralPath $policyFile, $policyDatabase `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

if (-not (Test-IsAdministrator)) {
    throw "install.ps1 must run in an elevated PowerShell session"
}
if ($PairingAddress -notmatch "^[A-Za-z0-9.-]+$") {
    throw "PairingAddress must be a hostname or IP address"
}
if (-not (Test-Path -LiteralPath $WorkerPasswordFile -PathType Leaf)) {
    throw "Worker password file does not exist: $WorkerPasswordFile"
}

$workerPassword = (Get-Content -LiteralPath $WorkerPasswordFile -Raw).Trim()
if ($workerPassword -notmatch "^[0-9a-f]{48}$") {
    throw "Worker password must contain exactly 48 lowercase hexadecimal characters"
}

try {
    $orcaInstaller = Get-VerifiedInstaller `
        -Name "Orca $orcaVersion" `
        -Uri $orcaInstallerUrl `
        -Sha256 $orcaInstallerSha256 `
        -FileName "orca-windows-setup.exe"
    $gitInstaller = Get-VerifiedInstaller `
        -Name "Git $gitVersion" `
        -Uri $gitInstallerUrl `
        -Sha256 $gitInstallerSha256 `
        -FileName "git-setup.exe"
    $nodeInstaller = Get-VerifiedInstaller `
        -Name "Node.js $nodeVersion" `
        -Uri $nodeInstallerUrl `
        -Sha256 $nodeInstallerSha256 `
        -FileName "node-setup.msi"
    $pythonInstaller = Get-VerifiedInstaller `
        -Name "Python $pythonVersion" `
        -Uri $pythonInstallerUrl `
        -Sha256 $pythonInstallerSha256 `
        -FileName "python-setup.exe"
    $githubCliInstaller = Get-VerifiedInstaller `
        -Name "GitHub CLI $githubCliVersion" `
        -Uri $githubCliInstallerUrl `
        -Sha256 $githubCliInstallerSha256 `
        -FileName "github-cli-setup.msi"

    Invoke-External $orcaInstaller @("/S")
    Invoke-External $gitInstaller @(
        "/SP-",
        "/VERYSILENT",
        "/SUPPRESSMSGBOXES",
        "/NORESTART",
        "/ALLUSERS"
    )
    Invoke-External msiexec.exe @("/i", $nodeInstaller, "/qn", "/norestart")
    Invoke-External $pythonInstaller @(
        "/quiet",
        "InstallAllUsers=1",
        "PrependPath=1",
        "Include_test=0"
    )
    Invoke-External msiexec.exe @("/i", $githubCliInstaller, "/qn", "/norestart")

    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machinePath;$userPath;$toolsRoot"

    $npm = "C:\Program Files\nodejs\npm.cmd"
    if (-not (Test-Path -LiteralPath $npm -PathType Leaf)) {
        throw "Node.js did not install npm at $npm"
    }
    Invoke-External $npm @(
        "install",
        "--global",
        "--prefix", $toolsRoot,
        "@github/copilot@$copilotCliVersion"
    )

    $securePassword = ConvertTo-SecureString $workerPassword -AsPlainText -Force
    $worker = Get-LocalUser -Name $workerName -ErrorAction SilentlyContinue
    if ($worker) {
        Set-LocalUser `
            -Name $workerName `
            -Password $securePassword `
            -PasswordNeverExpires $true `
            -UserMayChangePassword $false
    } else {
        $worker = New-LocalUser `
            -Name $workerName `
            -Password $securePassword `
            -PasswordNeverExpires `
            -UserMayNotChangePassword `
            -Description "Unprivileged Orca runtime and agent account"
    }

    $usersGroup = Get-LocalGroup -SID "S-1-5-32-545"
    $isUser = Get-LocalGroupMember -Group $usersGroup -ErrorAction SilentlyContinue |
        Where-Object { $_.SID.Value -eq $worker.SID.Value }
    if (-not $isUser) {
        Add-LocalGroupMember -Group $usersGroup -Member $worker
    }

    $administratorsGroup = Get-LocalGroup -SID "S-1-5-32-544"
    $isAdministrator = Get-LocalGroupMember -Group $administratorsGroup |
        Where-Object { $_.SID.Value -eq $worker.SID.Value }
    if ($isAdministrator) {
        throw "$workerName must not be a member of the local Administrators group"
    }
    Grant-BatchLogonRight $worker.SID.Value

    New-Item -ItemType Directory -Force -Path $root, $workspaceRoot, $toolsRoot | Out-Null
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existingTask -and $existingTask.State -eq "Running") {
        Stop-ScheduledTask -TaskName $taskName
    }
    $runtimeProcesses = @(
        Get-CimInstance Win32_Process |
            Where-Object {
                $_.ExecutablePath -and
                $_.ExecutablePath.StartsWith(
                    (Join-Path $root "app"),
                    [StringComparison]::OrdinalIgnoreCase
                )
            }
    )
    if ($runtimeProcesses) {
        $runtimeProcesses | ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop
        }
        for ($attempt = 1; $attempt -le 30; $attempt++) {
            if (-not (Get-NetTCPConnection `
                -State Listen `
                -LocalPort $Port `
                -ErrorAction SilentlyContinue)) {
                break
            }
            Start-Sleep -Seconds 1
        }
        if (Get-NetTCPConnection `
            -State Listen `
            -LocalPort $Port `
            -ErrorAction SilentlyContinue) {
            throw "Existing Orca runtime did not stop cleanly"
        }
    }

    $orcaSource = Join-Path $env:LOCALAPPDATA "Programs\orca"
    $orcaDestination = Join-Path $root "app"
    if (-not (Test-Path -LiteralPath (Join-Path $orcaSource "resources\bin\orca.exe"))) {
        throw "Orca CLI was not found under $orcaSource"
    }
    New-Item -ItemType Directory -Force -Path $orcaDestination | Out-Null
    & robocopy.exe $orcaSource $orcaDestination /MIR /R:2 /W:2 /NFL /NDL /NJH /NJS /NP
    if ($LASTEXITCODE -gt 7) {
        throw "robocopy.exe exited with code $LASTEXITCODE"
    }

    Copy-Item `
        -LiteralPath (Join-Path $PSScriptRoot "serve.ps1") `
        -Destination $serveScript `
        -Force

    @{
        PairingAddress = $PairingAddress
        Port = $Port
        WorkspaceRoot = $workspaceRoot
    } |
        ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $root "config.json") -Encoding UTF8

    $workerSid = $worker.SID.Value
    Invoke-External icacls.exe @(
        $root,
        "/inheritance:r",
        "/grant:r",
        "*S-1-5-18:(OI)(CI)F",
        "*S-1-5-32-544:(OI)(CI)F",
        "*${workerSid}:(OI)(CI)M"
    )
    Invoke-External icacls.exe @(
        "C:\Orca",
        "/inheritance:r",
        "/grant:r",
        "*S-1-5-18:(OI)(CI)F",
        "*S-1-5-32-544:(OI)(CI)F",
        "*${workerSid}:(OI)(CI)M"
    )

    $existingRule = Get-NetFirewallRule `
        -DisplayName $firewallRuleName `
        -ErrorAction SilentlyContinue
    if ($existingRule) {
        $existingRule | Remove-NetFirewallRule
    }
    New-NetFirewallRule `
        -DisplayName $firewallRuleName `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalPort $Port `
        -Profile Any `
        -RemoteAddress LocalSubnet | Out-Null

    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $action = New-ScheduledTaskAction `
        -Execute $powerShell `
        -Argument "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$serveScript`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 999 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -StartWhenAvailable
    $taskUser = "$env:COMPUTERNAME\$workerName"
    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -User $taskUser `
        -Password $workerPassword `
        -RunLevel Limited `
        -Force | Out-Null

    $registeredTask = Get-ScheduledTask -TaskName $taskName
    if ($registeredTask.State -ne "Running") {
        Start-ScheduledTask -TaskName $taskName
    }
    for ($attempt = 1; $attempt -le 60; $attempt++) {
        $listener = Get-NetTCPConnection `
            -State Listen `
            -LocalPort $Port `
            -ErrorAction SilentlyContinue
        if ($listener) {
            break
        }
        Start-Sleep -Seconds 2
    }
    if (-not $listener) {
        $task = Get-ScheduledTaskInfo -TaskName $taskName
        throw "Orca did not listen on port $Port; task result is $($task.LastTaskResult)"
    }

    foreach ($command in @("git.exe", "node.exe", "python.exe", "gh.exe")) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "Required development command is unavailable: $command"
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $toolsRoot "copilot.cmd"))) {
        throw "Copilot CLI was not installed under $toolsRoot"
    }

    Write-Host "Orca devbox runtime is listening on $PairingAddress`:$Port."
    Write-Host "Runtime account: $workerName (non-administrator)"
    Write-Host "Workspace root: $workspaceRoot"
} finally {
    Remove-Item -LiteralPath $WorkerPasswordFile -Force -ErrorAction SilentlyContinue
}
