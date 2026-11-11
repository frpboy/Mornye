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
# Supplemental target-window render, not a replacement for the full desktop.
# PrintWindow can return blank/stale GPU pixels even on API success. Every
# saved PNG still requires direct visual review; metadata is not a visual pass.
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class MornyeWindowCapture {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
}
'@
function Capture-Window([System.Diagnostics.Process]$Process, [string]$Name) {
    $capture = @{
        method = 'user32 PrintWindow, PW_RENDERFULLCONTENT=2'
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        processId = $null
        windowHandle = $null
        apiSuccess = $false
        saved = $false
        caveat = 'API success is not visual proof. Blank, stale, wrong or obscured pixels do not pass.'
    }
    try {
        $Process.Refresh()
        $capture.processId = $Process.Id
        $handle = $Process.MainWindowHandle
        $capture.windowHandle = $handle.ToInt64()
        $rect = [MornyeWindowCapture+RECT]::new()
        if ($handle -eq 0 -or -not [MornyeWindowCapture]::GetWindowRect($handle, [ref]$rect)) {
            $capture.error = 'No target window rectangle.'
        } else {
            $width = $rect.Right - $rect.Left
            $height = $rect.Bottom - $rect.Top
            $capture.width = $width
            $capture.height = $height
            if ($width -lt 1 -or $height -lt 1 -or $width -gt 16384 -or $height -gt 16384) {
                $capture.error = 'Target window dimensions outside capture bounds.'
            } else {
                $bitmap = [System.Drawing.Bitmap]::new($width, $height)
                $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
                try {
                    $hdc = $graphics.GetHdc()
                    try {
                        $capture.apiSuccess = [MornyeWindowCapture]::PrintWindow($handle, $hdc, 2)
                        if (-not $capture.apiSuccess) { $capture.win32Error = [Runtime.InteropServices.Marshal]::GetLastWin32Error() }
                    } finally {
                        $graphics.ReleaseHdc($hdc)
                    }
                    if ($capture.apiSuccess) {
                        $bitmap.Save((Join-Path $evidence "smoke-$Arch-$Name-window.png"))
                        $capture.saved = $true
                    } else {
                        $capture.error = 'PrintWindow returned false.'
                    }
                } finally {
                    $graphics.Dispose()
                    $bitmap.Dispose()
                }
            }
        }
    } catch {
        $capture.error = $_.Exception.Message
        $capture.saved = $false
    }
    try {
        $capture | ConvertTo-Json | Set-Content (Join-Path $evidence "smoke-$Arch-$Name-window.json")
    } catch {
        Write-Warning "Supplemental target-window capture unavailable; could not save provenance: $($_.Exception.Message)"
    }
}
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
    Capture-Window $visibleWizard 'installer'
} finally {
    Stop-InstallerProcesses
}
$installDir = Join-Path $env:RUNNER_TEMP "mornye-qualification-$Arch"
$installLog = Join-Path $evidence "install-$Arch.log"
$install = Start-Process -FilePath $Installer -ArgumentList '/VERYSILENT', '/SP-', '/SUPPRESSMSGBOXES', '/NORESTART', "/DIR=`"$installDir`"", "/LOG=`"$installLog`"" -PassThru
if (-not $install.WaitForExit(120000)) { Stop-Process -Id $install.Id -Force; throw 'Installer exceeded 120 seconds.' }
if ($install.ExitCode -ne 0) { throw "Installer failed: $($install.ExitCode)" }
# The installed tree also has Inno's generated x86 uninstaller. Verify the
# installed application against the already-audited build, then audit an exact
# copy of that installed payload without treating the uninstaller as app code.
$sourceDir = (Resolve-Path "build\windows\$Arch\runner\Release").Path
$auditDir = Join-Path $env:RUNNER_TEMP "mornye-installed-payload-audit-$Arch"
New-Item -ItemType Directory -Path $auditDir -ErrorAction Stop | Out-Null
$payload = @{}
foreach ($file in Get-ChildItem $sourceDir -Recurse -File -Force) {
    $relative = [IO.Path]::GetRelativePath($sourceDir, $file.FullName)
    $payload[$relative] = $true
    $installed = Join-Path $installDir $relative
    if (-not (Test-Path $installed -PathType Leaf)) { throw "Installed payload missing: $relative" }
    if ((Get-FileHash -Algorithm SHA256 $file.FullName).Hash -cne (Get-FileHash -Algorithm SHA256 $installed).Hash) {
        throw "Installed payload differs from build: $relative"
    }
    $copy = Join-Path $auditDir $relative
    New-Item -ItemType Directory -Force (Split-Path $copy) | Out-Null
    Copy-Item -LiteralPath $installed -Destination $copy
}
foreach ($file in Get-ChildItem $installDir -Recurse -File -Force) {
    $relative = [IO.Path]::GetRelativePath($installDir, $file.FullName)
    if (-not $payload.ContainsKey($relative) -and $relative -cnotin @('unins000.exe', 'unins000.dat')) {
        throw "Unexpected installed file: $relative"
    }
}
foreach ($name in 'unins000.exe', 'unins000.dat') {
    if (-not (Test-Path (Join-Path $installDir $name) -PathType Leaf)) { throw "Missing Inno uninstall file: $name" }
}
$uninstaller = [IO.BinaryReader]::new([IO.File]::OpenRead((Join-Path $installDir 'unins000.exe')))
try {
    if ($uninstaller.ReadUInt16() -ne 0x5A4D) { throw 'Invalid Inno uninstaller DOS header.' }
    $uninstaller.BaseStream.Position = 0x3C
    $offset = $uninstaller.ReadInt32()
    $uninstaller.BaseStream.Position = $offset
    if ($uninstaller.ReadUInt32() -ne 0x00004550 -or $uninstaller.ReadUInt16() -ne 0x014C) {
        throw 'Expected the pinned Inno 6.7.1 x86 uninstaller.'
    }
} finally {
    $uninstaller.Dispose()
}
./scripts/check_windows_bundle.ps1 -BundleDir $auditDir -Arch $Arch
Write-Host "Verified $($payload.Count) installed payload files against the build plus the generated Inno uninstall files."
$app = Start-Process -FilePath (Join-Path $installDir 'mornye.exe') -PassThru
try {
    Wait-Window $app
    Start-Sleep -Seconds 5
    $app.Refresh()
    if ($app.HasExited) { throw 'Installed app exited before screenshot.' }
    Capture-Screen 'installed-app-5s'
    Capture-Window $app 'installed-app-5s'
    # Startup update checks use a 10-second HTTP timeout and can show prompts.
    # Capture again after that window without clicking or accepting anything.
    Start-Sleep -Seconds 15
    $app.Refresh()
    if ($app.HasExited) { throw 'Installed app exited during startup prompt observation.' }
    Capture-Screen 'installed-app-20s'
    Capture-Window $app 'installed-app-20s'
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
