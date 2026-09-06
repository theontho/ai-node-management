[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$WorkerPasswordFile,
    [ValidateRange(1024, 65535)][int]$Port = 6768
)

$ErrorActionPreference = "Stop"
$workerName = "orca-worker"
$taskName = "OrcaDevbox-Serve"
$dashboardFirewallRuleName = "Reddit archive progress dashboard"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    throw "elevate-worker.ps1 must run in an elevated PowerShell session"
}
if (-not (Test-Path -LiteralPath $WorkerPasswordFile -PathType Leaf)) {
    throw "Worker password file does not exist: $WorkerPasswordFile"
}

$workerPassword = (Get-Content -LiteralPath $WorkerPasswordFile -Raw).Trim()
if ($workerPassword -notmatch "^[0-9a-f]{48}$") {
    throw "Worker password must contain exactly 48 lowercase hexadecimal characters"
}

try {
    $worker = Get-LocalUser -Name $workerName -ErrorAction Stop
    $administratorsGroup = Get-LocalGroup -SID "S-1-5-32-544"
    $isAdministrator = Get-LocalGroupMember -Group $administratorsGroup |
        Where-Object { $_.SID.Value -eq $worker.SID.Value }
    if (-not $isAdministrator) {
        Add-LocalGroupMember -Group $administratorsGroup -Member $worker
    }
    Set-LocalUser `
        -Name $workerName `
        -Description "Administrative Orca runtime and agent account"

    Get-NetFirewallRule `
        -DisplayName $dashboardFirewallRuleName `
        -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule
    New-NetFirewallRule `
        -DisplayName $dashboardFirewallRuleName `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalPort 8765 `
        -Profile Private,Public `
        -RemoteAddress @("LocalSubnet", "100.64.0.0/10") | Out-Null

    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    if ($task.State -eq "Running") {
        Stop-ScheduledTask -TaskName $taskName
    }
    $runtimeProcesses = @(
        Get-CimInstance Win32_Process |
            Where-Object {
                $owner = Invoke-CimMethod `
                    -InputObject $_ `
                    -MethodName GetOwnerSid `
                    -ErrorAction SilentlyContinue
                $owner.Sid -eq $worker.SID.Value
            }
    )
    if ($runtimeProcesses) {
        $runtimeProcesses | ForEach-Object {
            try {
                Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop
            } catch {
                if (Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue) {
                    throw
                }
            }
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
            throw "Existing Orca worker processes did not stop cleanly"
        }
    }

    $taskUser = "$env:COMPUTERNAME\$workerName"
    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $task.Actions `
        -Trigger $task.Triggers `
        -Settings $task.Settings `
        -User $taskUser `
        -Password $workerPassword `
        -RunLevel Highest `
        -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName

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
        $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName
        throw "Orca did not listen on port $Port; task result is $($taskInfo.LastTaskResult)"
    }

    $registeredTask = Get-ScheduledTask -TaskName $taskName
    if ($registeredTask.Principal.RunLevel -ne "Highest") {
        throw "Orca boot task did not retain the highest run level"
    }
    Write-Host "$workerName is an administrator and $taskName runs at highest level."
} finally {
    Remove-Item -LiteralPath $WorkerPasswordFile -Force -ErrorAction SilentlyContinue
}
