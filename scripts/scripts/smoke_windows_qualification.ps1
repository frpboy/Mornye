# Fresh hosted-runner install/launch evidence only. Never run on a user PC.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Installer,
    [ValidateSet('x64', 'arm64')][string]$Arch = 'x64'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_OS -ne 'Windows' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Run only on a disposable Windows GitHub Actions runner.'
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$evidence = Join-Path $PWD 'build\desktop'
function Capture-Screen([string]$Name) {
    $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bitmap = [System.Drawing.Bitmap]::new($bounds.Width, $bounds.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
        $bitmap.Save((Join-Path $evidence "smoke-$Arch-$Name.png"))
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}
function Wait-Window([System.Diagnostics.Process]$Process) {
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $Process.Refresh()
        if ($Process.HasExited) { throw "Process exited before showing a window: $($Process.ExitCode)" }
        if ($Process.MainWindowHandle -ne 0) { return }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'No visible process window within 30 seconds.'
}
# Inno Setup may relaunch into a temporary *.tmp child. Terminate all
# installer-name processes on this disposable runner before silent install.
$installerStem = [IO.Path]::GetFileNameWithoutExtension($Installer)
function Stop-InstallerProcesses {
    Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -eq $installerStem -or $_.ProcessName.StartsWith("$installerStem.tmp")
    } | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    if (Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -eq $installerStem -or $_.ProcessName.StartsWith("$installerStem.tmp")
    }) { throw 'Installer processes remain after wizard cleanup.' }
}
$wizard = Start-Process -FilePath $Installer -ArgumentList '/SP-', '/NORESTART' -PassThru
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    $visibleWizard = $null
    do {
        $visibleWizard = Get-Process -ErrorAction SilentlyContinue | Where-Object {
            ($_.ProcessName -eq $installerStem -or $_.ProcessName.StartsWith("$installerStem.tmp")) -and $_.MainWindowHandle -ne 0
        } | Select-Object -First 1
        if ($visibleWizard) { break }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $visibleWizard) { throw 'No installer or relaunched installer window within 30 seconds.' }
    Start-Sleep -Seconds 2
    Capture-Screen 'installer'
} finally {
    Stop-InstallerProcesses
}
$installDir = Join-Path $env:RUNNER_TEMP "mornye-qualification-$Arch"
$installLog = Join-Path $evidence "install-$Arch.log"
$install = Start-Process -FilePath $Installer -ArgumentList '/VERYSILENT', '/SP-', '/SUPPRESSMSGBOXES', '/NORESTART', "/DIR=`"$installDir`"", "/LOG=`"$installLog`"" -PassThru
if (-not $install.WaitForExit(120000)) { Stop-Process -Id $install.Id -Force; throw 'Installer exceeded 120 seconds.' }
if ($install.ExitCode -ne 0) { throw "Installer failed: $($install.ExitCode)" }
./scripts/check_windows_bundle.ps1 -BundleDir $installDir -Arch $Arch
$app = Start-Process -FilePath (Join-Path $installDir 'mornye.exe') -PassThru
try {
    Wait-Window $app
    Start-Sleep -Seconds 5
    $app.Refresh()
    if ($app.HasExited) { throw 'Installed app exited before screenshot.' }
    Capture-Screen 'installed-app-5s'
    # Startup update checks use a 10-second HTTP timeout and can show prompts.
    # Capture again after that window without clicking or accepting anything.
    Start-Sleep -Seconds 15
    $app.Refresh()
    if ($app.HasExited) { throw 'Installed app exited during startup prompt observation.' }
    Capture-Screen 'installed-app-20s'
    @{
        source = (git rev-parse HEAD)
        architecture = $Arch
        installerExitCode = $install.ExitCode
        appWindowTitle = $app.MainWindowTitle
        appWindowHandle = $app.MainWindowHandle.ToInt64()
        scope = 'Fresh-runner install and startup only. Pixels still require review; no audio, artwork or user-PC runtime claim.'
    } | ConvertTo-Json | Set-Content (Join-Path $evidence "smoke-$Arch.json")
} finally {
    if (-not $app.HasExited) { Stop-Process -Id $app.Id -Force }
}
