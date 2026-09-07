#Requires -Version 5.1
<#
    r9view installer for Windows.

        irm https://raw.githubusercontent.com/XPro-Gamer-Rhine/r9view/main/install.ps1 | iex

    Installs the build dependencies, compiles r9view, and puts it in your Start
    Menu with file associations, so it also shows up under "Open with".

    The build toolchain comes from MSYS2, which this installs if it is not there
    already. What lands in the install folder does not depend on it: every DLL
    r9view needs is copied in beside the executable, so the finished app runs on
    a machine with no MSYS2, no Qt and no compiler.

        -Prefix <dir>   where to install    (default %LOCALAPPDATA%\Programs\r9view)
        -MsysRoot <dir> an MSYS2 you already have, instead of looking for one
        -SkipDeps       do not touch pacman; you manage the dependencies yourself
        -NoShortcut     no Start Menu entry
        -NoAssoc        no file associations, no "Open with" entry
        -NoPath         do not put the install folder on your PATH
        -KeepBuild      leave the build tree behind (for working on r9view itself)
        -Uninstall      remove an installed r9view and everything above
#>
[CmdletBinding()]
param(
    [string] $Prefix   = (Join-Path $env:LOCALAPPDATA 'Programs\r9view'),
    [string] $MsysRoot = '',
    [string] $Branch   = 'main',
    [switch] $SkipDeps,
    [switch] $NoShortcut,
    [switch] $NoAssoc,
    [switch] $NoPath,
    [switch] $KeepBuild,
    [switch] $Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # one progress bar per download is noise

$RepoUrl      = 'https://github.com/XPro-Gamer-Rhine/r9view.git'
$UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\r9view'
$CapKey       = 'HKCU:\Software\r9view\Capabilities'
$StartMenu    = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\r9view.lnk'

# Extensions r9view can open. It claims the comic ones outright when nothing else
# has them; the rest it only adds itself to, because quietly taking .zip or .jpg
# away from whatever the user already uses would be rude.
$ComicExt   = @('.cbz', '.cbr', '.cb7', '.cbt')
$ArchiveExt = @('.zip', '.rar', '.7z', '.tar')
$ImageExt   = @('.png', '.jpg', '.jpeg', '.jpe', '.jfif', '.webp', '.avif', '.jxl',
                '.heic', '.heif', '.gif', '.bmp', '.tif', '.tiff', '.psd', '.svg',
                '.ico', '.tga', '.exr', '.qoi', '.dds', '.jp2', '.xcf')

# Three document types rather than one, so the line Windows shows beside a .jpg
# does not read "Comic archive".
$ProgIds = [ordered]@{
    'r9view.comic'   = @{ Label = 'Comic archive'; Extensions = $ComicExt }
    'r9view.archive' = @{ Label = 'Archive';       Extensions = $ArchiveExt }
    'r9view.image'   = @{ Label = 'Image';         Extensions = $ImageExt }
}
$AllProgIds = @($ProgIds.Keys)

# The MSYS2 packages a build needs. kimageformats is what buys avif/heif/jxl/psd
# and the rest of the long tail; without it Qt still reads the common formats.
$Packages = @(
    'mingw-w64-ucrt-x86_64-gcc',
    'mingw-w64-ucrt-x86_64-cmake',
    'mingw-w64-ucrt-x86_64-ninja',
    'mingw-w64-ucrt-x86_64-pkgconf',
    'mingw-w64-ucrt-x86_64-qt6-base',
    'mingw-w64-ucrt-x86_64-qt6-declarative',
    'mingw-w64-ucrt-x86_64-qt6-svg',
    'mingw-w64-ucrt-x86_64-qt6-imageformats',
    'mingw-w64-ucrt-x86_64-qt6-tools',
    'mingw-w64-ucrt-x86_64-kimageformats',
    'mingw-w64-ucrt-x86_64-libarchive'
)

# ------------------------------------------------------------------ output ---

function Write-Step { param([string] $Message) Write-Host '==> ' -ForegroundColor Cyan -NoNewline; Write-Host $Message }
function Write-Note { param([string] $Message) Write-Host '    ' -NoNewline; Write-Host $Message -ForegroundColor DarkGray }
function Write-Warn { param([string] $Message) Write-Host ' warning: ' -ForegroundColor Yellow -NoNewline; Write-Host $Message }
function Stop-Install { param([string] $Message) Write-Host ' error: ' -ForegroundColor Red -NoNewline; Write-Host $Message; exit 1 }

# ------------------------------------------------------------------- msys2 ---

function Find-Msys {
    $candidates = @()
    if ($MsysRoot)        { $candidates += $MsysRoot }
    if ($env:MSYS2_ROOT)  { $candidates += $env:MSYS2_ROOT }
    $candidates += 'C:\msys64'
    $candidates += 'C:\tools\msys64'
    $candidates += (Join-Path $env:LOCALAPPDATA 'Programs\msys64')
    foreach ($c in $candidates) {
        if ($c -and (Test-Path (Join-Path $c 'usr\bin\bash.exe'))) { return (Resolve-Path $c).Path }
    }
    return ''
}

function Install-Msys {
    Write-Step 'installing MSYS2 (the build toolchain lives here)'

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install --id MSYS2.MSYS2 --exact --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Null
        $found = Find-Msys
        if ($found) { return $found }
        Write-Warn 'winget did not leave an MSYS2 we can find; falling back to the installer'
    }

    # No winget, or it put MSYS2 somewhere unexpected: fetch the official
    # installer, which takes a root and installs without asking anything.
    $exe = Join-Path $env:TEMP 'msys2-x86_64-latest.exe'
    Write-Note 'downloading the MSYS2 installer'
    Invoke-WebRequest -UseBasicParsing -OutFile $exe -Uri 'https://github.com/msys2/msys2-installer/releases/latest/download/msys2-x86_64-latest.exe'
    & $exe in --confirm-command --accept-messages --root C:/msys64 | Out-Null
    Remove-Item $exe -Force -ErrorAction SilentlyContinue

    $found = Find-Msys
    if (-not $found) { Stop-Install 'the MSYS2 install did not produce a usable root' }
    return $found
}

