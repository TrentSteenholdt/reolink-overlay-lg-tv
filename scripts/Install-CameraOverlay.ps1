[CmdletBinding()]
param(
    [string] $OutputDirectory = (Join-Path ([System.IO.Path]::GetTempPath()) 'camera-overlay-build'),
    [string] $PackagePath,
    [switch] $Deploy,
    [string] $TvHost,
    [string] $SshKeyPath,
    [string] $KnownHostsPath
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$appDirectory = Join-Path $repositoryRoot 'apps\doorbell-overlay'
$appInfoPath = Join-Path $appDirectory 'appinfo.json'

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [Parameter(Mandatory)] [string[]] $ArgumentList
    )

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE`: $FilePath"
    }
}

if (-not (Test-Path -LiteralPath $appInfoPath -PathType Leaf)) {
    throw "App metadata not found: $appInfoPath"
}

$appInfo = Get-Content -LiteralPath $appInfoPath -Raw | ConvertFrom-Json
if ($appInfo.id -ne 'org.cameraoverlay.lgtv') {
    throw "Unexpected app id in $appInfoPath"
}
if ($appInfo.version -notmatch '^\d+\.\d+\.\d+$') {
    throw "App version must be a numeric x.y.z version; found '$($appInfo.version)'"
}

$packageName = "$($appInfo.id)_$($appInfo.version)_all.ipk"
$resolvedOutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)

if ($PackagePath) {
    $packagePath = [System.IO.Path]::GetFullPath($PackagePath)
    if ([System.IO.Path]::GetFileName($packagePath) -ne $packageName) {
        throw "Package must be named '$packageName' to match appinfo.json."
    }
    if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
        throw "Package file not found: $packagePath"
    }
}
else {
    New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null
    $packagePath = Join-Path $resolvedOutputDirectory $packageName
    if (Test-Path -LiteralPath $packagePath) {
        Remove-Item -LiteralPath $packagePath -Force
    }

    $packageCommand = Get-Command 'ares-package.cmd', 'ares-package' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    $packageCommandPath = if ($packageCommand) { $packageCommand.Source } else { $null }

    if (-not $packageCommandPath -and $env:APPDATA) {
        $userNpmCommand = Join-Path $env:APPDATA 'npm\ares-package.cmd'
        if (Test-Path -LiteralPath $userNpmCommand -PathType Leaf) {
            $packageCommandPath = $userNpmCommand
        }
    }

    if (-not $packageCommandPath) {
        throw 'ares-package is not installed. Install @webos-tools/cli or add its bin directory to PATH.'
    }

    Write-Host "Validating $($appInfo.id) $($appInfo.version)..."
    Invoke-NativeCommand -FilePath $packageCommandPath -ArgumentList @('-c', $appDirectory)

    Write-Host "Packaging to $resolvedOutputDirectory..."
    Invoke-NativeCommand -FilePath $packageCommandPath -ArgumentList @($appDirectory, '-o', $resolvedOutputDirectory)
    if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
        throw "Packaging completed but expected package was not created: $packagePath"
    }
}

Write-Host "Package ready: $packagePath"

if (-not $Deploy) {
    return
}

if (-not $TvHost -or -not $SshKeyPath -or -not $KnownHostsPath) {
    throw 'Deploy requires -TvHost, -SshKeyPath, and -KnownHostsPath.'
}
if ($TvHost -notmatch '^[A-Za-z0-9.-]+$') {
    throw 'TV host must be a hostname or IPv4 address.'
}
if (-not (Test-Path -LiteralPath $SshKeyPath -PathType Leaf)) {
    throw "SSH key not found: $SshKeyPath"
}
if (-not (Test-Path -LiteralPath $KnownHostsPath -PathType Leaf)) {
    throw "Pinned SSH known-hosts file not found: $KnownHostsPath"
}

$systemOpenSsh = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\OpenSSH' } else { $null }
$sshPath = if ($systemOpenSsh -and (Test-Path -LiteralPath (Join-Path $systemOpenSsh 'ssh.exe') -PathType Leaf)) {
    Join-Path $systemOpenSsh 'ssh.exe'
} else {
    (Get-Command 'ssh.exe', 'ssh' -ErrorAction SilentlyContinue | Select-Object -First 1).Source
}
$scpPath = if ($systemOpenSsh -and (Test-Path -LiteralPath (Join-Path $systemOpenSsh 'scp.exe') -PathType Leaf)) {
    Join-Path $systemOpenSsh 'scp.exe'
} else {
    (Get-Command 'scp.exe', 'scp' -ErrorAction SilentlyContinue | Select-Object -First 1).Source
}
if (-not $sshPath -or -not $scpPath) {
    throw 'OpenSSH ssh and scp commands are required for deployment.'
}

$overlayDirectory = '/var/lib/webosbrew/camera-overlay'
$tvAddress = $TvHost
if ($TvHost -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
    try {
        $tvAddress = Resolve-DnsName -Name $TvHost -Type A -ErrorAction Stop |
            Where-Object { $_.IPAddress } |
            Select-Object -ExpandProperty IPAddress -First 1
    }
    catch {
        throw "Could not resolve TV host '$TvHost' to an IPv4 address: $($_.Exception.Message)"
    }
    if (-not $tvAddress) {
        throw "TV host '$TvHost' did not resolve to an IPv4 address."
    }
}
$tvTarget = "root@$tvAddress"
$sshOptions = @(
    '-i', $SshKeyPath,
    '-o', "UserKnownHostsFile=`"$KnownHostsPath`"",
    '-o', "HostKeyAlias=$TvHost",
    '-o', 'StrictHostKeyChecking=yes',
    '-o', 'HostKeyAlgorithms=ssh-ed25519',
    '-o', 'BatchMode=yes',
    '-o', 'ConnectTimeout=10'
)

