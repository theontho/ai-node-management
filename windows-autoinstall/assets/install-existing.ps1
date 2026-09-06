$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$appPrefix = "__APP_PREFIX_PS__"
$computerNamePrefix = "__COMPUTER_NAME_PREFIX_PS__"
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

if (-not $env:COMPUTERNAME.StartsWith($computerNamePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "This payload targets names beginning with $computerNamePrefix, not $env:COMPUTERNAME"
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

$destinationConfig = Join-Path $destinationRoot "config"
New-Item -ItemType Directory -Force -Path $destinationConfig | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $destinationRoot "packages") | Out-Null
Copy-Item `
    -LiteralPath (Join-Path $sourceRoot "provision.ps1") `
    -Destination (Join-Path $destinationRoot "provision.ps1") `
    -Force
Copy-Item `
    -LiteralPath (Join-Path $sourceRoot "config\ssh-public-key") `
    -Destination (Join-Path $destinationConfig "ssh-public-key") `
    -Force
Copy-Item `
    -LiteralPath (Join-Path $sourceRoot "packages\OpenSSH-Win64.msi") `
    -Destination (Join-Path $destinationRoot "packages\OpenSSH-Win64.msi") `
    -Force
Copy-Item `
    -LiteralPath (Join-Path $sourceRoot "packages\Tailscale-amd64.msi") `
    -Destination (Join-Path $destinationRoot "packages\Tailscale-amd64.msi") `
    -Force
Copy-Item `
    -LiteralPath (Join-Path $sourceRoot "config\tailscale-auth-key") `
    -Destination (Join-Path $destinationConfig "tailscale-auth-key") `
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