# Runs a shell script inside the UCRT64 environment. The script goes through a
# file rather than the command line: quoting a multi-line shell script through
# PowerShell, cmd and bash in turn is a game with no winners.
function Invoke-Msys {
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $Script,
        [string] $What = 'command'
    )
    $tmp = Join-Path $env:TEMP ('r9view-' + [guid]::NewGuid().ToString('N') + '.sh')
    # LF line endings and no BOM: bash reads this, not Notepad.
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($tmp, ($Script -replace "`r`n", "`n"), $utf8)
    try {
        $unix = & (Join-Path $Root 'usr\bin\cygpath.exe') -u $tmp
        $previous = $env:MSYSTEM
        $env:MSYSTEM = 'UCRT64'
        try {
            & (Join-Path $Root 'usr\bin\bash.exe') -lc "bash '$unix'"
            $code = $LASTEXITCODE
        } finally {
            $env:MSYSTEM = $previous
        }
        if ($code -ne 0) { Stop-Install "$What failed (exit $code)" }
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function ConvertTo-MsysPath {
    param([string] $Root, [string] $Path)
    return (& (Join-Path $Root 'usr\bin\cygpath.exe') -u $Path)
}

# ----------------------------------------------------------------- deploy ----

# Copies every non-system DLL the deployed binaries import, following the chain
# outwards. windeployqt knows about Qt and nothing else, so libarchive -- and the
# zstd/lzma/bz2/zlib underneath it, and the avif/heif/jxl libraries behind the
# image plugins -- would otherwise be missing, and the app would die on launch
# naming one DLL at a time.
function Copy-RuntimeDependencies {
    param(
        [Parameter(Mandatory)] [string] $Root,      # the deployed folder
        [Parameter(Mandatory)] [string] $BinDir,    # ucrt64\bin, where the DLLs come from
        [Parameter(Mandatory)] [string] $Objdump
    )

    $seen  = @{}
    $queue = New-Object System.Collections.Queue
    Get-ChildItem -LiteralPath $Root -Recurse -File |
        Where-Object { $_.Extension -eq '.dll' -or $_.Extension -eq '.exe' } |
        ForEach-Object { $queue.Enqueue($_.FullName) }

    $copied = 0
    while ($queue.Count -gt 0) {
        $file = $queue.Dequeue()
        $imports = & $Objdump -p $file 2>$null |
            Select-String -Pattern '^\s*DLL Name:\s*(\S+)' |
            ForEach-Object { $_.Matches[0].Groups[1].Value }

        foreach ($name in $imports) {
            $key = $name.ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true

            $from = Join-Path $BinDir $name
            if (-not (Test-Path -LiteralPath $from)) { continue }   # a Windows system DLL

            $to = Join-Path $Root $name
            if (-not (Test-Path -LiteralPath $to)) {
                Copy-Item -LiteralPath $from -Destination $to -Force
                $copied++
            }
            $queue.Enqueue($to)
        }
    }
    return $copied
}

# ------------------------------------------------------------ integration ----

function New-Shortcut {
    param([string] $Target, [string] $LinkPath)
    $dir = Split-Path -Parent $LinkPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $shell = New-Object -ComObject WScript.Shell
    $link  = $shell.CreateShortcut($LinkPath)
    $link.TargetPath       = $Target
    $link.WorkingDirectory = Split-Path -Parent $Target
    $link.IconLocation     = "$Target,0"
    $link.Description      = 'Image and comic viewer'
    $link.Save()
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
}

function Set-RegValue {
    param([string] $Path, [string] $Name, [string] $Value)
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType String -Force | Out-Null
}

function Get-RegDefault {
    param([string] $Path)
    if (-not (Test-Path $Path)) { return '' }
    $item = Get-ItemProperty -Path $Path -ErrorAction SilentlyContinue
    if (-not $item) { return '' }
    if (-not ($item.PSObject.Properties.Name -contains '(default)')) { return '' }
    return [string] $item.'(default)'
}

# Remove-ItemProperty -Name '(default)' reports success and quietly leaves the
# value in place, which during an uninstall means an extension is left pointing
# at a ProgID that no longer exists -- and a .cbz that no longer opens at all.
# The .NET key does actually delete it.
function Remove-RegDefault {
    param([string] $Path)
    $sub = $Path -replace '^HKCU:\\', '' -replace '^Microsoft\.PowerShell\.Core\\Registry::', '' -replace '^HKEY_CURRENT_USER\\', ''
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($sub, $true)
        if ($key) {
            try { $key.DeleteValue('', $false) } finally { $key.Close() }
        }
    } catch { }
}

