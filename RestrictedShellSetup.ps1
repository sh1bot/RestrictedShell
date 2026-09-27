#requires -version 5.1

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]$identity

if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList (
        '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
    )
    exit
}

if (-not ('RestrictedShell.NativeIcon' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace RestrictedShell
{
    public static class NativeIcon
    {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern uint PrivateExtractIconsW(
            string fileName, int iconIndex, int cxIcon, int cyIcon,
            IntPtr[] iconHandles, uint[] iconIds, uint iconCount, uint flags);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr LoadImageW(
            IntPtr instance, string name, uint type, int cx, int cy, uint loadFlags);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool DestroyIcon(IntPtr icon);
    }
}
'@
}

$here = Split-Path -Parent $PSCommandPath
$installDir = Join-Path $env:ProgramData 'RestrictedShell'
$ini = Join-Path $installDir 'RestrictedShell.ini'
$shell = Join-Path $installDir 'RestrictedShell.exe'
$installedScriptsDir = Join-Path $installDir 'scripts'
$allLocalGroups = @(Get-LocalGroup)

function New-RestrictedFileAcl {
    $acl = [Security.AccessControl.FileSecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)

    foreach ($entry in @(
        @('S-1-5-18', [Security.AccessControl.FileSystemRights]::FullControl),
        @('S-1-5-32-544', [Security.AccessControl.FileSystemRights]::FullControl),
        @('S-1-5-32-545', [Security.AccessControl.FileSystemRights]::ReadAndExecute)
    )) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($entry[0]),
            $entry[1],
            [Security.AccessControl.AccessControlType]::Allow
        ))
    }
    return $acl
}

function Protect-RestrictedFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Set-Acl -LiteralPath $Path -AclObject (New-RestrictedFileAcl)
    }
}

function Protect-RestrictedShellStorage {
    if (-not (Test-Path -LiteralPath $installDir -PathType Container)) {
        return
    }

    $inherit = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)

    foreach ($entry in @(
        @('S-1-5-18', [Security.AccessControl.FileSystemRights]::FullControl),
        @('S-1-5-32-544', [Security.AccessControl.FileSystemRights]::FullControl),
        @('S-1-5-32-545', [Security.AccessControl.FileSystemRights]::ReadAndExecute)
    )) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($entry[0]),
            $entry[1],
            $inherit,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow
        ))
    }

    Set-Acl -LiteralPath $installDir -AclObject $acl
    Protect-RestrictedFile $ini
    Protect-RestrictedFile $shell

    if (Test-Path -LiteralPath $installedScriptsDir -PathType Container) {
        Get-ChildItem -LiteralPath $installedScriptsDir -File -Recurse |
            ForEach-Object { Protect-RestrictedFile $_.FullName }
    }
}

function Get-NativeArchitecture {
    switch ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()) {
        'x86'   { return 'x86' }
        'x64'   { return 'x64' }
        'arm64' { return 'arm64' }
        default { throw 'Unsupported Windows architecture.' }
    }
}

function Read-IniFile {
    param([string]$Path)

    $data = [ordered]@{}
    $section = ''
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $data
    }

    foreach ($line in Get-Content -LiteralPath $Path) {
        $text = $line.Trim()
        if ($text -match '^\[(.+)\]$') {
            $section = $matches[1]
            if (-not $data.Contains($section)) {
                $data[$section] = [ordered]@{}
            }
        }
        elseif ($section -and $text -match '^([^;#][^=]*)=(.*)$') {
            $data[$section][$matches[1].Trim()] = $matches[2]
        }
    }
    return $data
}

function Set-IniValue {
    param($Data, [string]$Section, [string]$Key, $Value)

    if (-not $Data.Contains($Section)) {
        $Data[$Section] = [ordered]@{}
    }
    $Data[$Section][$Key] = [string]$Value
}

