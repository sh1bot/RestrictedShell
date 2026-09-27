#requires -version 5.1

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = 'Stop'

if (-not ('RestrictedShell.NativeIcon' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace RestrictedShell {
    public static class NativeIcon {
        [DllImport("shell32.dll", CharSet=CharSet.Unicode)]
        public static extern uint PrivateExtractIcons(string file, int index, int cx, int cy, IntPtr[] icons, uint[] ids, uint count, uint flags);
        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool DestroyIcon(IntPtr icon);
    }
}
'@
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]$identity
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"')
    exit
}

$here = Split-Path -Parent $PSCommandPath
$installDir = Join-Path $env:ProgramData 'RestrictedShell'
$ini = Join-Path $installDir 'RestrictedShell.ini'
$shell = Join-Path $installDir 'RestrictedShell.exe'

function Get-NativeArchitecture {
    switch ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()) {
        'x86' { 'x86' }
        'x64' { 'x64' }
        'arm64' { 'arm64' }
        default { throw 'Unsupported Windows architecture.' }
    }
}

function Install-RestrictedShell {
    $architecture = Get-NativeArchitecture
    $source = Join-Path $here "bin\$architecture\RestrictedShell.exe"
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Missing $architecture shell binary: $source" }
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $shell -Force
    if (-not (Test-Path $ini)) {
        $template = Join-Path $here 'RestrictedShell.ini'
        if (Test-Path $template) { Copy-Item $template $ini }
        else { [IO.File]::WriteAllText($ini, "[RestrictedShell]`r`nLogoffOnExit=1`r`nBlockShellHotkeys=1`r`n", [Text.UTF8Encoding]::new($false)) }
    }
}

function Read-IniFile($Path) {
    $data = [ordered]@{}; $section = ''
    if (Test-Path $Path) {
        foreach ($line in Get-Content $Path) {
            $text = $line.Trim()
            if ($text -match '^\[(.+)\]$') { $section=$matches[1]; if (-not $data.Contains($section)) { $data[$section]=[ordered]@{} } }
            elseif ($section -and $text -match '^([^;#][^=]*)=(.*)$') { $data[$section][$matches[1].Trim()]=$matches[2] }
        }
    }
    return $data
}
function Set-IniValue($Data,$Section,$Key,$Value) { if (-not $Data.Contains($Section)){$Data[$Section]=[ordered]@{}}; $Data[$Section][$Key]=[string]$Value }
function Write-IniFile($Data) {
    $lines=[Collections.Generic.List[string]]::new()
    foreach($section in $Data.Keys){$lines.Add("[$section]");foreach($key in $Data[$section].Keys){$lines.Add("$key=$($Data[$section][$key])")};$lines.Add('')}
    [IO.File]::WriteAllLines($ini,$lines,[Text.UTF8Encoding]::new($false))
}
function Get-ProfilePath($Sid) { $key="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$Sid"; if(Test-Path $key){return [Environment]::ExpandEnvironmentVariables((Get-ItemProperty $key).ProfileImagePath)} }
function Invoke-WithUserHive($Sid,$Profile,[scriptblock]$Body) {
    $loaded="Registry::HKEY_USERS\$Sid"
    if(Test-Path $loaded){&$Body $loaded;return}
    $mount='RS_'+[guid]::NewGuid().ToString('N'); & reg.exe load "HKU\$mount" (Join-Path $Profile 'NTUSER.DAT') | Out-Null
    if($LASTEXITCODE){throw 'Could not load user hive.'}
    try{&$Body "Registry::HKEY_USERS\$mount"}finally{[GC]::Collect();[GC]::WaitForPendingFinalizers();& reg.exe unload "HKU\$mount"|Out-Null}
}
function Save-RegistryValue($Data,$Section,$Path,$Name,$Key){$v=Get-ItemProperty $Path -Name $Name -ErrorAction SilentlyContinue;if($null-ne$v){Set-IniValue $Data $Section $Key $v.$Name}else{Set-IniValue $Data $Section $Key '__MISSING__'}}
function Restore-RegistryValue($Path,$Name,$Value,$Type){if($Value-eq'__MISSING__'){Remove-ItemProperty $Path -Name $Name -ErrorAction SilentlyContinue}else{New-Item $Path -Force|Out-Null;New-ItemProperty $Path -Name $Name -PropertyType $Type -Value $Value -Force|Out-Null}}