function Register-FileTypes {
    param([string] $Exe)

    $classes = 'HKCU:\Software\Classes'
    $command = '"' + $Exe + '" "%1"'
    $all     = $ComicExt + $ArchiveExt + $ImageExt

    # The application entry puts r9view in the "Open with" list for every type it
    # understands, without claiming any of them.
    $appKey = "$classes\Applications\r9view.exe"
    Set-RegValue -Path $appKey -Name 'FriendlyAppName' -Value 'r9view'
    Set-RegValue -Path $appKey -Name 'ApplicationName' -Value 'r9view'
    Set-RegValue -Path $appKey -Name 'ApplicationDescription' -Value 'Image and comic viewer'
    Set-RegValue -Path $appKey -Name 'ApplicationCompany' -Value 'Rhineul Islam'
    Set-RegValue -Path "$appKey\DefaultIcon" -Name '(default)' -Value "$Exe,0"
    Set-RegValue -Path "$appKey\shell\open" -Name 'FriendlyAppName' -Value 'r9view'
    Set-RegValue -Path "$appKey\shell\open\command" -Name '(default)' -Value $command
    if (-not (Test-Path "$appKey\SupportedTypes")) { New-Item -Path "$appKey\SupportedTypes" -Force | Out-Null }
    foreach ($ext in $all) { Set-RegValue -Path "$appKey\SupportedTypes" -Name $ext -Value '' }

    # Real document types, so a .cbz shows the r9view icon rather than a blank
    # page, and so the entry beside a .jpg reads "Image" and not "Comic archive".
    foreach ($progId in $AllProgIds) {
        Set-RegValue -Path "$classes\$progId" -Name '(default)' -Value $ProgIds[$progId].Label
        Set-RegValue -Path "$classes\$progId" -Name 'FriendlyTypeName' -Value $ProgIds[$progId].Label
        Set-RegValue -Path "$classes\$progId\DefaultIcon" -Name '(default)' -Value "$Exe,0"
        Set-RegValue -Path "$classes\$progId\shell\open" -Name 'FriendlyAppName' -Value 'r9view'
        Set-RegValue -Path "$classes\$progId\shell\open\command" -Name '(default)' -Value $command
    }

    foreach ($progId in $AllProgIds) {
        foreach ($ext in $ProgIds[$progId].Extensions) {
            Set-RegValue -Path "$classes\$ext\OpenWithProgids" -Name $progId -Value ''
            # OpenWithList is the older of the two mechanisms and still the one
            # some shell surfaces read, so register both rather than guess.
            if (-not (Test-Path "$classes\$ext\OpenWithList\r9view.exe")) {
                New-Item -Path "$classes\$ext\OpenWithList\r9view.exe" -Force | Out-Null
            }
            # Take the extension itself only for comic formats, and only when it
            # is going spare. Windows will not let anyone but the user change a
            # default they have already chosen, and it should not: this fills a
            # blank, it does not take anything away.
            if ($ComicExt -contains $ext) {
                $existing = Get-RegDefault -Path "$classes\$ext"
                if ([string]::IsNullOrEmpty($existing) -or $existing -eq $progId) {
                    Set-RegValue -Path "$classes\$ext" -Name '(default)' -Value $progId
                }
            }
        }
    }

    # Registered application. This is what lists r9view in Settings -> Default
    # apps as an application in its own right, where a couple of clicks make it
    # the default for a type. Without it r9view is only ever reachable through
    # "Open with -> Choose another app", which is where it was hiding.
    Set-RegValue -Path $CapKey -Name 'ApplicationName' -Value 'r9view'
    Set-RegValue -Path $CapKey -Name 'ApplicationDescription' -Value 'Read comics straight out of a zip, or browse a folder of images'
    Set-RegValue -Path $CapKey -Name 'ApplicationIcon' -Value "$Exe,0"
    foreach ($progId in $AllProgIds) {
        foreach ($ext in $ProgIds[$progId].Extensions) {
            Set-RegValue -Path "$CapKey\FileAssociations" -Name $ext -Value $progId
        }
    }
    Set-RegValue -Path 'HKCU:\Software\RegisteredApplications' -Name 'r9view' -Value 'Software\r9view\Capabilities'

    Update-ShellAssociations
}

