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
    & $FilePath @ArgumentList
    if ($LASTEXITCODE -notin @(0, 1641, 3010)) {
        throw "$FilePath exited with code $LASTEXITCODE"
    }
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Version,
        [ValidateSet("user", "machine")][string]$Scope
    )

    $listOutput = & winget.exe list `
        --id $Id `
        --exact `
        --accept-source-agreements `
        --disable-interactivity 2>&1
    $listText = $listOutput -join "`n"
    $packagePattern = "(?m)\s$([regex]::Escape($Id))\s+$([regex]::Escape($Version))(?:\s|$)"
    if ($LASTEXITCODE -eq 0 -and $listText -match $packagePattern) {
        Write-Host "$Id $Version is already installed."
        return
    }
    if ($LASTEXITCODE -eq 0 -and $listText -match "\s$([regex]::Escape($Id))\s+") {
        throw "$Id is installed at a version other than required $Version"
    }

    $arguments = @(
        "install",
        "--id", $Id,
        "--exact",
        "--version", $Version,
        "--silent",
        "--accept-source-agreements",
        "--accept-package-agreements",
        "--disable-interactivity"
    )
    if ($Scope) {
        $arguments += @("--scope", $Scope)
    }
    Invoke-External winget.exe $arguments
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
    Install-WingetPackage "StablyAI.Orca" $orcaVersion "user"
    Install-WingetPackage "Git.Git" $gitVersion "machine"
    Install-WingetPackage "OpenJS.NodeJS.LTS" $nodeVersion "machine"
    Install-WingetPackage "Python.Python.3.13" $pythonVersion "machine"
    Install-WingetPackage "GitHub.cli" $githubCliVersion "machine"

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