function Find-PictureCandidate($Executable) {
    $directory=[IO.Path]::GetDirectoryName($Executable);$base=[IO.Path]::GetFileNameWithoutExtension($Executable)
    foreach($name in @("$base.ico",'app.ico','icon.ico','logo.ico')){$candidate=Join-Path $directory $name;if(Test-Path $candidate){return $candidate}}
    $icons=@(Get-ChildItem $directory -Filter *.ico -File -ErrorAction SilentlyContinue);if($icons.Count-eq1){return $icons[0].FullName}
    foreach($name in @("$base.png",'app.png','icon.png','logo.png','app-icon.png')){$candidate=Join-Path $directory $name;if(Test-Path $candidate){return $candidate}}
    return $Executable
}

function Convert-IconToBitmap($Icon) {
    # Clone while the native icon handle is still valid; callers can then safely destroy it.
    $bitmap=$Icon.ToBitmap()
    return [Drawing.Bitmap]::new($bitmap)
}

function Get-IconBitmap($Path,$Size) {
    $extension=[IO.Path]::GetExtension($Path).ToLowerInvariant()
    if($extension -eq '.ico') {
        # The Icon(file,width,height) constructor asks GDI+ for the best representation
        # in the ICO for the requested dimensions, preserving authored size variants.
        $icon=[Drawing.Icon]::new($Path,$Size,$Size)
        try{return Convert-IconToBitmap $icon}finally{$icon.Dispose()}
    }
    if($extension -eq '.exe') {
        $handles=[IntPtr[]]::new(1);$ids=[uint32[]]::new(1)
        try {
            $count=[RestrictedShell.NativeIcon]::PrivateExtractIcons($Path,0,$Size,$Size,$handles,$ids,1,0)
            if($count-gt0 -and $handles[0]-ne[IntPtr]::Zero){
                $icon=[Drawing.Icon]::FromHandle($handles[0])
                try{return Convert-IconToBitmap $icon}finally{$icon.Dispose()}
            }
        } finally {
            if($handles[0]-ne[IntPtr]::Zero){[void][RestrictedShell.NativeIcon]::DestroyIcon($handles[0])}
        }
        # Some executables do not cooperate with PrivateExtractIcons. Keep the old,
        # reliable associated-icon path as a fallback instead of returning a blank image.
        $fallback=[Drawing.Icon]::ExtractAssociatedIcon($Path)
        if($null-eq$fallback){throw "No icon could be extracted from $Path"}
        try{return Convert-IconToBitmap $fallback}finally{$fallback.Dispose()}
    }
    throw "Not an icon source: $Path"
}

function Get-PictureBitmap($Path,[int]$Size=96) {
    $extension=[IO.Path]::GetExtension($Path).ToLowerInvariant()
    if($extension -in '.ico','.exe'){return Get-IconBitmap $Path $Size}
    $image=[Drawing.Image]::FromFile($Path)
    try {
        if($image.Width-eq$Size -and $image.Height-eq$Size){return [Drawing.Bitmap]::new($image)}
        $bitmap=[Drawing.Bitmap]::new($Size,$Size);$graphics=[Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.Clear([Drawing.Color]::Transparent);$graphics.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $scale=[Math]::Min($Size/[double]$image.Width,$Size/[double]$image.Height);$w=[Math]::Max(1,[int][Math]::Round($image.Width*$scale));$h=[Math]::Max(1,[int][Math]::Round($image.Height*$scale));$x=[int](($Size-$w)/2);$y=[int](($Size-$h)/2)
            $graphics.DrawImage($image,[Drawing.Rectangle]::new($x,$y,$w,$h))
        }finally{$graphics.Dispose()}
        return $bitmap
    }finally{$image.Dispose()}
}

function Install-AccountPicture($Sid,$Source) {
    if(-not$Source -or -not(Test-Path $Source)){return}
    $pictureDir=Join-Path $env:ProgramData "RestrictedShell\AccountPictures\$Sid";$registryKey="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AccountPicture\Users\$Sid"
    New-Item -ItemType Directory -Path $pictureDir -Force|Out-Null;New-Item $registryKey -Force|Out-Null
    foreach($size in 32,40,48,96,192,240,448){
        # Request each size independently so ICO/EXE authored representations are used
        # whenever Windows can supply them. Raster sources are scaled only as necessary.
        $bitmap=Get-PictureBitmap $Source $size
        try{$filename=Join-Path $pictureDir "Image$size.png";$bitmap.Save($filename,[Drawing.Imaging.ImageFormat]::Png);New-ItemProperty $registryKey -Name "Image$size" -PropertyType String -Value $filename -Force|Out-Null}finally{$bitmap.Dispose()}
    }
}

