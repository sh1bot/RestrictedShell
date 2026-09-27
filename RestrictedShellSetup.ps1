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
    Copy-Item -LiteralPath $source -Destination $shell -Force

    if (-not (Test-Path -LiteralPath $ini)) {
        $template = Join-Path $here 'RestrictedShell.ini'

        if (Test-Path -LiteralPath $template) {
            Copy-Item -LiteralPath $template -Destination $ini
        }
        else {
            $defaultIni = "[RestrictedShell]`r`nLogoffOnExit=1`r`nBlockShellHotkeys=1`r`n"
            [IO.File]::WriteAllText($ini, $defaultIni, [Text.UTF8Encoding]::new($false))
        }
    }
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

function Find-PictureCandidate {
    param($Executable)

    $directory = [IO.Path]::GetDirectoryName($Executable)
    $baseName = [IO.Path]::GetFileNameWithoutExtension($Executable)

    foreach ($name in @("$baseName.ico", 'app.ico', 'icon.ico', 'logo.ico')) {
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

function Get-ExeIconBitmap {
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
    }
    catch {
        # Continue to the conservative associated-icon fallback below.
    }
    finally {
        if ($handles[0] -ne [IntPtr]::Zero) {
            [void][RestrictedShell.NativeIcon]::DestroyIcon($handles[0])
        }
    }

    $fallback = [Drawing.Icon]::ExtractAssociatedIcon($Path)

    if ($null -eq $fallback) {
        throw "No icon could be extracted from '$Path'."
    }

    try {
        return Convert-IconHandleToBitmap $fallback
    }
    finally {
        $fallback.Dispose()
    }
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

    $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()

    switch ($extension) {
        '.ico' {
            return Get-IcoBitmap -Path $Path -Size $Size
        }
        '.exe' {
            return Get-ExeIconBitmap -Path $Path -Size $Size
        }
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
}

$form = [Windows.Forms.Form]@{
    Text = 'Restricted Account Configurator'
    Width = 700
    Height = 610
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
        Width = 130
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
    Left = 155
    Top = 22
    Width = 300
    DropDownStyle = 'DropDownList'
}
$form.Controls.Add($accountCombo)

Add-Label 'Target application:' 20 68
$appTextBox = Add-TextBox 155 65 410

$browseButton = [Windows.Forms.Button]@{
    Text = 'Browse...'
    Left = 575
    Top = 63
    Width = 85
}
$form.Controls.Add($browseButton)

Add-Label 'Arguments:' 20 105
$argumentsTextBox = Add-TextBox 155 102 505

Add-Label 'Account picture:' 20 150

$pictureBox = [Windows.Forms.PictureBox]@{
    Left = 155
    Top = 145
    Width = 96
    Height = 96
    BorderStyle = 'FixedSingle'
    SizeMode = 'Zoom'
}
$form.Controls.Add($pictureBox)

$picturePathTextBox = Add-TextBox 270 147 390
$picturePathTextBox.ReadOnly = $true

$choosePictureButton = [Windows.Forms.Button]@{
    Text = 'Choose picture...'
    Left = 270
    Top = 182
    Width = 130
}

$autoPictureButton = [Windows.Forms.Button]@{
    Text = 'Auto-select'
    Left = 410
    Top = 182
    Width = 100
}

$form.Controls.AddRange(@($choosePictureButton, $autoPictureButton))

$disableTaskManager = [Windows.Forms.CheckBox]@{
    Text = 'Disable Task Manager'
    Left = 155
    Top = 270
    Width = 250
    Checked = $true
}

$preventPasswordChange = [Windows.Forms.CheckBox]@{
    Text = 'User cannot change password'
    Left = 155
    Top = 300
    Width = 260
    Checked = $true
}

$passwordNeverExpires = [Windows.Forms.CheckBox]@{
    Text = 'Password never expires'
    Left = 155
    Top = 330
    Width = 250
    Checked = $true
}

$blockShellHotkeys = [Windows.Forms.CheckBox]@{
    Text = 'Block Windows shell/application-switching hotkeys'
    Left = 155
    Top = 360
    Width = 370
    Checked = $true
}

$logoffOnExit = [Windows.Forms.CheckBox]@{
    Text = 'Log off when target application exits'
    Left = 155
    Top = 390
    Width = 320
    Checked = $true
}

$form.Controls.AddRange(@(
    $disableTaskManager,
    $preventPasswordChange,
    $passwordNeverExpires,
    $blockShellHotkeys,
    $logoffOnExit
))

$note = [Windows.Forms.Label]@{
    Left = 20
    Top = 430
    Width = 640
    Height = 55
    Text = 'First sign into this account normally, configure and test the target application, then sign out. Convert replaces Explorer for the selected account.'
}
$form.Controls.Add($note)

$status = [Windows.Forms.Label]@{
    Left = 20
    Top = 505
    Width = 390
    Height = 40
    Text = 'Ready.'
}

$convertButton = [Windows.Forms.Button]@{
    Text = 'Convert / Update'
    Left = 420
    Top = 500
    Width = 115
}

$revertButton = [Windows.Forms.Button]@{
    Text = 'Revert Account'
    Left = 545
    Top = 500
    Width = 115
}

$form.Controls.AddRange(@($status, $convertButton, $revertButton))

$executableDialog = [Windows.Forms.OpenFileDialog]@{
    Filter = 'Executables|*.exe'
}

$pictureDialog = [Windows.Forms.OpenFileDialog]@{
    Filter = 'Pictures/icons/apps|*.ico;*.png;*.jpg;*.jpeg;*.bmp;*.exe|All files|*.*'
}

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

function Refresh-AccountState {
    $user = Get-SelectedUser

    if (-not $user) {
        return
    }

    $data = Read-IniFile $ini
    $metadataSection = "Setup:$($user.Name)"

    $revertButton.Enabled = (
        $data.Contains($metadataSection) -and
        $data[$metadataSection].Converted -eq '1' -and
        $data[$metadataSection].SID -eq $user.SID.Value
    )

    if ($data.Contains($user.Name)) {
        $appTextBox.Text = $data[$user.Name].Executable
        $argumentsTextBox.Text = $data[$user.Name].Arguments
    }
}

$users = Get-LocalUser |
    Where-Object {
        $_.Enabled -and
        $_.Name -notin @('Administrator', 'Guest', 'DefaultAccount', 'WDAGUtilityAccount')
    } |
    Sort-Object Name

foreach ($user in $users) {
    [void]$accountCombo.Items.Add($user.Name)
}

$accountCombo.Add_SelectedIndexChanged({
    Refresh-AccountState
})

if ($accountCombo.Items.Count) {
    $accountCombo.SelectedIndex = 0
}

$browseButton.Add_Click({
    if ($executableDialog.ShowDialog() -eq 'OK') {
        $appTextBox.Text = $executableDialog.FileName
        Set-PicturePreview (Find-PictureCandidate $appTextBox.Text)
    }
})

$autoPictureButton.Add_Click({
    Set-PicturePreview (Find-PictureCandidate $appTextBox.Text)
})

$choosePictureButton.Add_Click({
    if ($pictureDialog.ShowDialog() -eq 'OK') {
        Set-PicturePreview $pictureDialog.FileName
    }
})

$convertButton.Add_Click({
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
            New-ItemProperty `
                $winlogon `
                -Name 'Shell' `
                -PropertyType String `
                -Value ('"' + $shell + '"') `
                -Force | Out-Null

            if ($disableTaskManager.Checked) {
                New-Item $policies -Force | Out-Null
                New-ItemProperty `
                    $policies `
                    -Name 'DisableTaskMgr' `
                    -PropertyType DWord `
                    -Value 1 `
                    -Force | Out-Null
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
        Set-IniValue $data $user.Name 'LogoffOnExit' ([int]$logoffOnExit.Checked)
        Set-IniValue $data $user.Name 'BlockShellHotkeys' ([int]$blockShellHotkeys.Checked)
        Set-IniValue $data $metadataSection 'Converted' 1
        Write-IniFile $data

        $status.Text = "Converted $($user.Name)."
        Refresh-AccountState
    }
    catch {
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Conversion failed') | Out-Null
    }
})

$revertButton.Add_Click({
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
    }
})

[void]$form.ShowDialog()