function Update-ShellAssociations {
    if (-not ('R9View.Shell' -as [type])) {
        Add-Type -Namespace 'R9View' -Name 'Shell' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll")]
public static extern void SHChangeNotify(int eventId, uint flags, System.IntPtr a, System.IntPtr b);
'@
    }
    # SHCNE_ASSOCCHANGED: tell Explorer to re-read what opens what.
    [R9View.Shell]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
}

function Add-ToUserPath {
    param([string] $Directory)
    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($null -eq $current) { $current = '' }
    $parts = @($current -split ';' | Where-Object { $_ -ne '' })
    foreach ($p in $parts) {
        if ($p.TrimEnd('\') -ieq $Directory.TrimEnd('\')) { return $false }
    }
    [Environment]::SetEnvironmentVariable('Path', (($parts + $Directory) -join ';'), 'User')
    return $true
}

function Remove-FromUserPath {
    param([string] $Directory)
    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ([string]::IsNullOrEmpty($current)) { return }
    $parts = @($current -split ';' | Where-Object { $_ -ne '' -and $_.TrimEnd('\') -ine $Directory.TrimEnd('\') })
    [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
}

# The uninstaller is generated rather than shipped, so that a one-line
# irm | iex install -- which never puts a file on disk -- still leaves one behind.
function Write-Uninstaller {
    param([string] $Target)
    $body = @'
#Requires -Version 5.1
# Removes r9view. Written by the installer; safe to run from anywhere.
$ErrorActionPreference = 'SilentlyContinue'

$prefix   = Split-Path -Parent $MyInvocation.MyCommand.Path
$progIds  = @('r9view.comic', 'r9view.archive', 'r9view.image')
$classes  = 'HKCU:\Software\Classes'
$shortcut = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\r9view.lnk'

# Remove-ItemProperty reports success on a key's unnamed value and leaves it
# there, which would strand .cbz on a ProgID this script is about to delete.
function Remove-RegDefault {
    param([string] $KeyName)   # HKEY_CURRENT_USER\Software\...
    $sub = $KeyName -replace '^HKEY_CURRENT_USER\\', ''
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($sub, $true)
        if ($key) {
            try { $key.DeleteValue('', $false) } finally { $key.Close() }
        }
    } catch { }
}

Get-Process r9view -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 300

Remove-Item $shortcut -Force
Remove-Item (Join-Path ([Environment]::GetFolderPath('Desktop')) 'r9view.lnk') -Force
Remove-Item "$classes\Applications\r9view.exe" -Recurse -Force
foreach ($progId in $progIds) { Remove-Item "$classes\$progId" -Recurse -Force }
Get-ChildItem $classes | Where-Object { $_.PSChildName -like '.*' } | ForEach-Object {
    $owp = Join-Path $_.PSPath 'OpenWithProgids'
    $owl = Join-Path $_.PSPath 'OpenWithList\r9view.exe'
    if (Test-Path $owl) { Remove-Item -Path $owl -Recurse -Force }
    foreach ($progId in $progIds) {
        if (Test-Path $owp) { Remove-ItemProperty -Path $owp -Name $progId -Force }
        $item = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
        if ($item -and $item.PSObject.Properties.Name -contains '(default)') {
            if ([string]$item.'(default)' -eq $progId) { Remove-RegDefault -KeyName $_.Name }
        }
    }
}
Remove-ItemProperty -Path 'HKCU:\Software\RegisteredApplications' -Name 'r9view' -Force
Remove-Item 'HKCU:\Software\r9view' -Recurse -Force
Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\r9view' -Recurse -Force

$path = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($path) {
    $kept = $path -split ';' | Where-Object { $_ -ne '' -and $_.TrimEnd('\') -ine $prefix.TrimEnd('\') }
    [Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'User')
}

Write-Host "r9view removed. Bookmarks and settings are still in $(Join-Path $env:APPDATA 'r9view')"
Write-Host '  (delete that folder too if you want no trace left)'

# This script lives in the folder being deleted and cannot pull the rug from
# under itself, so the last step goes to a detached process.
Start-Process -WindowStyle Hidden powershell -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command',
    "Start-Sleep -Seconds 2; Remove-Item -LiteralPath '$prefix' -Recurse -Force"
)
'@
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Target, $body, $utf8)
}

function Invoke-Uninstall {
    Write-Step "removing r9view from $Prefix"
    Get-Process r9view -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 300

    Remove-Item $StartMenu -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path ([Environment]::GetFolderPath('Desktop')) 'r9view.lnk') -Force -ErrorAction SilentlyContinue
    Remove-Item 'HKCU:\Software\Classes\Applications\r9view.exe' -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($progId in $AllProgIds) {
        Remove-Item "HKCU:\Software\Classes\$progId" -Recurse -Force -ErrorAction SilentlyContinue
    }
    Get-ChildItem 'HKCU:\Software\Classes' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -like '.*' } | ForEach-Object {
            $owp = Join-Path $_.PSPath 'OpenWithProgids'
            $owl = Join-Path $_.PSPath 'OpenWithList\r9view.exe'
            if (Test-Path $owl) { Remove-Item -Path $owl -Recurse -Force -ErrorAction SilentlyContinue }
            foreach ($progId in $AllProgIds) {
                if (Test-Path $owp) { Remove-ItemProperty -Path $owp -Name $progId -Force -ErrorAction SilentlyContinue }
                # An extension still pointing at a ProgID we just deleted is
                # worse than one we never touched: the file becomes unopenable.
                if ((Get-RegDefault -Path $_.PSPath) -eq $progId) {
                    Remove-RegDefault -Path $_.Name
                }
            }
        }
    Remove-ItemProperty -Path 'HKCU:\Software\RegisteredApplications' -Name 'r9view' -Force -ErrorAction SilentlyContinue
    Remove-Item 'HKCU:\Software\r9view' -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $UninstallKey -Recurse -Force -ErrorAction SilentlyContinue
    Remove-FromUserPath -Directory $Prefix
    if (Test-Path $Prefix) { Remove-Item -LiteralPath $Prefix -Recurse -Force -ErrorAction SilentlyContinue }
    Update-ShellAssociations
    Write-Host ''
    Write-Host 'r9view removed.' -ForegroundColor Green
    Write-Note "settings and bookmarks are still in $(Join-Path $env:APPDATA 'r9view')"
    exit 0
}

# ------------------------------------------------------------------- main ----

if ($Uninstall) { Invoke-Uninstall }

if (-not [Environment]::Is64BitOperatingSystem) { Stop-Install 'r9view needs 64-bit Windows' }

# Where the sources are: this checkout if the script is sitting in one, a fresh
# clone otherwise -- which is what the one-line irm | iex install does.
$workdir = ''
$source  = ''
if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'CMakeLists.txt'))) {
    if ((Get-Content (Join-Path $PSScriptRoot 'CMakeLists.txt') -Raw) -match 'project\(r9view') {
        $source = $PSScriptRoot
    }
}