$form=[Windows.Forms.Form]@{Text='Restricted Account Configurator';Width=700;Height=610;StartPosition='CenterScreen';FormBorderStyle='FixedDialog';MaximizeBox=$false};$form.Font=[Drawing.Font]::new('Segoe UI',9)
function Add-Label($Text,$X,$Y){$c=[Windows.Forms.Label]@{Text=$Text;Left=$X;Top=$Y;Width=130};$form.Controls.Add($c)}
function Add-TextBox($X,$Y,$Width){$c=[Windows.Forms.TextBox]@{Left=$X;Top=$Y;Width=$Width};$form.Controls.Add($c);return $c}
Add-Label 'Windows account:' 20 25;$accountCombo=[Windows.Forms.ComboBox]@{Left=155;Top=22;Width=300;DropDownStyle='DropDownList'};$form.Controls.Add($accountCombo)
Add-Label 'Target application:' 20 68;$appTextBox=Add-TextBox 155 65 410;$browseButton=[Windows.Forms.Button]@{Text='Browse...';Left=575;Top=63;Width=85};$form.Controls.Add($browseButton)
Add-Label 'Arguments:' 20 105;$argumentsTextBox=Add-TextBox 155 102 505
Add-Label 'Account picture:' 20 150;$pictureBox=[Windows.Forms.PictureBox]@{Left=155;Top=145;Width=96;Height=96;BorderStyle='FixedSingle';SizeMode='Zoom'};$form.Controls.Add($pictureBox)
$picturePathTextBox=Add-TextBox 270 147 390;$picturePathTextBox.ReadOnly=$true;$choosePictureButton=[Windows.Forms.Button]@{Text='Choose picture...';Left=270;Top=182;Width=130};$autoPictureButton=[Windows.Forms.Button]@{Text='Auto-select';Left=410;Top=182;Width=100};$form.Controls.AddRange(@($choosePictureButton,$autoPictureButton))
$disableTaskManager=[Windows.Forms.CheckBox]@{Text='Disable Task Manager';Left=155;Top=270;Width=250;Checked=$true};$preventPasswordChange=[Windows.Forms.CheckBox]@{Text='User cannot change password';Left=155;Top=300;Width=260;Checked=$true};$passwordNeverExpires=[Windows.Forms.CheckBox]@{Text='Password never expires';Left=155;Top=330;Width=250;Checked=$true};$blockShellHotkeys=[Windows.Forms.CheckBox]@{Text='Block Windows shell/application-switching hotkeys';Left=155;Top=360;Width=370;Checked=$true};$logoffOnExit=[Windows.Forms.CheckBox]@{Text='Log off when target application exits';Left=155;Top=390;Width=320;Checked=$true};$form.Controls.AddRange(@($disableTaskManager,$preventPasswordChange,$passwordNeverExpires,$blockShellHotkeys,$logoffOnExit))
$note=[Windows.Forms.Label]@{Left=20;Top=430;Width=640;Height=55;Text='First sign into this account normally, configure and test the target application, then sign out. Convert replaces Explorer for the selected account.'};$form.Controls.Add($note)
$status=[Windows.Forms.Label]@{Left=20;Top=505;Width=390;Height=40;Text='Ready.'};$convertButton=[Windows.Forms.Button]@{Text='Convert / Update';Left=420;Top=500;Width=115};$revertButton=[Windows.Forms.Button]@{Text='Revert Account';Left=545;Top=500;Width=115};$form.Controls.AddRange(@($status,$convertButton,$revertButton))
$executableDialog=[Windows.Forms.OpenFileDialog]@{Filter='Executables|*.exe'};$pictureDialog=[Windows.Forms.OpenFileDialog]@{Filter='Pictures/icons/apps|*.ico;*.png;*.jpg;*.jpeg;*.bmp;*.exe|All files|*.*'}

function Set-PicturePreview($Path){
    if($pictureBox.Image){$pictureBox.Image.Dispose()};$pictureBox.Image=$null;$picturePathTextBox.Text=$Path
    if($Path){try{$pictureBox.Image=Get-PictureBitmap $Path 96;$status.Text='Picture preview loaded.'}catch{$status.Text="Picture preview failed: $($_.Exception.Message)"}}
}
function Get-SelectedUser{if($accountCombo.SelectedItem){return Get-LocalUser -Name ([string]$accountCombo.SelectedItem)}}
function Refresh-AccountState{$user=Get-SelectedUser;if(-not$user){return};$data=Read-IniFile $ini;$meta="Setup:$($user.Name)";$revertButton.Enabled=$data.Contains($meta)-and$data[$meta].Converted-eq'1'-and$data[$meta].SID-eq$user.SID.Value;if($data.Contains($user.Name)){$appTextBox.Text=$data[$user.Name].Executable;$argumentsTextBox.Text=$data[$user.Name].Arguments}}
Get-LocalUser|Where-Object{$_.Enabled-and$_.Name-notin@('Administrator','Guest','DefaultAccount','WDAGUtilityAccount')}|Sort-Object Name|ForEach-Object{[void]$accountCombo.Items.Add($_.Name)}
$accountCombo.Add_SelectedIndexChanged({Refresh-AccountState});if($accountCombo.Items.Count){$accountCombo.SelectedIndex=0}
$browseButton.Add_Click({if($executableDialog.ShowDialog()-eq'OK'){$appTextBox.Text=$executableDialog.FileName;Set-PicturePreview (Find-PictureCandidate $appTextBox.Text)}})
$autoPictureButton.Add_Click({Set-PicturePreview (Find-PictureCandidate $appTextBox.Text)})
$choosePictureButton.Add_Click({if($pictureDialog.ShowDialog()-eq'OK'){Set-PicturePreview $pictureDialog.FileName}})

