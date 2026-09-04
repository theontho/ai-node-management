$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$appPrefix = "__APP_PREFIX_PS__"
$computerName = "__COMPUTER_NAME_PS__"
$administratorUsername = "__ADMIN_USERNAME_PS__"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    $quotedScript = '"' + $PSCommandPath.Replace('"', '\"') + '"'
    $arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File $quotedScript"
    $process = Start-Process `
        -FilePath "powershell.exe" `
        -ArgumentList $arguments `
        -Verb RunAs `
        -Wait `
        -PassThru
    exit $process.ExitCode
}

$sourceRoot = Split-Path -Parent $PSCommandPath
$manifest = Join-Path $sourceRoot "manifest.sha256"

foreach ($line in Get-Content -LiteralPath $manifest) {
    if ($line -notmatch "^([0-9a-f]{64})  (.+)$") {
        throw "Invalid payload manifest line: $line"
    }

    $expectedHash = $Matches[1]
    $relativePath = $Matches[2]
    $payloadPath = Join-Path $sourceRoot $relativePath
    $actualHash = (Get-FileHash -LiteralPath $payloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
        throw "Payload integrity check failed for $relativePath"
    }
}

if ($env:COMPUTERNAME -ne $computerName) {
    throw "This payload targets $computerName, not $env:COMPUTERNAME"
}

$administrator = Get-LocalUser -Name $administratorUsername -ErrorAction Stop
$administrators = Get-LocalGroup -SID "S-1-5-32-544"
$isAdministrator = Get-LocalGroupMember -Group $administrators |
    Where-Object { $_.SID.Value -eq $administrator.SID.Value }
if (-not $isAdministrator) {
    throw "$administratorUsername is not a member of the local Administrators group"
}

$destinationRoot = Join-Path $env:ProgramData $appPrefix
$remoteReady = Join-Path $destinationRoot "state\remote-ready.txt"
if (Test-Path -LiteralPath $remoteReady) {
    throw "$destinationRoot is already provisioned"
}

$existingTask = Get-ScheduledTask -TaskName "$appPrefix-Provision" -ErrorAction SilentlyContinue
if ($existingTask) {
    Stop-ScheduledTask -TaskName "$appPrefix-Provision" -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName "$appPrefix-Provision" -Confirm:$false
}

if (-not (Get-Service -Name sshd -ErrorAction SilentlyContinue)) {
    $winget = Get-Command winget.exe -ErrorAction Stop
    $wingetArguments = @(
        "install",
        "--id", "Microsoft.OpenSSH.Preview",
        "--exact",
        "--source", "winget",
        "--silent",
        "--accept-package-agreements",
        "--accept-source-agreements",
        "--disable-interactivity"
    )
    $wingetProcess = Start-Process `
        -FilePath $winget.Source `
        -ArgumentList $wingetArguments `
        -Wait `
        -PassThru
    if ($wingetProcess.ExitCode -ne 0) {
        throw "WinGet could not install OpenSSH (exit code $($wingetProcess.ExitCode))"
    }
}

$destinationConfig = Join-Path $destinationRoot "config"
New-Item -ItemType Directory -Force -Path $destinationConfig | Out-Null
Copy-Item `
    -LiteralPath (Join-Path $sourceRoot "provision.ps1") `
    -Destination (Join-Path $destinationRoot "provision.ps1") `
    -Force
Copy-Item `
    -LiteralPath (Join-Path $sourceRoot "config\ssh-public-key") `
    -Destination (Join-Path $destinationConfig "ssh-public-key") `
    -Force

& icacls.exe `
    $destinationRoot `
    /inheritance:r `
    /grant:r "SYSTEM:(OI)(CI)F" `
    "Administrators:(OI)(CI)F"
if ($LASTEXITCODE -ne 0) {
    throw "Could not secure $destinationRoot"
}

& cmd.exe /d /c (Join-Path $sourceRoot "SetupComplete.cmd")
if ($LASTEXITCODE -ne 0) {
    throw "Could not start the provisioning task"
}

Write-Host ""
Write-Host "AI node provisioning started."
Write-Host "The task retries every five minutes until SSH configuration is ready."
Write-Host "Status: $destinationRoot\state"
Write-Host "Log:    $destinationRoot\provision.log"