function Write-IniFile {
    param($Data)

    $lines = [Collections.Generic.List[string]]::new()
    foreach ($section in $Data.Keys) {
        $lines.Add("[$section]")
        foreach ($key in $Data[$section].Keys) {
            $lines.Add("$key=$($Data[$section][$key])")
        }
        $lines.Add('')
    }

    $temp = Join-Path $installDir ('.RestrictedShell.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllLines($temp, $lines, [Text.UTF8Encoding]::new($false))
        Protect-RestrictedFile $temp

        if (Test-Path -LiteralPath $ini -PathType Leaf) {
            [IO.File]::Replace($temp, $ini, $null)
        }
        else {
            [IO.File]::Move($temp, $ini)
        }
        Protect-RestrictedFile $ini
    }
    finally {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Ensure-IniDefaults {
    $data = Read-IniFile $ini
    $changed = $false
    $defaults = @{
        RestrictedShell = [ordered]@{
            LogoffOnExit = '1'
            BlockShellHotkeys = '1'
            PreventChildProcesses = '0'
            StandardKeyboardVolumeShortcuts = '0'
            PreRunExecutable = ''
            PreRunArguments = ''
            PreRunInterpreter = ''
        }
        AudioDefaults = [ordered]@{
            PublicVolume = '10'
            PrivateVolume = '60'
        }
    }

    foreach ($section in $defaults.Keys) {
        if (-not $data.Contains($section)) {
            $data[$section] = [ordered]@{}
            $changed = $true
        }
        foreach ($key in $defaults[$section].Keys) {
            if (-not $data[$section].Contains($key)) {
                $data[$section][$key] = $defaults[$section][$key]
                $changed = $true
            }
        }
    }

    if ($changed) {
        Write-IniFile $data
    }
}

function Install-RestrictedShell {
    $architecture = Get-NativeArchitecture
    $source = Join-Path $here "bin\$architecture\RestrictedShell.exe"
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Missing $architecture shell binary: $source"
    }

    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    Protect-RestrictedShellStorage
    Copy-Item -LiteralPath $source -Destination $shell -Force

    $packagedScriptsDir = Join-Path $here 'scripts'
    if (Test-Path -LiteralPath $packagedScriptsDir -PathType Container) {
        New-Item -ItemType Directory -Path $installedScriptsDir -Force | Out-Null
        Copy-Item -Path (Join-Path $packagedScriptsDir '*') -Destination $installedScriptsDir -Recurse -Force
    }

    if (-not (Test-Path -LiteralPath $ini -PathType Leaf)) {
        $template = Join-Path $here 'RestrictedShell.ini'
        if (Test-Path -LiteralPath $template -PathType Leaf) {
            Copy-Item -LiteralPath $template -Destination $ini
        }
        else {
            [IO.File]::WriteAllText($ini, "", [Text.UTF8Encoding]::new($false))
        }
    }

    Protect-RestrictedShellStorage
    Ensure-IniDefaults
}

function Resolve-InstalledPreRunPath {
    param([string]$Path)

    if (-not $Path) { return '' }
    $packagedScriptsDir = Join-Path $here 'scripts'
    if (-not (Test-Path -LiteralPath $packagedScriptsDir -PathType Container)) {
        return $Path
    }

    $sourceRoot = [IO.Path]::GetFullPath($packagedScriptsDir).TrimEnd('\') + '\'
    $candidate = [IO.Path]::GetFullPath($Path)
    if ($candidate.StartsWith($sourceRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return Join-Path $installedScriptsDir $candidate.Substring($sourceRoot.Length)
    }
    return $Path
}

function Get-ProfilePath {
    param([string]$Sid)

    $key = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$Sid"
    if (Test-Path $key) {
        return [Environment]::ExpandEnvironmentVariables((Get-ItemProperty $key).ProfileImagePath)
    }
    return $null
}

function Invoke-WithUserHive {
    param([string]$Sid, [string]$Profile, [scriptblock]$Body)

    $loadedHive = "Registry::HKEY_USERS\$Sid"
    if (Test-Path $loadedHive) {
        & $Body $loadedHive
        return
    }

    $mountName = 'RS_' + [guid]::NewGuid().ToString('N')
    & reg.exe load "HKU\$mountName" (Join-Path $Profile 'NTUSER.DAT') | Out-Null
    if ($LASTEXITCODE) { throw 'Could not load user hive.' }

    try {
        & $Body "Registry::HKEY_USERS\$mountName"
    }
    finally {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        & reg.exe unload "HKU\$mountName" | Out-Null
    }
}

function Save-RegistryValue {
    param($Data, [string]$Section, [string]$Path, [string]$Name, [string]$Key)

    $value = Get-ItemProperty $Path -Name $Name -ErrorAction SilentlyContinue
    Set-IniValue $Data $Section $Key $(if ($null -ne $value) { $value.$Name } else { '__MISSING__' })
}

function Restore-RegistryValue {
    param([string]$Path, [string]$Name, $Value, [string]$Type)

    if ($Value -eq '__MISSING__') {
        Remove-ItemProperty $Path -Name $Name -ErrorAction SilentlyContinue
        return
    }
    New-Item $Path -Force | Out-Null
    New-ItemProperty $Path -Name $Name -PropertyType $Type -Value $Value -Force | Out-Null
}

function Restore-AccountFromMetadata {
    param($User, [string]$Profile, $Data, [string]$MetadataSection)

    Invoke-WithUserHive $User.SID.Value $Profile {
        param($hive)
        Restore-RegistryValue `
            (Join-Path $hive 'Software\Microsoft\Windows NT\CurrentVersion\Winlogon') `
            'Shell' $Data[$MetadataSection].PreviousShell 'String'
        Restore-RegistryValue `
            (Join-Path $hive 'Software\Microsoft\Windows\CurrentVersion\Policies\System') `
            'DisableTaskMgr' $Data[$MetadataSection].PreviousDisableTaskMgr 'DWord'
    }

    Set-LocalUser `
        -Name $User.Name `
        -UserMayChangePassword:([bool][int]$Data[$MetadataSection].PreviousUserMayChangePassword) `
        -PasswordNeverExpires:([bool][int]$Data[$MetadataSection].PreviousPasswordNeverExpires)
}

function Get-LocalGroupClosure {
    param([string]$UserSid)

    $sids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [void]$sids.Add($UserSid)
    $changed = $true

    while ($changed) {
        $changed = $false
        foreach ($group in $allLocalGroups) {
            if ($sids.Contains($group.SID.Value)) { continue }
            $members = @(Get-LocalGroupMember -Group $group -ErrorAction SilentlyContinue)
            foreach ($member in $members) {
                if ($member.SID -and $sids.Contains($member.SID.Value)) {
                    [void]$sids.Add($group.SID.Value)
                    $changed = $true
                    break
                }
            }
        }
    }
    return $sids
}

function Get-UserWritablePrincipalSids {
    param([string]$UserSid)

    $sids = Get-LocalGroupClosure $UserSid
    foreach ($sid in @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545')) {
        [void]$sids.Add($sid)
    }
    return $sids
}

function Test-PathWritableByPrincipals {
    param([string]$Path, $PrincipalSids)

    $writeMask = [Security.AccessControl.FileSystemRights]::Write -bor
        [Security.AccessControl.FileSystemRights]::Modify -bor
        [Security.AccessControl.FileSystemRights]::FullControl -bor
        [Security.AccessControl.FileSystemRights]::Delete -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership

    foreach ($candidate in @($Path, (Split-Path -Parent $Path))) {
        if (-not $candidate -or -not (Test-Path -LiteralPath $candidate)) { continue }
        $acl = Get-Acl -LiteralPath $candidate
        foreach ($rule in $acl.Access) {
            if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
            try {
                $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
            }
            catch { continue }
            if ($PrincipalSids.Contains($sid) -and (($rule.FileSystemRights -band $writeMask) -ne 0)) {
                return $true
            }
        }
    }
    return $false
}

function Assert-SecureLaunchPath {
    param([string]$Path, $PrincipalSids, [string]$Description)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description does not exist: $Path"
    }
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (Test-PathWritableByPrincipals $fullPath $PrincipalSids) {
        throw "$Description is writable or replaceable by the restricted user: $fullPath`nChoose a file in an administrator-controlled location such as Program Files or C:\ProgramData\RestrictedShell."
    }
}

function Resolve-PythonInterpreter {
    param([string]$ScriptPath)

    $windowed = [IO.Path]::GetExtension($ScriptPath).Equals('.pyw', [StringComparison]::OrdinalIgnoreCase)
    $names = if ($windowed) { @('pyw.exe', 'pythonw.exe') } else { @('py.exe', 'python.exe') }
    $candidates = [Collections.Generic.List[string]]::new()

    foreach ($name in $names) {
        $candidates.Add((Join-Path $env:WINDIR $name))
    }

    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, 'C:\')) {
        if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($name in $names) {
            Get-ChildItem -LiteralPath $root -Directory -Filter 'Python*' -ErrorAction SilentlyContinue |
                ForEach-Object { $candidates.Add((Join-Path $_.FullName $name)) }
        }
    }

    foreach ($name in $names) {
        $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($command) { $candidates.Add($command.Source) }
    }

    foreach ($candidate in $candidates | Select-Object -Unique) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    throw "No Python interpreter was found for $([IO.Path]::GetExtension($ScriptPath)) pre-run script."
}

function Convert-IconHandleToBitmap {
    param([IntPtr]$Handle)
    if ($Handle -eq [IntPtr]::Zero) { throw 'Windows returned a null icon handle.' }
    $icon = [Drawing.Icon]::FromHandle($Handle)
    try {
        $bitmap = $icon.ToBitmap()
        try { return [Drawing.Bitmap]::new($bitmap) }
        finally { $bitmap.Dispose() }
    }
    finally { $icon.Dispose() }
}

function Get-IcoBitmap {
    param([string]$Path, [int]$Size)
    $handle = [RestrictedShell.NativeIcon]::LoadImageW([IntPtr]::Zero, $Path, 1, $Size, $Size, 0x0010)
    if ($handle -eq [IntPtr]::Zero) {
        throw "LoadImageW could not load a ${Size}x${Size} icon from '$Path'."
    }
    try { return Convert-IconHandleToBitmap $handle }
    finally { [void][RestrictedShell.NativeIcon]::DestroyIcon($handle) }
}

function Get-EmbeddedExeIconBitmap {
    param([string]$Path, [int]$Size)
    $handles = [IntPtr[]]::new(1)
    $ids = [uint32[]]::new(1)
    try {
        $count = [RestrictedShell.NativeIcon]::PrivateExtractIconsW($Path, 0, $Size, $Size, $handles, $ids, 1, 0)
        if ($count -gt 0 -and $count -ne [uint32]::MaxValue -and $handles[0] -ne [IntPtr]::Zero) {
            return Convert-IconHandleToBitmap $handles[0]
        }
        return $null
    }
    finally {
        if ($handles[0] -ne [IntPtr]::Zero) { [void][RestrictedShell.NativeIcon]::DestroyIcon($handles[0]) }
    }
}

function Get-ExeIconBitmap {
    param([string]$Path, [int]$Size)
    try {
        $embedded = Get-EmbeddedExeIconBitmap $Path $Size
        if ($embedded) { return $embedded }
    }
    catch { }

    $icon = [Drawing.Icon]::ExtractAssociatedIcon($Path)
    if (-not $icon) { throw "No icon could be extracted from '$Path'." }
    try {
        $bitmap = $icon.ToBitmap()
        try { return [Drawing.Bitmap]::new($bitmap) }
        finally { $bitmap.Dispose() }
    }
    finally { $icon.Dispose() }
}

function Get-NormalizedBitmapHash {
    param([Drawing.Bitmap]$Bitmap)
    $bytes = New-Object byte[] ($Bitmap.Width * $Bitmap.Height * 4)
    $i = 0
    for ($y = 0; $y -lt $Bitmap.Height; $y++) {
        for ($x = 0; $x -lt $Bitmap.Width; $x++) {
            $p = $Bitmap.GetPixel($x, $y)
            $bytes[$i++] = $p.A; $bytes[$i++] = $p.R; $bytes[$i++] = $p.G; $bytes[$i++] = $p.B
        }
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ($sha.ComputeHash($bytes) | ForEach-Object ToString x2) -join '' }
    finally { $sha.Dispose() }
}

$genericIconSignatures = @(
    @('933f506c84bddc927f19c4890c0b391bad30f59e4c2052607b6e4b6297d1d62f', 'deb5efcddc9c870fb0e8bf3dabd86827e3f369de9ceded75afa98bc0e473e7f6'),
    @('26a47902011dde48fc5e45607ff2dcae0eeb0e71a588830aaeca181808c73fd0', '315add701425584c9e4e069ecd6e437083b597f31bb561b0eae3683387f9ede0'),
    @('5bd97fab4b452d85a5a6527b2c5a55b297a40af4e73dcadbb84f7db0d9cb3430', 'c6c5eb2cb723d4b10758bada7c286a13f962c70c021478ae1ede727fd42c944d')
)

function Test-UsefulEmbeddedExeIcon {
    param([string]$Path)
    $a = $null; $b = $null
    try {
        $a = Get-EmbeddedExeIconBitmap $Path 32
        if (-not $a) { return $false }
        $b = Get-EmbeddedExeIconBitmap $Path 48
        if (-not $b) { return $true }
        $ha = Get-NormalizedBitmapHash $a
        $hb = Get-NormalizedBitmapHash $b
        foreach ($sig in $genericIconSignatures) {
            if ($ha -eq $sig[0] -and $hb -eq $sig[1]) { return $false }
        }
        return $true
    }
    catch { return $false }
    finally {
        if ($a) { $a.Dispose() }
        if ($b) { $b.Dispose() }
    }
}

function Find-PictureCandidate {
    param([string]$Executable)
    $directory = [IO.Path]::GetDirectoryName($Executable)
    $base = [IO.Path]::GetFileNameWithoutExtension($Executable)

    $matching = Join-Path $directory "$base.ico"
    if (Test-Path -LiteralPath $matching) { return $matching }
    if (Test-UsefulEmbeddedExeIcon $Executable) { return $Executable }

    foreach ($name in @('app.ico', 'icon.ico', 'logo.ico')) {
        $candidate = Join-Path $directory $name
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    $icons = @(Get-ChildItem -LiteralPath $directory -Filter *.ico -File -ErrorAction SilentlyContinue)
    if ($icons.Count -eq 1) { return $icons[0].FullName }

    foreach ($name in @("$base.png", 'app.png', 'icon.png', 'logo.png', 'app-icon.png')) {
        $candidate = Join-Path $directory $name
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $Executable
}

function Resize-RasterBitmap {
    param([Drawing.Image]$Image, [int]$Size)
    if ($Image.Width -eq $Size -and $Image.Height -eq $Size) { return [Drawing.Bitmap]::new($Image) }

    $bitmap = [Drawing.Bitmap]::new($Size, $Size)
    $g = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $g.Clear([Drawing.Color]::Transparent)
        $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.CompositingQuality = [Drawing.Drawing2D.CompositingQuality]::HighQuality
        $scale = [Math]::Min($Size / [double]$Image.Width, $Size / [double]$Image.Height)
        $w = [Math]::Max(1, [int][Math]::Round($Image.Width * $scale))
        $h = [Math]::Max(1, [int][Math]::Round($Image.Height * $scale))
        $g.DrawImage($Image, [Drawing.Rectangle]::new([int](($Size-$w)/2), [int](($Size-$h)/2), $w, $h))
    }
    finally { $g.Dispose() }
    return $bitmap
}

function Get-PictureBitmap {
    param([string]$Path, [int]$Size = 96)
    switch ([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.ico' { return Get-IcoBitmap $Path $Size }
        '.exe' { return Get-ExeIconBitmap $Path $Size }
        default {
            $image = [Drawing.Image]::FromFile($Path)
            try { return Resize-RasterBitmap $image $Size }
            finally { $image.Dispose() }
        }
    }
}

function Install-AccountPicture {
    param([string]$Sid, [string]$Source)
    if (-not $Source -or -not (Test-Path -LiteralPath $Source -PathType Leaf)) { return }

    $dir = Join-Path $installDir "AccountPictures\$Sid"
    $registryKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AccountPicture\Users\$Sid"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    New-Item $registryKey -Force | Out-Null

    foreach ($size in 32,40,48,96,192,240,448) {
        $bitmap = Get-PictureBitmap $Source $size
        try {
            $filename = Join-Path $dir "Image$size.png"
            $bitmap.Save($filename, [Drawing.Imaging.ImageFormat]::Png)
            Protect-RestrictedFile $filename
            New-ItemProperty $registryKey -Name "Image$size" -PropertyType String -Value $filename -Force | Out-Null
        }
        finally { $bitmap.Dispose() }
    }
}

$form = [Windows.Forms.Form]@{
    Text='Restricted Account Configurator'; Width=700; Height=750; StartPosition='CenterScreen'
    FormBorderStyle='FixedDialog'; MaximizeBox=$false
}
$form.Font = [Drawing.Font]::new('Segoe UI', 9)

function Add-Label($Text,$X,$Y) {
    $c=[Windows.Forms.Label]@{Text=$Text;Left=$X;Top=$Y;Width=135};$form.Controls.Add($c)
}
function Add-TextBox($X,$Y,$Width) {
    $c=[Windows.Forms.TextBox]@{Left=$X;Top=$Y;Width=$Width};$form.Controls.Add($c);return $c
}

Add-Label 'Windows account:' 20 25
$accountCombo=[Windows.Forms.ComboBox]@{Left=160;Top=22;Width=300;DropDownStyle='DropDownList'};$form.Controls.Add($accountCombo)
Add-Label 'Target application:' 20 68
$appTextBox=Add-TextBox 160 65 405
$browseButton=[Windows.Forms.Button]@{Text='Browse...';Left=575;Top=63;Width=85};$form.Controls.Add($browseButton)
Add-Label 'Arguments:' 20 105
$argumentsTextBox=Add-TextBox 160 102 500
Add-Label 'Pre-run program/script:' 20 142
$preRunTextBox=Add-TextBox 160 139 405
$preRunBrowseButton=[Windows.Forms.Button]@{Text='Browse...';Left=575;Top=137;Width=85};$form.Controls.Add($preRunBrowseButton)
Add-Label 'Pre-run arguments:' 20 179
$preRunArgumentsTextBox=Add-TextBox 160 176 500
Add-Label 'Account picture:' 20 224
$pictureBox=[Windows.Forms.PictureBox]@{Left=160;Top=219;Width=96;Height=96;BorderStyle='FixedSingle';SizeMode='Zoom'};$form.Controls.Add($pictureBox)
$picturePathTextBox=Add-TextBox 275 221 385;$picturePathTextBox.ReadOnly=$true
$choosePictureButton=[Windows.Forms.Button]@{Text='Choose picture...';Left=275;Top=256;Width=130}
$autoPictureButton=[Windows.Forms.Button]@{Text='Auto-select';Left=415;Top=256;Width=100}
$form.Controls.AddRange(@($choosePictureButton,$autoPictureButton))

$disableTaskManager=[Windows.Forms.CheckBox]@{Text='Disable Task Manager';Left=160;Top=340;Width=250;Checked=$true}
$preventPasswordChange=[Windows.Forms.CheckBox]@{Text='User cannot change password';Left=160;Top=370;Width=260;Checked=$true}
$passwordNeverExpires=[Windows.Forms.CheckBox]@{Text='Password never expires';Left=160;Top=400;Width=250;Checked=$true}
$blockShellHotkeys=[Windows.Forms.CheckBox]@{Text='Block Windows shell/application-switching hotkeys';Left=160;Top=430;Width=370;Checked=$true}
$preventChildProcesses=[Windows.Forms.CheckBox]@{Text='Prevent target application from starting child processes';Left=160;Top=460;Width=390;Checked=$false}
$standardKeyboardVolumeShortcuts=[Windows.Forms.CheckBox]@{Text='Enable Win+Alt volume shortcuts (= / - / M)';Left=160;Top=490;Width=390;Checked=$false}
$logoffOnExit=[Windows.Forms.CheckBox]@{Text='Log off when target application exits';Left=160;Top=520;Width=320;Checked=$true}
$form.Controls.AddRange(@($disableTaskManager,$preventPasswordChange,$passwordNeverExpires,$blockShellHotkeys,$preventChildProcesses,$standardKeyboardVolumeShortcuts,$logoffOnExit))

$note=[Windows.Forms.Label]@{Left=20;Top=560;Width=640;Height=60;Text='First sign into this account normally, configure and test the target application, then sign out. Target and pre-run files must be in locations the restricted user cannot modify.'};$form.Controls.Add($note)
$status=[Windows.Forms.Label]@{Left=20;Top=650;Width=390;Height=40;Text='Ready.'}
$convertButton=[Windows.Forms.Button]@{Text='Convert / Update';Left=420;Top=645;Width=115}
$revertButton=[Windows.Forms.Button]@{Text='Revert Account';Left=545;Top=645;Width=115}
$form.Controls.AddRange(@($status,$convertButton,$revertButton))

$executableDialog=[Windows.Forms.OpenFileDialog]@{Filter='Executables|*.exe'}
$preRunDialog=[Windows.Forms.OpenFileDialog]@{Filter='Programs/scripts|*.exe;*.com;*.bat;*.cmd;*.ps1;*.py;*.pyw|All files|*.*'}
$pictureDialog=[Windows.Forms.OpenFileDialog]@{Filter='Pictures/icons/apps|*.ico;*.png;*.jpg;*.jpeg;*.bmp;*.exe|All files|*.*'}

function Set-PicturePreview($Path) {
    if ($pictureBox.Image) { $pictureBox.Image.Dispose() }
    $pictureBox.Image=$null;$picturePathTextBox.Text=$Path
    if (-not $Path) { $status.Text='No account picture selected.';return }
    try {
        $pictureBox.Image=Get-PictureBitmap $Path 96
        $status.Text="Picture preview loaded: 96x96 from $([IO.Path]::GetFileName($Path))"
    }
    catch { $status.Text="Picture preview failed: $($_.Exception.Message)" }
}

function Get-SelectedUser {
    if ($accountCombo.SelectedItem) { return Get-LocalUser -Name ([string]$accountCombo.SelectedItem) }
    return $null
}
function Get-IniBoolean($Section,$Key,[bool]$Default) {
    if ($Section -and $Section.Contains($Key)) { return $Section[$Key] -ne '0' }
    return $Default
}

function Refresh-AccountState {
    $user=Get-SelectedUser;if(-not $user){return}
    $appTextBox.Text='';$argumentsTextBox.Text='';$preRunTextBox.Text='';$preRunArgumentsTextBox.Text='';$picturePathTextBox.Text=''
    $preventChildProcesses.Checked=$false;$standardKeyboardVolumeShortcuts.Checked=$false;$blockShellHotkeys.Checked=$true;$logoffOnExit.Checked=$true

    $data=Read-IniFile $ini;$meta="Setup:$($user.Name)"
    $revertButton.Enabled=($data.Contains($meta) -and $data[$meta].SID -eq $user.SID.Value -and
        ($data[$meta].Converted -eq '1' -or $data[$meta].RollbackReady -eq '1'))

    if($data.Contains($user.Name)){
        $s=$data[$user.Name]
        $appTextBox.Text=$s.Executable;$argumentsTextBox.Text=$s.Arguments
        $preRunTextBox.Text=$s.PreRunExecutable;$preRunArgumentsTextBox.Text=$s.PreRunArguments
        $preventChildProcesses.Checked=Get-IniBoolean $s 'PreventChildProcesses' $false
        $standardKeyboardVolumeShortcuts.Checked=Get-IniBoolean $s 'StandardKeyboardVolumeShortcuts' $false
        $blockShellHotkeys.Checked=Get-IniBoolean $s 'BlockShellHotkeys' $true
        $logoffOnExit.Checked=Get-IniBoolean $s 'LogoffOnExit' $true
    }
}

$administratorSid='S-1-5-32-544'
$currentSid=$identity.User.Value
$users=Get-LocalUser | Where-Object {
    if(-not $_.Enabled -or $_.SID.Value -eq $currentSid -or $_.Name -in @('Guest','DefaultAccount','WDAGUtilityAccount')){return $false}
    $groups=Get-LocalGroupClosure $_.SID.Value
    return -not $groups.Contains($administratorSid)
} | Sort-Object Name
foreach($user in $users){[void]$accountCombo.Items.Add($user.Name)}
$accountCombo.Add_SelectedIndexChanged({Refresh-AccountState})
if($accountCombo.Items.Count){$accountCombo.SelectedIndex=0}

$browseButton.Add_Click({if($executableDialog.ShowDialog()-eq'OK'){$appTextBox.Text=$executableDialog.FileName;Set-PicturePreview (Find-PictureCandidate $appTextBox.Text)}})
$preRunBrowseButton.Add_Click({if($preRunDialog.ShowDialog()-eq'OK'){$preRunTextBox.Text=$preRunDialog.FileName}})
$autoPictureButton.Add_Click({Set-PicturePreview (Find-PictureCandidate $appTextBox.Text)})
$choosePictureButton.Add_Click({if($pictureDialog.ShowDialog()-eq'OK'){Set-PicturePreview $pictureDialog.FileName}})

$convertButton.Add_Click({
    $originalText=$convertButton.Text;$convertButton.Enabled=$false;$convertButton.Text='Working...';$status.Text='Validating and applying restricted account settings...';[Windows.Forms.Application]::DoEvents()

    $user=$null;$profile=$null;$data=$null;$meta=$null;$firstConversion=$false;$rollbackPrepared=$false;$changesStarted=$false
    try {
        Install-RestrictedShell
        $user=Get-SelectedUser;if(-not $user){throw 'Select an account.'}
        $profile=Get-ProfilePath $user.SID.Value
        if(-not $profile -or -not(Test-Path -LiteralPath (Join-Path $profile 'NTUSER.DAT') -PathType Leaf)){throw 'Account profile is not initialized. Sign into it once, then sign out.'}
        if(-not(Test-Path -LiteralPath $appTextBox.Text -PathType Leaf)){throw 'Select a valid target executable.'}

        $storedPreRunPath=Resolve-InstalledPreRunPath $preRunTextBox.Text
        if($storedPreRunPath -and -not(Test-Path -LiteralPath $storedPreRunPath -PathType Leaf)){throw 'Select a valid pre-run program or script, or leave it blank.'}

        $interpreter=''
        if($storedPreRunPath -and [IO.Path]::GetExtension($storedPreRunPath) -in @('.py','.pyw')){
            $interpreter=Resolve-PythonInterpreter $storedPreRunPath
        }

        $writableSids=Get-UserWritablePrincipalSids $user.SID.Value
        Assert-SecureLaunchPath $appTextBox.Text $writableSids 'Target application'
        if($storedPreRunPath){Assert-SecureLaunchPath $storedPreRunPath $writableSids 'Pre-run program/script'}
        if($interpreter){Assert-SecureLaunchPath $interpreter $writableSids 'Python interpreter'}

        $data=Read-IniFile $ini;$meta="Setup:$($user.Name)"
        $existingValid=$data.Contains($meta) -and $data[$meta].Converted -eq '1' -and $data[$meta].SID -eq $user.SID.Value
        $firstConversion=-not $existingValid

        if($firstConversion){
            if($data.Contains($meta)){$data.Remove($meta)}
            Set-IniValue $data $meta 'SID' $user.SID.Value
            Set-IniValue $data $meta 'PreviousUserMayChangePassword' ([int]$user.UserMayChangePassword)
            Set-IniValue $data $meta 'PreviousPasswordNeverExpires' ([int]$user.PasswordNeverExpires)
            Invoke-WithUserHive $user.SID.Value $profile {
                param($hive)
                Save-RegistryValue $data $meta (Join-Path $hive 'Software\Microsoft\Windows NT\CurrentVersion\Winlogon') 'Shell' 'PreviousShell'
                Save-RegistryValue $data $meta (Join-Path $hive 'Software\Microsoft\Windows\CurrentVersion\Policies\System') 'DisableTaskMgr' 'PreviousDisableTaskMgr'
            }
            Set-IniValue $data $meta 'RollbackReady' 1
            Set-IniValue $data $meta 'Converted' 0
        }

        Set-IniValue $data $user.Name 'Executable' ([IO.Path]::GetFullPath($appTextBox.Text))
        Set-IniValue $data $user.Name 'Arguments' $argumentsTextBox.Text
        Set-IniValue $data $user.Name 'PreRunExecutable' $storedPreRunPath
        Set-IniValue $data $user.Name 'PreRunArguments' $preRunArgumentsTextBox.Text
        Set-IniValue $data $user.Name 'PreRunInterpreter' $interpreter
        Set-IniValue $data $user.Name 'PreventChildProcesses' ([int]$preventChildProcesses.Checked)
        Set-IniValue $data $user.Name 'StandardKeyboardVolumeShortcuts' ([int]$standardKeyboardVolumeShortcuts.Checked)
        Set-IniValue $data $user.Name 'LogoffOnExit' ([int]$logoffOnExit.Checked)
        Set-IniValue $data $user.Name 'BlockShellHotkeys' ([int]$blockShellHotkeys.Checked)

        # Persist both rollback state and intended launch configuration before
        # changing the user's shell. A power loss from this point still leaves
        # enough information for Revert Account to recover the account.
        Write-IniFile $data
        $rollbackPrepared=$firstConversion

        if($picturePathTextBox.Text){Install-AccountPicture $user.SID.Value $picturePathTextBox.Text}

        $changesStarted=$true
        Invoke-WithUserHive $user.SID.Value $profile {
            param($hive)
            $winlogon=Join-Path $hive 'Software\Microsoft\Windows NT\CurrentVersion\Winlogon'
            $policies=Join-Path $hive 'Software\Microsoft\Windows\CurrentVersion\Policies\System'
            New-Item $winlogon -Force|Out-Null
            New-ItemProperty $winlogon -Name Shell -PropertyType String -Value ('"'+$shell+'"') -Force|Out-Null
            if($disableTaskManager.Checked){
                New-Item $policies -Force|Out-Null
                New-ItemProperty $policies -Name DisableTaskMgr -PropertyType DWord -Value 1 -Force|Out-Null
            }else{Remove-ItemProperty $policies -Name DisableTaskMgr -ErrorAction SilentlyContinue}
        }
        Set-LocalUser -Name $user.Name -UserMayChangePassword:(-not $preventPasswordChange.Checked) -PasswordNeverExpires:$passwordNeverExpires.Checked

        if($firstConversion){Set-IniValue $data $meta 'Converted' 1}
        Write-IniFile $data
        $preRunTextBox.Text=$storedPreRunPath
        $status.Text="Converted $($user.Name).";Refresh-AccountState
    }
    catch {
        $message=$_.Exception.Message
        if($firstConversion -and $rollbackPrepared){
            if($changesStarted){
                try {
                    Restore-AccountFromMetadata $user $profile $data $meta
                    $data.Remove($user.Name);$data.Remove($meta);Write-IniFile $data
                    $message += "`n`nThe partially applied conversion was automatically rolled back."
                }
                catch {
                    $message += "`n`nAutomatic rollback also failed. Rollback metadata was preserved; use Revert Account after correcting the underlying problem."
                }
            }else{
                try{$data.Remove($user.Name);$data.Remove($meta);Write-IniFile $data}catch{}
            }
        }
        [Windows.Forms.MessageBox]::Show($message,'Conversion failed')|Out-Null;$status.Text='Conversion failed.'
    }
    finally{$convertButton.Text=$originalText;$convertButton.Enabled=$true;Refresh-AccountState}
})

$revertButton.Add_Click({
    $originalText=$revertButton.Text;$revertButton.Enabled=$false;$revertButton.Text='Working...';$status.Text='Reverting account settings...';[Windows.Forms.Application]::DoEvents()
    try{
        $user=Get-SelectedUser;if(-not$user){throw'Select an account.'}
        $data=Read-IniFile $ini;$meta="Setup:$($user.Name)"
        if(-not$data.Contains($meta)-or$data[$meta].SID-ne$user.SID.Value-or($data[$meta].Converted-ne'1'-and$data[$meta].RollbackReady-ne'1')){throw'No valid rollback state.'}
        $profile=Get-ProfilePath $user.SID.Value
        Restore-AccountFromMetadata $user $profile $data $meta
        $data.Remove($user.Name);$data.Remove($meta);Write-IniFile $data
        $status.Text="Reverted $($user.Name).";Refresh-AccountState
    }
    catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Revert failed')|Out-Null;$status.Text='Revert failed.'}
    finally{$revertButton.Text=$originalText;$revertButton.Enabled=$true;Refresh-AccountState}
})

[void]$form.ShowDialog()