Write-Host "Uploading overlay package and TV API files to $TvHost ($tvAddress); verifying the pinned key for $TvHost..."
Invoke-NativeCommand -FilePath $sshPath -ArgumentList ($sshOptions + @($tvTarget, 'umask 077; mkdir -p /var/lib/webosbrew/camera-overlay; chmod 700 /var/lib/webosbrew/camera-overlay'))
Invoke-NativeCommand -FilePath $scpPath -ArgumentList ($sshOptions + @(
    (Join-Path $appDirectory 'control'),
    (Join-Path $appDirectory 'producer.py'),
    (Join-Path $repositoryRoot 'apps\tv-api\api-control'),
    (Join-Path $repositoryRoot 'apps\tv-api\api_server.js'),
    "${tvTarget}:$overlayDirectory/"
))
Invoke-NativeCommand -FilePath $scpPath -ArgumentList ($sshOptions + @(
    (Join-Path $repositoryRoot 'apps\tv-api\10-camera-overlay-api'),
    "${tvTarget}:/tmp/10-camera-overlay-api"
))
Invoke-NativeCommand -FilePath $scpPath -ArgumentList ($sshOptions + @(
    (Join-Path $repositoryRoot 'apps\tv-api\api-config.example.json'),
    "${tvTarget}:$overlayDirectory/api-config.example.json"
))
Invoke-NativeCommand -FilePath $scpPath -ArgumentList ($sshOptions + @(
    (Join-Path $appDirectory 'stream.example.json'),
    "${tvTarget}:$overlayDirectory/stream.example.json"
))
Invoke-NativeCommand -FilePath $scpPath -ArgumentList ($sshOptions + @(
    $packagePath,
    "${tvTarget}:/tmp/$packageName"
))

$remoteScript = @'
set -eu
overlay_dir=/var/lib/webosbrew/camera-overlay
package_path=/tmp/__PACKAGE_NAME__
install_log=/tmp/camera-overlay-install.log
chmod 700 "$overlay_dir/control" "$overlay_dir/producer.py" "$overlay_dir/api-control" "$overlay_dir/api_server.js"
mkdir -p /var/lib/webosbrew/init.d
cp /tmp/10-camera-overlay-api /var/lib/webosbrew/init.d/10-camera-overlay-api
chmod 700 /var/lib/webosbrew/init.d/10-camera-overlay-api
chmod 600 "$overlay_dir/api-config.example.json" "$overlay_dir/stream.example.json"

install_request='{"id":"__APP_ID__","ipkUrl":"/tmp/__PACKAGE_NAME__","subscribe":true}'
(luna-send -i -w 60000 -f luna://com.webos.appInstallService/dev/install "$install_request" </dev/null >"$install_log" 2>&1 || true) &
install_pid=$!
installed=0
attempt=0
while [ "$attempt" -lt 90 ]; do
    if grep -Fq '"statusValue": 30' "$install_log" && grep -Fq '"state": "installed"' "$install_log"; then
        installed=1
        break
    fi
    if ! kill -0 "$install_pid" 2>/dev/null && grep -Eiq '"state": "failed"|"statusValue": 31' "$install_log"; then
        break
    fi
    attempt=$((attempt + 1))
    sleep 1
done
if [ "$installed" -ne 1 ]; then
    echo 'webOS app install did not report installed status.' >&2
    tail -n 20 "$install_log" >&2 || true
    exit 1
fi

app_info=$(luna-send -n 1 -f luna://com.webos.applicationManager/getAppInfo '{"id":"__APP_ID__"}' </dev/null)
printf '%s' "$app_info" | grep -Fq '"version": "__APP_VERSION__"' || {
    echo 'Installed app version does not match the package.' >&2
    exit 1
}

"$overlay_dir/api-control" start >/dev/null
rm -f /tmp/10-camera-overlay-api
rm -f "$package_path" "$install_log"
echo "Installed __APP_ID__ version __APP_VERSION__ and checked API service state."
'@
$remoteScript = $remoteScript.Replace('__PACKAGE_NAME__', $packageName).
    Replace('__APP_ID__', [string] $appInfo.id).
    Replace('__APP_VERSION__', [string] $appInfo.version)

Write-Host 'Installing the package and TV API receiver...'
Invoke-NativeCommand -FilePath $sshPath -ArgumentList ($sshOptions + @($tvTarget, $remoteScript))
Write-Host "TV deployment complete: $($appInfo.id) $($appInfo.version) on $TvHost"
