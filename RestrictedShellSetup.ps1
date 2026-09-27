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
            string fileName,
            int iconIndex,
            int cxIcon,
            int cyIcon,
            IntPtr[] iconHandles,
            uint[] iconIds,
            uint iconCount,
            uint flags);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr LoadImageW(
            IntPtr instance,
            string name,
            uint type,
            int cx,
            int cy,
            uint loadFlags);

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

function Protect-RestrictedShellStorage {
    if (-not (Test-Path -LiteralPath $installDir)) {
        return
    }

    $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $administratorsSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $usersSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
    $inherit = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit

    $directoryAcl = [Security.AccessControl.DirectorySecurity]::new()
    $directoryAcl.SetAccessRuleProtection($true, $false)
    $directoryAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $systemSid,
        [Security.AccessControl.FileSystemRights]::FullControl,
        $inherit,
        [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Allow
    ))
    $directoryAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $administratorsSid,
        [Security.AccessControl.FileSystemRights]::FullControl,
        $inherit,
        [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Allow
    ))
    $directoryAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $usersSid,
        [Security.AccessControl.FileSystemRights]::ReadAndExecute,
        $inherit,
        [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Allow
    ))
    Set-Acl -LiteralPath $installDir -AclObject $directoryAcl

    if (Test-Path -LiteralPath $ini) {
        $fileAcl = [Security.AccessControl.FileSecurity]::new()
        $fileAcl.SetAccessRuleProtection($true, $false)
        $fileAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $systemSid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.AccessControlType]::Allow
        ))
        $fileAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $administratorsSid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.AccessControlType]::Allow
        ))
        $fileAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $usersSid,
            [Security.AccessControl.FileSystemRights]::ReadAndExecute,
            [Security.AccessControl.AccessControlType]::Allow
        ))
        Set-Acl -LiteralPath $ini -AclObject $fileAcl
    }
}

function Get-NativeArchitecture {
    $architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()

    switch ($architecture) {
        'x86'   { return 'x86' }
        'x64'   { return 'x64' }
        'arm64' { return 'arm64' }
        default { throw "Unsupported Windows architecture: $architecture" }
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

    if (-not (Test-Path -LiteralPath $ini)) {
        $template = Join-Path $here 'RestrictedShell.ini'

        if (Test-Path -LiteralPath $template) {
            Copy-Item -LiteralPath $template -Destination $ini
        }
        else {
            $defaultIni = @"
[RestrictedShell]
LogoffOnExit=1
BlockShellHotkeys=1
PreventChildProcesses=0
StandardKeyboardVolumeShortcuts=0
PreRunExecutable=
PreRunArguments=
"@
            [IO.File]::WriteAllText($ini, $defaultIni, [Text.UTF8Encoding]::new($false))
        }
    }

    Protect-RestrictedShellStorage
}

function Read-IniFile {
    param($Path)

    $data = [ordered]@{}
    $section = ''

    if (Test-Path -LiteralPath $Path) {
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
    }

    return $data
}

function Set-IniValue {
    param($Data, $Section, $Key, $Value)

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

    [IO.File]::WriteAllLines($ini, $lines, [Text.UTF8Encoding]::new($false))
    Protect-RestrictedShellStorage
}

function Get-ProfilePath {
    param($Sid)

    $key = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$Sid"
    if (Test-Path $key) {
        return [Environment]::ExpandEnvironmentVariables((Get-ItemProperty $key).ProfileImagePath)
    }

    return $null
}

function Invoke-WithUserHive {
    param($Sid, $Profile, [scriptblock]$Body)

    $loadedHive = "Registry::HKEY_USERS\$Sid"
    if (Test-Path $loadedHive) {
        & $Body $loadedHive
        return
    }

    $mountName = 'RS_' + [guid]::NewGuid().ToString('N')
    $ntUser = Join-Path $Profile 'NTUSER.DAT'

    & reg.exe load "HKU\$mountName" $ntUser | Out-Null
    if ($LASTEXITCODE) {
        throw 'Could not load user hive.'
    }

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
    param($Data, $Section, $Path, $Name, $Key)

    $value = Get-ItemProperty $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -ne $value) {
        Set-IniValue $Data $Section $Key $value.$Name
    }
    else {
        Set-IniValue $Data $Section $Key '__MISSING__'
    }
}