try {
    if (-not $source) {
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            Stop-Install 'git is needed to fetch r9view; install it and re-run'
        }
        $workdir = Join-Path $env:TEMP ('r9view-src-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $workdir -Force | Out-Null
        Write-Step 'fetching r9view'
        git clone --depth 1 --branch $Branch $RepoUrl (Join-Path $workdir 'r9view') 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Stop-Install "could not clone $RepoUrl" }
        $source = Join-Path $workdir 'r9view'
    } else {
        Write-Step "building from $source"
    }

    # -- toolchain ----------------------------------------------------------
    $msys = Find-Msys
    if (-not $msys) {
        if ($SkipDeps) { Stop-Install 'no MSYS2 found, and -SkipDeps says not to install one' }
        $msys = Install-Msys
    }
    Write-Note "MSYS2 at $msys"

    if ($SkipDeps) {
        Write-Step 'SkipDeps set -- leaving pacman alone'
    } else {
        Write-Step 'installing build dependencies (a few hundred MB the first time)'
        # -Syuu first: pacman will not install into a half-updated root, and a
        # freshly installed MSYS2 is always a little behind.
        # "is up to date -- skipping" is pacman telling us it had nothing to do,
        # on stderr, which makes a second run look like it went wrong.
        $quietPacman = @'
run_pacman() {
    log=$(mktemp)
    if ! pacman "$@" >"$log" 2>&1; then cat "$log" >&2; rm -f "$log"; exit 1; fi
    grep -Ei '(warning|error)' "$log" | grep -Ev 'is up to date -- skipping' >&2 || true
    rm -f "$log"
}
'@
        Invoke-Msys -Root $msys -What 'updating MSYS2' -Script "$quietPacman`nrun_pacman -Syuu --noconfirm --needed"
        Invoke-Msys -Root $msys -What 'installing packages' -Script "$quietPacman`nrun_pacman -S --noconfirm --needed $($Packages -join ' ')"
    }

    $ucrtBin = Join-Path $msys 'ucrt64\bin'
    $objdump = Join-Path $ucrtBin 'objdump.exe'
    foreach ($needed in @('cmake.exe', 'ninja.exe', 'windeployqt.exe', 'objdump.exe')) {
        if (-not (Test-Path (Join-Path $ucrtBin $needed))) {
            Stop-Install "$needed is missing from $ucrtBin -- run again without -SkipDeps"
        }
    }

    # -- build --------------------------------------------------------------
    $build = Join-Path $source 'build-windows'
    $stage = Join-Path $env:TEMP ('r9view-stage-' + [guid]::NewGuid().ToString('N'))

    Write-Step 'compiling (this takes a minute)'
    $srcUnix   = ConvertTo-MsysPath -Root $msys -Path $source
    $buildUnix = ConvertTo-MsysPath -Root $msys -Path $build
    $stageUnix = ConvertTo-MsysPath -Root $msys -Path $stage

    Invoke-Msys -Root $msys -What 'the build' -Script @"
