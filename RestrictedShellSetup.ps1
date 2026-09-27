#requires -version 5.1
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$ErrorActionPreference='Stop'
$me=[Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if(-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
 Start-Process powershell.exe -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+$PSCommandPath+'"');exit
}
$here=Split-Path -Parent $PSCommandPath
$installDir=Join-Path $env:ProgramData 'RestrictedShell'
$ini=Join-Path $installDir 'RestrictedShell.ini'
$shell=Join-Path $installDir 'RestrictedShell.exe'

function Get-NativeArchitecture {
 $a=[System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
 switch($a){
  'x86'   { 'x86' }
  'x64'   { 'x64' }
  'arm64' { 'arm64' }
  default { throw "Unsupported Windows architecture: $a" }
 }
}
function Install-RestrictedShell {
 $arch=Get-NativeArchitecture
 $source=Join-Path $here ("bin\"+$arch+"\RestrictedShell.exe")
 if(-not(Test-Path -LiteralPath $source -PathType Leaf)){
  throw "The $arch RestrictedShell binary is missing: $source`r`nBuild all architectures first with src\build-all.bat."
 }
 New-Item -ItemType Directory -Path $installDir -Force|Out-Null
 Copy-Item -LiteralPath $source -Destination $shell -Force
 if(-not(Test-Path -LiteralPath $ini)){
  $template=Join-Path $here 'RestrictedShell.ini'
  if(Test-Path -LiteralPath $template){Copy-Item -LiteralPath $template -Destination $ini}
  else{[IO.File]::WriteAllText($ini,"[RestrictedShell]`r`nLogoffOnExit=1`r`nBlockShellHotkeys=1`r`n",[Text.UTF8Encoding]::new($false))}
 }
}
function ReadIni{param($p)$d=[ordered]@{};$s='';if(Test-Path $p){foreach($l in Get-Content $p){$t=$l.Trim();if($t-match'^\[(.+)\]$'){$s=$matches[1];if(-not$d.Contains($s)){$d[$s]=[ordered]@{}}}elseif($s-and$t-match'^([^;#][^=]*)=(.*)$'){$d[$s][$matches[1].Trim()]=$matches[2]}}};$d}
function SetI($d,$s,$k,$v){if(-not$d.Contains($s)){$d[$s]=[ordered]@{}};$d[$s][$k]=[string]$v}
function WriteIni($d){$o=[Collections.Generic.List[string]]::new();foreach($s in $d.Keys){$o.Add("[$s]");foreach($k in $d[$s].Keys){$o.Add("$k=$($d[$s][$k])")};$o.Add('')};[IO.File]::WriteAllLines($ini,$o,[Text.UTF8Encoding]::new($false))}
function Profile($sid){$k="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid";if(Test-Path $k){[Environment]::ExpandEnvironmentVariables((Get-ItemProperty $k).ProfileImagePath)}}
function Hive($sid,$prof,[scriptblock]$b){$h="Registry::HKEY_USERS\$sid";if(Test-Path $h){&$b $h;return};$m='RS_'+[guid]::NewGuid().ToString('N');reg load "HKU\$m" (Join-Path $prof NTUSER.DAT)|Out-Null;if($LASTEXITCODE){throw'Could not load user hive.'};try{&$b "Registry::HKEY_USERS\$m"}finally{[gc]::Collect();[gc]::WaitForPendingFinalizers();reg unload "HKU\$m"|Out-Null}}
function SaveV($d,$m,$p,$n,$k){$x=Get-ItemProperty $p -Name $n -ErrorAction SilentlyContinue;if($null-ne$x){SetI $d $m $k $x.$n}else{SetI $d $m $k '__MISSING__'}}
function RestoreV($p,$n,$v,$type){if($v-eq'__MISSING__'){Remove-ItemProperty $p -Name $n -ErrorAction SilentlyContinue}else{New-Item $p -Force|Out-Null;New-ItemProperty $p -Name $n -PropertyType $type -Value $v -Force|Out-Null}}
function PicCandidate($e) {
 $d = [IO.Path]::GetDirectoryName($e)
 $b = [IO.Path]::GetFileNameWithoutExtension($e)
 foreach($n in @("$b.ico", 'app.ico', 'icon.ico', 'logo.ico')) {
  $x = Join-Path $d $n
  if(Test-Path $x) { return $x }
 }
 $i = @(Get-ChildItem $d -Filter *.ico -File -ErrorAction SilentlyContinue)
 if($i.Count -eq 1) { return $i[0].FullName }
 foreach($n in @("$b.png", 'app.png', 'icon.png', 'logo.png', 'app-icon.png')) {
  $x = Join-Path $d $n
  if(Test-Path $x) { return $x }
 }
 return $e
}
function Bitmap($p){$e=[IO.Path]::GetExtension($p).ToLower();if($e-in'.exe','.ico'){$i=if($e-eq'.exe'){[Drawing.Icon]::ExtractAssociatedIcon($p)}else{[Drawing.Icon]::new($p)};try{$i.ToBitmap()}finally{$i.Dispose()}}else{$i=[Drawing.Image]::FromFile($p);try{[Drawing.Bitmap]::new($i)}finally{$i.Dispose()}}}
function InstallPicture($sid,$source){
 if(-not$source-or-not(Test-Path $source)){return}
 $src=Bitmap $source;if(-not$src){throw'Could not read selected account picture.'}
 $dir=Join-Path $env:ProgramData "RestrictedShell\AccountPictures\$sid"
 $rk="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AccountPicture\Users\$sid"
 New-Item -ItemType Directory -Path $dir -Force|Out-Null
 New-Item $rk -Force|Out-Null
 try{
  foreach($n in 32,40,48,96,192,240,448){
   $b=[Drawing.Bitmap]::new($n,$n)
   try{
    $g=[Drawing.Graphics]::FromImage($b)
    try{
     $g.Clear([Drawing.Color]::Transparent)
     $g.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
     $g.DrawImage($src,[Drawing.Rectangle]::new(0,0,$n,$n))
    }finally{$g.Dispose()}
    $fn=Join-Path $dir "Image$n.png"
    $b.Save($fn,[Drawing.Imaging.ImageFormat]::Png)
    New-ItemProperty $rk -Name "Image$n" -PropertyType String -Value $fn -Force|Out-Null
   }finally{$b.Dispose()}
  }
 }finally{$src.Dispose()}
}
$f=[Windows.Forms.Form]@{Text='Restricted Account Configurator';Width=700;Height=610;StartPosition='CenterScreen';FormBorderStyle='FixedDialog';MaximizeBox=$false};$f.Font=[Drawing.Font]::new('Segoe UI',9)
function L($t,$x,$y){$c=[Windows.Forms.Label]@{Text=$t;Left=$x;Top=$y;Width=130};$f.Controls.Add($c)}
function T($x,$y,$w){$c=[Windows.Forms.TextBox]@{Left=$x;Top=$y;Width=$w};$f.Controls.Add($c);$c}
L 'Windows account:' 20 25;$acct=[Windows.Forms.ComboBox]@{Left=155;Top=22;Width=300;DropDownStyle='DropDownList'};$f.Controls.Add($acct)
L 'Target application:' 20 68;$app=T 155 65 410;$browse=[Windows.Forms.Button]@{Text='Browse...';Left=575;Top=63;Width=85};$f.Controls.Add($browse)
L 'Arguments:' 20 105;$argumentsTextBox=T 155 102 505
L 'Account picture:' 20 150;$pic=[Windows.Forms.PictureBox]@{Left=155;Top=145;Width=96;Height=96;BorderStyle='FixedSingle';SizeMode='Zoom'};$f.Controls.Add($pic);$pp=T 270 147 390;$pp.ReadOnly=$true
$choose=[Windows.Forms.Button]@{Text='Choose picture...';Left=270;Top=182;Width=130};$auto=[Windows.Forms.Button]@{Text='Auto-select';Left=410;Top=182;Width=100};$f.Controls.AddRange(@($choose,$auto))
$task=[Windows.Forms.CheckBox]@{Text='Disable Task Manager';Left=155;Top=270;Width=250;Checked=$true}
$nochg=[Windows.Forms.CheckBox]@{Text='User cannot change password';Left=155;Top=300;Width=260;Checked=$true}
$never=[Windows.Forms.CheckBox]@{Text='Password never expires';Left=155;Top=330;Width=250;Checked=$true}
$block=[Windows.Forms.CheckBox]@{Text='Block Windows shell/application-switching hotkeys';Left=155;Top=360;Width=370;Checked=$true}
$logoff=[Windows.Forms.CheckBox]@{Text='Log off when target application exits';Left=155;Top=390;Width=320;Checked=$true};$f.Controls.AddRange(@($task,$nochg,$never,$block,$logoff))
$note=[Windows.Forms.Label]@{Left=20;Top=430;Width=640;Height=55;Text='First sign into this account normally, configure and test the target application, then sign out. Convert replaces Explorer for the selected account.'};$f.Controls.Add($note)
$status=[Windows.Forms.Label]@{Left=20;Top=505;Width=390;Height=40;Text='Ready.'};$cv=[Windows.Forms.Button]@{Text='Convert / Update';Left=420;Top=500;Width=115};$rv=[Windows.Forms.Button]@{Text='Revert Account';Left=545;Top=500;Width=115};$f.Controls.AddRange(@($status,$cv,$rv))
$ofd=[Windows.Forms.OpenFileDialog]@{Filter='Executables|*.exe'};$pfd=[Windows.Forms.OpenFileDialog]@{Filter='Pictures/icons/apps|*.ico;*.png;*.jpg;*.jpeg;*.bmp;*.exe|All files|*.*'}
function SetPic($p){if($pic.Image){$pic.Image.Dispose()};$pic.Image=$null;$pp.Text=$p;if($p){try{$pic.Image=Bitmap $p}catch{}}}
function U{if($acct.SelectedItem){Get-LocalUser -Name ([string]$acct.SelectedItem)}}
function State{$u=U;if(-not$u){return};$d=ReadIni $ini;$m="Setup:$($u.Name)";$rv.Enabled=$d.Contains($m)-and$d[$m].Converted-eq'1'-and$d[$m].SID-eq$u.SID.Value;if($d.Contains($u.Name)){$app.Text=$d[$u.Name].Executable;$argumentsTextBox.Text=$d[$u.Name].Arguments}}
Get-LocalUser|?{$_.Enabled-and$_.Name-notin@('Administrator','Guest','DefaultAccount','WDAGUtilityAccount')}|sort Name|%{[void]$acct.Items.Add($_.Name)};$acct.Add_SelectedIndexChanged({State});if($acct.Items.Count){$acct.SelectedIndex=0}
$browse.Add_Click({if($ofd.ShowDialog()-eq'OK'){$app.Text=$ofd.FileName;SetPic (PicCandidate $app.Text)}});$auto.Add_Click({SetPic (PicCandidate $app.Text)});$choose.Add_Click({if($pfd.ShowDialog()-eq'OK'){SetPic $pfd.FileName}})
$cv.Add_Click({try{Install-RestrictedShell;$u=U;$prof=Profile $u.SID.Value;if(-not$prof-or-not(Test-Path (Join-Path $prof NTUSER.DAT))){throw'Account profile is not initialized. Sign into it once, then sign out.'};if(-not(Test-Path $app.Text)){throw'Select a valid target executable.'};$d=ReadIni $ini;$m="Setup:$($u.Name)";$first=-not($d.Contains($m)-and$d[$m].Converted-eq'1');if($first){SetI $d $m SID $u.SID.Value;SetI $d $m PreviousUserMayChangePassword ([int]$u.UserMayChangePassword);SetI $d $m PreviousPasswordNeverExpires ([int]$u.PasswordNeverExpires)}
Hive $u.SID.Value $prof {param($h)$wp=Join-Path $h 'Software\Microsoft\Windows NT\CurrentVersion\Winlogon';$tp=Join-Path $h 'Software\Microsoft\Windows\CurrentVersion\Policies\System';if($first){SaveV $d $m $wp Shell PreviousShell;SaveV $d $m $tp DisableTaskMgr PreviousDisableTaskMgr};New-Item $wp -Force|Out-Null;New-ItemProperty $wp -Name Shell -PropertyType String -Value ('"'+$shell+'"') -Force|Out-Null;if($task.Checked){New-Item $tp -Force|Out-Null;New-ItemProperty $tp -Name DisableTaskMgr -PropertyType DWord -Value 1 -Force|Out-Null}else{Remove-ItemProperty $tp -Name DisableTaskMgr -ErrorAction SilentlyContinue}}
Set-LocalUser -Name $u.Name -UserMayChangePassword:(-not$nochg.Checked) -PasswordNeverExpires:$never.Checked;if($pp.Text){InstallPicture $u.SID.Value $pp.Text};SetI $d $u.Name Executable $app.Text;SetI $d $u.Name Arguments $argumentsTextBox.Text;SetI $d $u.Name LogoffOnExit ([int]$logoff.Checked);SetI $d $u.Name BlockShellHotkeys ([int]$block.Checked);SetI $d $m Converted 1;WriteIni $d;$status.Text="Converted $($u.Name).";State}catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Conversion failed')|Out-Null}})
$rv.Add_Click({try{$u=U;$d=ReadIni $ini;$m="Setup:$($u.Name)";if(-not$d.Contains($m)-or$d[$m].SID-ne$u.SID.Value){throw'No valid rollback state.'};$prof=Profile $u.SID.Value;Hive $u.SID.Value $prof {param($h)RestoreV (Join-Path $h 'Software\Microsoft\Windows NT\CurrentVersion\Winlogon') Shell $d[$m].PreviousShell String;RestoreV (Join-Path $h 'Software\Microsoft\Windows\CurrentVersion\Policies\System') DisableTaskMgr $d[$m].PreviousDisableTaskMgr DWord};Set-LocalUser -Name $u.Name -UserMayChangePassword:([bool][int]$d[$m].PreviousUserMayChangePassword) -PasswordNeverExpires:([bool][int]$d[$m].PreviousPasswordNeverExpires);$d.Remove($u.Name);$d.Remove($m);WriteIni $d;$status.Text="Reverted $($u.Name).";State}catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Revert failed')|Out-Null}})
[void]$f.ShowDialog()