function Restore-RegistryValue {
    param($Path, $Name, $Value, $Type)

    if ($Value -eq '__MISSING__') {
        Remove-ItemProperty $Path -Name $Name -ErrorAction SilentlyContinue
        return
    }

    New-Item $Path -Force | Out-Null
    New-ItemProperty $Path -Name $Name -PropertyType $Type -Value $Value -Force | Out-Null
}

function Convert-IconHandleToBitmap {
    param([IntPtr]$Handle)

    if ($Handle -eq [IntPtr]::Zero) {
        throw 'Windows returned a null icon handle.'
    }

    $icon = [Drawing.Icon]::FromHandle($Handle)
    try {
        $bitmap = $icon.ToBitmap()
        try {
            return [Drawing.Bitmap]::new($bitmap)
        }
        finally {
            $bitmap.Dispose()
        }
    }
    finally {
        $icon.Dispose()
    }
}

function Get-IcoBitmap {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$Size
    )

    $IMAGE_ICON = 1
    $LR_LOADFROMFILE = 0x0010
    $handle = [RestrictedShell.NativeIcon]::LoadImageW(
        [IntPtr]::Zero,
        $Path,
        $IMAGE_ICON,
        $Size,
        $Size,
        $LR_LOADFROMFILE
    )

    if ($handle -eq [IntPtr]::Zero) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "LoadImageW could not load a ${Size}x${Size} icon from '$Path' (Win32 error $errorCode)."
    }

    try {
        return Convert-IconHandleToBitmap $handle
    }
    finally {
        [void][RestrictedShell.NativeIcon]::DestroyIcon($handle)
    }
}

function Get-EmbeddedExeIconBitmap {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$Size
    )

    $handles = [IntPtr[]]::new(1)
    $ids = [uint32[]]::new(1)

    try {
        $count = [RestrictedShell.NativeIcon]::PrivateExtractIconsW(
            $Path,
            0,
            $Size,
            $Size,
            $handles,
            $ids,
            1,
            0
        )

        if ($count -gt 0 -and $count -ne [uint32]::MaxValue -and $handles[0] -ne [IntPtr]::Zero) {
            return Convert-IconHandleToBitmap $handles[0]
        }

        return $null
    }
    finally {
        if ($handles[0] -ne [IntPtr]::Zero) {
            [void][RestrictedShell.NativeIcon]::DestroyIcon($handles[0])
        }
    }
}

function Get-ExeIconBitmap {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$Size
    )

    try {
        $embedded = Get-EmbeddedExeIconBitmap -Path $Path -Size $Size
        if ($embedded) {
            return $embedded
        }
    }
    catch {
        # Fall back to Windows' associated icon below.
    }

    $fallback = [Drawing.Icon]::ExtractAssociatedIcon($Path)
    if ($null -eq $fallback) {
        throw "No icon could be extracted from '$Path'."
    }

    try {
        $bitmap = $fallback.ToBitmap()
        try {
            return [Drawing.Bitmap]::new($bitmap)
        }
        finally {
            $bitmap.Dispose()
        }
    }
    finally {
        $fallback.Dispose()
    }
}

function Get-NormalizedBitmapHash {
    param([Parameter(Mandatory = $true)][Drawing.Bitmap]$Bitmap)

    $bytes = New-Object byte[] ($Bitmap.Width * $Bitmap.Height * 4)
    $index = 0

    for ($y = 0; $y -lt $Bitmap.Height; $y++) {
        for ($x = 0; $x -lt $Bitmap.Width; $x++) {
            $pixel = $Bitmap.GetPixel($x, $y)
            $bytes[$index++] = $pixel.A
            $bytes[$index++] = $pixel.R
            $bytes[$index++] = $pixel.G
            $bytes[$index++] = $pixel.B
        }
    }

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ($sha.ComputeHash($bytes) | ForEach-Object ToString x2) -join ''
    }
    finally {
        $sha.Dispose()
    }
}

