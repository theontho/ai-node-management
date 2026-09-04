$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$root = "C:\ProgramData\OrcaDevbox"
$config = Get-Content -LiteralPath (Join-Path $root "config.json") -Raw |
    ConvertFrom-Json
$profileRoot = Join-Path $root "profile"
$logRoot = Join-Path $root "logs"
$toolsRoot = Join-Path $root "tools"

$env:USERPROFILE = $profileRoot
$env:HOME = $profileRoot
$env:APPDATA = Join-Path $profileRoot "AppData\Roaming"
$env:LOCALAPPDATA = Join-Path $profileRoot "AppData\Local"
$env:Path = @(
    $toolsRoot,
    "C:\Program Files\Git\cmd",
    "C:\Program Files\nodejs",
    "C:\Program Files\GitHub CLI",
    [Environment]::GetEnvironmentVariable("Path", "Machine")
) -join ";"

New-Item `
    -ItemType Directory `
    -Force `
    -Path $profileRoot, $env:APPDATA, $env:LOCALAPPDATA, $logRoot, $config.WorkspaceRoot |
    Out-Null

$orca = Join-Path $root "app\resources\bin\orca.exe"
if (-not (Test-Path -LiteralPath $orca -PathType Leaf)) {
    throw "Orca CLI is missing: $orca"
}

$log = Join-Path $logRoot "serve.log"
& $orca `
    serve `
    --port $config.Port `
    --pairing-address $config.PairingAddress `
    --json *>> $log
exit $LASTEXITCODE