$convertButton.Add_Click({
 try{
  Install-RestrictedShell;$user=Get-SelectedUser;if(-not$user){throw'Select an account.'};$profile=Get-ProfilePath $user.SID.Value;if(-not$profile-or-not(Test-Path(Join-Path $profile 'NTUSER.DAT'))){throw'Account profile is not initialized. Sign into it once, then sign out.'};if(-not(Test-Path $appTextBox.Text)){throw'Select a valid target executable.'}
  $data=Read-IniFile $ini;$meta="Setup:$($user.Name)";$first=-not($data.Contains($meta)-and$data[$meta].Converted-eq'1');if($first){Set-IniValue $data $meta SID $user.SID.Value;Set-IniValue $data $meta PreviousUserMayChangePassword ([int]$user.UserMayChangePassword);Set-IniValue $data $meta PreviousPasswordNeverExpires ([int]$user.PasswordNeverExpires)}
  Invoke-WithUserHive $user.SID.Value $profile {param($hive)$winlogon=Join-Path $hive 'Software\Microsoft\Windows NT\CurrentVersion\Winlogon';$policies=Join-Path $hive 'Software\Microsoft\Windows\CurrentVersion\Policies\System';if($first){Save-RegistryValue $data $meta $winlogon Shell PreviousShell;Save-RegistryValue $data $meta $policies DisableTaskMgr PreviousDisableTaskMgr};New-Item $winlogon -Force|Out-Null;New-ItemProperty $winlogon -Name Shell -PropertyType String -Value ('"'+$shell+'"') -Force|Out-Null;if($disableTaskManager.Checked){New-Item $policies -Force|Out-Null;New-ItemProperty $policies -Name DisableTaskMgr -PropertyType DWord -Value 1 -Force|Out-Null}else{Remove-ItemProperty $policies -Name DisableTaskMgr -ErrorAction SilentlyContinue}}
  Set-LocalUser -Name $user.Name -UserMayChangePassword:(-not$preventPasswordChange.Checked) -PasswordNeverExpires:$passwordNeverExpires.Checked;if($picturePathTextBox.Text){Install-AccountPicture $user.SID.Value $picturePathTextBox.Text};Set-IniValue $data $user.Name Executable $appTextBox.Text;Set-IniValue $data $user.Name Arguments $argumentsTextBox.Text;Set-IniValue $data $user.Name LogoffOnExit ([int]$logoffOnExit.Checked);Set-IniValue $data $user.Name BlockShellHotkeys ([int]$blockShellHotkeys.Checked);Set-IniValue $data $meta Converted 1;Write-IniFile $data;$status.Text="Converted $($user.Name).";Refresh-AccountState
 }catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Conversion failed')|Out-Null}
})
$revertButton.Add_Click({
 try{$user=Get-SelectedUser;if(-not$user){throw'Select an account.'};$data=Read-IniFile $ini;$meta="Setup:$($user.Name)";if(-not$data.Contains($meta)-or$data[$meta].SID-ne$user.SID.Value){throw'No valid rollback state.'};$profile=Get-ProfilePath $user.SID.Value;Invoke-WithUserHive $user.SID.Value $profile {param($hive)Restore-RegistryValue (Join-Path $hive 'Software\Microsoft\Windows NT\CurrentVersion\Winlogon') Shell $data[$meta].PreviousShell String;Restore-RegistryValue (Join-Path $hive 'Software\Microsoft\Windows\CurrentVersion\Policies\System') DisableTaskMgr $data[$meta].PreviousDisableTaskMgr DWord};Set-LocalUser -Name $user.Name -UserMayChangePassword:([bool][int]$data[$meta].PreviousUserMayChangePassword) -PasswordNeverExpires:([bool][int]$data[$meta].PreviousPasswordNeverExpires);$data.Remove($user.Name);$data.Remove($meta);Write-IniFile $data;$status.Text="Reverted $($user.Name).";Refresh-AccountState}catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Revert failed')|Out-Null}
})
[void]$form.ShowDialog()