$genericIconSignatures = @(
    @{
        Name = 'PyInstaller console'
        Hash32 = '933f506c84bddc927f19c4890c0b391bad30f59e4c2052607b6e4b6297d1d62f'
        Hash48 = 'deb5efcddc9c870fb0e8bf3dabd86827e3f369de9ceded75afa98bc0e473e7f6'
    },
    @{
        Name = 'PyInstaller windowed'
        Hash32 = '26a47902011dde48fc5e45607ff2dcae0eeb0e71a588830aaeca181808c73fd0'
        Hash48 = '315add701425584c9e4e069ecd6e437083b597f31bb561b0eae3683387f9ede0'
    },
    @{
        Name = 'Electron'
        Hash32 = '5bd97fab4b452d85a5a6527b2c5a55b297a40af4e73dcadbb84f7db0d9cb3430'
        Hash48 = 'c6c5eb2cb723d4b10758bada7c286a13f962c70c021478ae1ede727fd42c944d'
    }
)

function Test-UsefulEmbeddedExeIcon {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bitmap32 = $null
    $bitmap48 = $null

    try {
        $bitmap32 = Get-EmbeddedExeIconBitmap -Path $Path -Size 32
        if (-not $bitmap32) {
            return $false
        }

        $bitmap48 = Get-EmbeddedExeIconBitmap -Path $Path -Size 48
        if (-not $bitmap48) {
            return $true
        }

        $hash32 = Get-NormalizedBitmapHash $bitmap32
        $hash48 = Get-NormalizedBitmapHash $bitmap48

        foreach ($signature in $genericIconSignatures) {
            if ($hash32 -eq $signature.Hash32 -and $hash48 -eq $signature.Hash48) {
                return $false
            }
        }

        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($bitmap32) { $bitmap32.Dispose() }
        if ($bitmap48) { $bitmap48.Dispose() }
    }
}