set -e
cmake -S '$srcUnix' -B '$buildUnix' -G Ninja -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build '$buildUnix' --parallel
rm -rf '$stageUnix'
cmake --install '$buildUnix' --prefix '$stageUnix' >/dev/null
"@

    if (-not (Test-Path (Join-Path $stage 'r9view.exe'))) { Stop-Install 'the build produced no r9view.exe' }

    # -- deploy -------------------------------------------------------------
    Write-Step 'collecting Qt and the libraries r9view loads'
    # windeployqt always grumbles about the translation catalogue it was just
    # told to skip, and about a Direct3D 12 compiler this app never asks for.
    # Neither is a problem, and neither should look like one.
    Invoke-Msys -Root $msys -What 'windeployqt' -Script @"
log=`$(mktemp)
if ! windeployqt --release --no-translations --compiler-runtime --qmldir '$srcUnix/qml' '$stageUnix/r9view.exe' >"`$log" 2>&1; then
    cat "`$log" >&2; rm -f "`$log"; exit 1
fi
grep -Ei '(warning|error)' "`$log" | grep -Ev 'catalogs\.json|Translations will not be available|dxcompiler\.dll' >&2 || true
rm -f "`$log"
"@
    # Without this Qt measures its plugin and QML paths from the layout of the
    # machine that built it, and the deployed app cannot find its own QtQuick.
    Copy-Item (Join-Path $source 'packaging\windows\qt.conf') (Join-Path $stage 'qt.conf') -Force

    $extra = Copy-RuntimeDependencies -Root $stage -BinDir $ucrtBin -Objdump $objdump
    Write-Note "$extra libraries beyond Qt (libarchive, the image codecs, and what those need)"

    Write-Uninstaller -Target (Join-Path $stage 'uninstall.ps1')
    Copy-Item (Join-Path $source 'LICENSE') (Join-Path $stage 'LICENSE') -Force -ErrorAction SilentlyContinue

    # -- install ------------------------------------------------------------
    Write-Step "installing to $Prefix"
    Get-Process r9view -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 300
    if (Test-Path $Prefix) { Remove-Item -LiteralPath $Prefix -Recurse -Force }
    $parent = Split-Path -Parent $Prefix
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Move-Item -LiteralPath $stage -Destination $Prefix -Force

    $exe = Join-Path $Prefix 'r9view.exe'

    if (-not $NoShortcut) { New-Shortcut -Target $exe -LinkPath $StartMenu }
    if (-not $NoAssoc)    { Register-FileTypes -Exe $exe }

    $pathAdded = $false
    if (-not $NoPath) { $pathAdded = Add-ToUserPath -Directory $Prefix }

    $size = (Get-ChildItem -LiteralPath $Prefix -Recurse -File | Measure-Object -Property Length -Sum).Sum
    Set-RegValue -Path $UninstallKey -Name 'DisplayName'     -Value 'r9view'
    Set-RegValue -Path $UninstallKey -Name 'DisplayVersion'  -Value '1.0.0'
    Set-RegValue -Path $UninstallKey -Name 'Publisher'       -Value 'Rhineul Islam'
    Set-RegValue -Path $UninstallKey -Name 'DisplayIcon'     -Value $exe
    Set-RegValue -Path $UninstallKey -Name 'InstallLocation' -Value $Prefix
    Set-RegValue -Path $UninstallKey -Name 'UninstallString' -Value ('powershell -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $Prefix 'uninstall.ps1') + '"')
    New-ItemProperty -Path $UninstallKey -Name 'EstimatedSize' -Value ([int]($size / 1024)) -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $UninstallKey -Name 'NoModify' -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $UninstallKey -Name 'NoRepair' -Value 1 -PropertyType DWord -Force | Out-Null

    if (-not $KeepBuild) { Remove-Item -LiteralPath $build -Recurse -Force -ErrorAction SilentlyContinue }

    Write-Host ''
    Write-Host 'r9view is installed.' -ForegroundColor Green
    Write-Host "  r9view $env:USERPROFILE\Downloads\some-comic.cbz   open an archive"
    Write-Host "  r9view $env:USERPROFILE\Pictures                   open a folder"
    Write-Host '  r9view photo.jpg                                  open one image (and its folder)'
    Write-Host ''
    if (-not $NoShortcut) { Write-Note 'in the Start Menu as r9view' }
    if (-not $NoAssoc) {
        Write-Note 'right-click a comic or an image -> Open with -> r9view'
        Write-Note 'to make it the default for a type: Settings -> Apps -> Default apps -> r9view'
    }
    if ($pathAdded)       { Write-Warn 'open a new terminal before the r9view command works there' }
} finally {
    if ($workdir -and (Test-Path $workdir)) {
        Remove-Item -LiteralPath $workdir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