function Find-PictureCandidate {
    param($Executable)

    $directory = [IO.Path]::GetDirectoryName($Executable)
    $baseName = [IO.Path]::GetFileNameWithoutExtension($Executable)

    $matchingIco = Join-Path $directory "$baseName.ico"
    if (Test-Path -LiteralPath $matchingIco) {
        return $matchingIco
    }

    if (Test-UsefulEmbeddedExeIcon -Path $Executable) {
        return $Executable
    }

    foreach ($name in @('app.ico', 'icon.ico', 'logo.ico')) {
        $candidate = Join-Path $directory $name
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    $icons = @(Get-ChildItem -LiteralPath $directory -Filter *.ico -File -ErrorAction SilentlyContinue)
    if ($icons.Count -eq 1) {
        return $icons[0].FullName
    }

    foreach ($name in @("$baseName.png", 'app.png', 'icon.png', 'logo.png', 'app-icon.png')) {
        $candidate = Join-Path $directory $name
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $Executable
}

function Resize-RasterBitmap {
    param(
        [Parameter(Mandatory = $true)][Drawing.Image]$Image,
        [Parameter(Mandatory = $true)][int]$Size
    )

    if ($Image.Width -eq $Size -and $Image.Height -eq $Size) {
        return [Drawing.Bitmap]::new($Image)
    }

    $bitmap = [Drawing.Bitmap]::new($Size, $Size)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)

    try {
        $graphics.Clear([Drawing.Color]::Transparent)
        $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.CompositingQuality = [Drawing.Drawing2D.CompositingQuality]::HighQuality

        $scale = [Math]::Min($Size / [double]$Image.Width, $Size / [double]$Image.Height)
        $width = [Math]::Max(1, [int][Math]::Round($Image.Width * $scale))
        $height = [Math]::Max(1, [int][Math]::Round($Image.Height * $scale))
        $x = [int](($Size - $width) / 2)
        $y = [int](($Size - $height) / 2)

        $graphics.DrawImage($Image, [Drawing.Rectangle]::new($x, $y, $width, $height))
    }
    finally {
        $graphics.Dispose()
    }

    return $bitmap
}

function Get-PictureBitmap {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Size = 96
    )

    switch ([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.ico' { return Get-IcoBitmap -Path $Path -Size $Size }
        '.exe' { return Get-ExeIconBitmap -Path $Path -Size $Size }
        default {
            $image = [Drawing.Image]::FromFile($Path)
            try {
                return Resize-RasterBitmap -Image $image -Size $Size
            }
            finally {
                $image.Dispose()
            }
        }
    }
}

function Install-AccountPicture {
    param($Sid, $Source)

    if (-not $Source -or -not (Test-Path -LiteralPath $Source)) {
        return
    }

    $pictureDir = Join-Path $env:ProgramData "RestrictedShell\AccountPictures\$Sid"
    $registryKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AccountPicture\Users\$Sid"

    New-Item -ItemType Directory -Path $pictureDir -Force | Out-Null
    New-Item $registryKey -Force | Out-Null

    foreach ($size in 32, 40, 48, 96, 192, 240, 448) {
        $bitmap = Get-PictureBitmap -Path $Source -Size $size
        try {
            $filename = Join-Path $pictureDir "Image$size.png"
            $bitmap.Save($filename, [Drawing.Imaging.ImageFormat]::Png)
            New-ItemProperty $registryKey -Name "Image$size" -PropertyType String -Value $filename -Force | Out-Null
        }
        finally {
            $bitmap.Dispose()
        }
    }

    Protect-RestrictedShellStorage
}

$form = [Windows.Forms.Form]@{
    Text = 'Restricted Account Configurator'
    Width = 700
    Height = 750
    StartPosition = 'CenterScreen'
    FormBorderStyle = 'FixedDialog'
    MaximizeBox = $false
}
$form.Font = [Drawing.Font]::new('Segoe UI', 9)

function Add-Label {
    param($Text, $X, $Y)

    $control = [Windows.Forms.Label]@{
        Text = $Text
        Left = $X
        Top = $Y
        Width = 135
    }
    $form.Controls.Add($control)
}

function Add-TextBox {
    param($X, $Y, $Width)

    $control = [Windows.Forms.TextBox]@{
        Left = $X
        Top = $Y
        Width = $Width
    }
    $form.Controls.Add($control)
    return $control
}

Add-Label 'Windows account:' 20 25
$accountCombo = [Windows.Forms.ComboBox]@{
    Left = 160
    Top = 22
    Width = 300
    DropDownStyle = 'DropDownList'
}
$form.Controls.Add($accountCombo)

Add-Label 'Target application:' 20 68
$appTextBox = Add-TextBox 160 65 405
$browseButton = [Windows.Forms.Button]@{ Text = 'Browse...'; Left = 575; Top = 63; Width = 85 }
$form.Controls.Add($browseButton)

Add-Label 'Arguments:' 20 105
$argumentsTextBox = Add-TextBox 160 102 500

Add-Label 'Pre-run program/script:' 20 142
$preRunTextBox = Add-TextBox 160 139 405
$preRunBrowseButton = [Windows.Forms.Button]@{ Text = 'Browse...'; Left = 575; Top = 137; Width = 85 }
$form.Controls.Add($preRunBrowseButton)

Add-Label 'Pre-run arguments:' 20 179
$preRunArgumentsTextBox = Add-TextBox 160 176 500

Add-Label 'Account picture:' 20 224
$pictureBox = [Windows.Forms.PictureBox]@{
    Left = 160
    Top = 219
    Width = 96
    Height = 96
    BorderStyle = 'FixedSingle'
    SizeMode = 'Zoom'
}
$form.Controls.Add($pictureBox)

$picturePathTextBox = Add-TextBox 275 221 385
$picturePathTextBox.ReadOnly = $true
$choosePictureButton = [Windows.Forms.Button]@{ Text = 'Choose picture...'; Left = 275; Top = 256; Width = 130 }
$autoPictureButton = [Windows.Forms.Button]@{ Text = 'Auto-select'; Left = 415; Top = 256; Width = 100 }
$form.Controls.AddRange(@($choosePictureButton, $autoPictureButton))

$disableTaskManager = [Windows.Forms.CheckBox]@{ Text = 'Disable Task Manager'; Left = 160; Top = 340; Width = 250; Checked = $true }
$preventPasswordChange = [Windows.Forms.CheckBox]@{ Text = 'User cannot change password'; Left = 160; Top = 370; Width = 260; Checked = $true }
$passwordNeverExpires = [Windows.Forms.CheckBox]@{ Text = 'Password never expires'; Left = 160; Top = 400; Width = 250; Checked = $true }
$blockShellHotkeys = [Windows.Forms.CheckBox]@{ Text = 'Block Windows shell/application-switching hotkeys'; Left = 160; Top = 430; Width = 370; Checked = $true }
$preventChildProcesses = [Windows.Forms.CheckBox]@{ Text = 'Prevent target application from starting child processes'; Left = 160; Top = 460; Width = 390; Checked = $false }
$standardKeyboardVolumeShortcuts = [Windows.Forms.CheckBox]@{ Text = 'Enable Win+Alt volume shortcuts (= / - / M)'; Left = 160; Top = 490; Width = 390; Checked = $false }
$logoffOnExit = [Windows.Forms.CheckBox]@{ Text = 'Log off when target application exits'; Left = 160; Top = 520; Width = 320; Checked = $true }
$form.Controls.AddRange(@(
    $disableTaskManager,
    $preventPasswordChange,
    $passwordNeverExpires,
    $blockShellHotkeys,
    $preventChildProcesses,
    $standardKeyboardVolumeShortcuts,
    $logoffOnExit
))

$note = [Windows.Forms.Label]@{
    Left = 20
    Top = 560
    Width = 640
    Height = 60
    Text = 'First sign into this account normally, configure and test the target application, then sign out. A pre-run program/script is unrestricted and must exit before the target starts.'
}
$form.Controls.Add($note)

$status = [Windows.Forms.Label]@{ Left = 20; Top = 650; Width = 390; Height = 40; Text = 'Ready.' }
$convertButton = [Windows.Forms.Button]@{ Text = 'Convert / Update'; Left = 420; Top = 645; Width = 115 }
$revertButton = [Windows.Forms.Button]@{ Text = 'Revert Account'; Left = 545; Top = 645; Width = 115 }
$form.Controls.AddRange(@($status, $convertButton, $revertButton))

$executableDialog = [Windows.Forms.OpenFileDialog]@{ Filter = 'Executables|*.exe' }
$preRunDialog = [Windows.Forms.OpenFileDialog]@{ Filter = 'Programs/scripts|*.exe;*.com;*.bat;*.cmd;*.ps1|All files|*.*' }
$pictureDialog = [Windows.Forms.OpenFileDialog]@{ Filter = 'Pictures/icons/apps|*.ico;*.png;*.jpg;*.jpeg;*.bmp;*.exe|All files|*.*' }

function Set-PicturePreview {
    param($Path)

    if ($pictureBox.Image) {
        $pictureBox.Image.Dispose()
    }

    $pictureBox.Image = $null
    $picturePathTextBox.Text = $Path

    if (-not $Path) {
        $status.Text = 'No account picture selected.'
        return
    }

    try {
        $pictureBox.Image = Get-PictureBitmap -Path $Path -Size 96
        $status.Text = "Picture preview loaded: 96x96 from $([IO.Path]::GetFileName($Path))"
    }
    catch {
        $status.Text = "Picture preview failed: $($_.Exception.Message)"
    }
}

function Get-SelectedUser {
    if ($accountCombo.SelectedItem) {
        return Get-LocalUser -Name ([string]$accountCombo.SelectedItem)
    }

    return $null
}

function Get-IniBoolean {
    param($Section, $Key, [bool]$Default)

    if ($Section -and $Section.Contains($Key)) {
        return $Section[$Key] -ne '0'
    }

    return $Default
}

function Refresh-AccountState {
    $user = Get-SelectedUser
    if (-not $user) {
        return
    }

    $appTextBox.Text = ''
    $argumentsTextBox.Text = ''
    $preRunTextBox.Text = ''
    $preRunArgumentsTextBox.Text = ''
    $picturePathTextBox.Text = ''
    $preventChildProcesses.Checked = $false
    $standardKeyboardVolumeShortcuts.Checked = $false
    $blockShellHotkeys.Checked = $true
    $logoffOnExit.Checked = $true

    $data = Read-IniFile $ini
    $metadataSection = "Setup:$($user.Name)"

    $revertButton.Enabled = (
        $data.Contains($metadataSection) -and
        $data[$metadataSection].Converted -eq '1' -and
        $data[$metadataSection].SID -eq $user.SID.Value
    )

    if ($data.Contains($user.Name)) {
        $section = $data[$user.Name]
        $appTextBox.Text = $section.Executable
        $argumentsTextBox.Text = $section.Arguments
        $preRunTextBox.Text = $section.PreRunExecutable
        $preRunArgumentsTextBox.Text = $section.PreRunArguments
        $preventChildProcesses.Checked = Get-IniBoolean $section 'PreventChildProcesses' $false
        $standardKeyboardVolumeShortcuts.Checked = Get-IniBoolean $section 'StandardKeyboardVolumeShortcuts' $false
        $blockShellHotkeys.Checked = Get-IniBoolean $section 'BlockShellHotkeys' $true
        $logoffOnExit.Checked = Get-IniBoolean $section 'LogoffOnExit' $true
    }
}

$administratorsGroup = Get-LocalGroup -SID 'S-1-5-32-544'
$administratorSids = @(
    Get-LocalGroupMember -Group $administratorsGroup.Name -ErrorAction Stop |
        ForEach-Object { $_.SID.Value }
)
$currentSid = $identity.User.Value

$users = Get-LocalUser |
    Where-Object {
        $_.Enabled -and
        $_.SID.Value -ne $currentSid -and
        $_.SID.Value -notin $administratorSids -and
        $_.Name -notin @('Guest', 'DefaultAccount', 'WDAGUtilityAccount')
    } |
    Sort-Object Name

foreach ($user in $users) {
    [void]$accountCombo.Items.Add($user.Name)
}

$accountCombo.Add_SelectedIndexChanged({ Refresh-AccountState })
if ($accountCombo.Items.Count) {
    $accountCombo.SelectedIndex = 0
}

$browseButton.Add_Click({
    if ($executableDialog.ShowDialog() -eq 'OK') {
        $appTextBox.Text = $executableDialog.FileName
        Set-PicturePreview (Find-PictureCandidate $appTextBox.Text)
    }
})

$preRunBrowseButton.Add_Click({
    if ($preRunDialog.ShowDialog() -eq 'OK') {
        $preRunTextBox.Text = $preRunDialog.FileName
    }
})

$autoPictureButton.Add_Click({ Set-PicturePreview (Find-PictureCandidate $appTextBox.Text) })
$choosePictureButton.Add_Click({
    if ($pictureDialog.ShowDialog() -eq 'OK') {
        Set-PicturePreview $pictureDialog.FileName
    }
})

$convertButton.Add_Click({
    $originalText = $convertButton.Text
    $convertButton.Enabled = $false
    $convertButton.Text = 'Working...'
    $status.Text = 'Applying restricted account settings...'
    [Windows.Forms.Application]::DoEvents()

    try {
        Install-RestrictedShell

        $user = Get-SelectedUser
        if (-not $user) {
            throw 'Select an account.'
        }

        $profile = Get-ProfilePath $user.SID.Value
        if (-not $profile -or -not (Test-Path (Join-Path $profile 'NTUSER.DAT'))) {
            throw 'Account profile is not initialized. Sign into it once, then sign out.'
        }

        if (-not (Test-Path -LiteralPath $appTextBox.Text)) {
            throw 'Select a valid target executable.'
        }

        if ($preRunTextBox.Text -and -not (Test-Path -LiteralPath $preRunTextBox.Text)) {
            throw 'Select a valid pre-run program or script, or leave it blank.'
        }

        $data = Read-IniFile $ini
        $metadataSection = "Setup:$($user.Name)"
        $firstConversion = -not (
            $data.Contains($metadataSection) -and
            $data[$metadataSection].Converted -eq '1'
        )

        if ($firstConversion) {
            Set-IniValue $data $metadataSection 'SID' $user.SID.Value
            Set-IniValue $data $metadataSection 'PreviousUserMayChangePassword' ([int]$user.UserMayChangePassword)
            Set-IniValue $data $metadataSection 'PreviousPasswordNeverExpires' ([int]$user.PasswordNeverExpires)
        }

        Invoke-WithUserHive $user.SID.Value $profile {
            param($hive)

            $winlogon = Join-Path $hive 'Software\Microsoft\Windows NT\CurrentVersion\Winlogon'
            $policies = Join-Path $hive 'Software\Microsoft\Windows\CurrentVersion\Policies\System'

            if ($firstConversion) {
                Save-RegistryValue $data $metadataSection $winlogon 'Shell' 'PreviousShell'
                Save-RegistryValue $data $metadataSection $policies 'DisableTaskMgr' 'PreviousDisableTaskMgr'
            }

            New-Item $winlogon -Force | Out-Null
            New-ItemProperty $winlogon -Name 'Shell' -PropertyType String -Value ('"' + $shell + '"') -Force | Out-Null

            if ($disableTaskManager.Checked) {
                New-Item $policies -Force | Out-Null
                New-ItemProperty $policies -Name 'DisableTaskMgr' -PropertyType DWord -Value 1 -Force | Out-Null
            }
            else {
                Remove-ItemProperty $policies -Name 'DisableTaskMgr' -ErrorAction SilentlyContinue
            }
        }

        Set-LocalUser `
            -Name $user.Name `
            -UserMayChangePassword:(-not $preventPasswordChange.Checked) `
            -PasswordNeverExpires:$passwordNeverExpires.Checked

        if ($picturePathTextBox.Text) {
            Install-AccountPicture $user.SID.Value $picturePathTextBox.Text
        }

        Set-IniValue $data $user.Name 'Executable' $appTextBox.Text
        Set-IniValue $data $user.Name 'Arguments' $argumentsTextBox.Text
        Set-IniValue $data $user.Name 'PreRunExecutable' $preRunTextBox.Text
        Set-IniValue $data $user.Name 'PreRunArguments' $preRunArgumentsTextBox.Text
        Set-IniValue $data $user.Name 'PreventChildProcesses' ([int]$preventChildProcesses.Checked)
        Set-IniValue $data $user.Name 'StandardKeyboardVolumeShortcuts' ([int]$standardKeyboardVolumeShortcuts.Checked)
        Set-IniValue $data $user.Name 'LogoffOnExit' ([int]$logoffOnExit.Checked)
        Set-IniValue $data $user.Name 'BlockShellHotkeys' ([int]$blockShellHotkeys.Checked)
        Set-IniValue $data $metadataSection 'Converted' 1
        Write-IniFile $data

        $status.Text = "Converted $($user.Name)."
        Refresh-AccountState
    }
    catch {
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Conversion failed') | Out-Null
        $status.Text = 'Conversion failed.'
    }
    finally {
        $convertButton.Text = $originalText
        $convertButton.Enabled = $true
    }
})

$revertButton.Add_Click({
    $originalText = $revertButton.Text
    $revertButton.Enabled = $false
    $revertButton.Text = 'Working...'
    $status.Text = 'Reverting account settings...'
    [Windows.Forms.Application]::DoEvents()

    try {
        $user = Get-SelectedUser
        if (-not $user) {
            throw 'Select an account.'
        }

        $data = Read-IniFile $ini
        $metadataSection = "Setup:$($user.Name)"

        if (-not $data.Contains($metadataSection) -or $data[$metadataSection].SID -ne $user.SID.Value) {
            throw 'No valid rollback state.'
        }

        $profile = Get-ProfilePath $user.SID.Value

        Invoke-WithUserHive $user.SID.Value $profile {
            param($hive)

            Restore-RegistryValue `
                (Join-Path $hive 'Software\Microsoft\Windows NT\CurrentVersion\Winlogon') `
                'Shell' `
                $data[$metadataSection].PreviousShell `
                'String'

            Restore-RegistryValue `
                (Join-Path $hive 'Software\Microsoft\Windows\CurrentVersion\Policies\System') `
                'DisableTaskMgr' `
                $data[$metadataSection].PreviousDisableTaskMgr `
                'DWord'
        }

        Set-LocalUser `
            -Name $user.Name `
            -UserMayChangePassword:([bool][int]$data[$metadataSection].PreviousUserMayChangePassword) `
            -PasswordNeverExpires:([bool][int]$data[$metadataSection].PreviousPasswordNeverExpires)

        $data.Remove($user.Name)
        $data.Remove($metadataSection)
        Write-IniFile $data

        $status.Text = "Reverted $($user.Name)."
        Refresh-AccountState
    }
    catch {
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Revert failed') | Out-Null
        $status.Text = 'Revert failed.'
    }
    finally {
        $revertButton.Text = $originalText
        Refresh-AccountState
    }
})

[void]$form.ShowDialog()
