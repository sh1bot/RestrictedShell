# RestrictedShell

RestrictedShell converts an existing local Windows user account into a **single-application login**.

When the converted account signs in, Windows starts one configured application instead of the normal Explorer desktop. RestrictedShell can then remove common routes from that application into the rest of Windows: it can block shell and application-switching shortcuts, disable Task Manager for that account, optionally prevent the target application from launching child processes, and log the user off when the target application exits.

It fills a similar niche to kiosk mode, but is intended to be easy to apply to an ordinary local account and later remove again. Other accounts on the PC continue to use Windows normally, and **Revert Account** restores the converted account's recorded shell, Task Manager policy, and password settings.

Typical uses include a supervised child account, a public or library PC running one application, a temporary game/demo station, or an appliance-style application that should not expose the normal Windows desktop.

RestrictedShell also keeps basic volume and microphone controls available even though Explorer is not running.

RestrictedShell is **not a complete application sandbox or application-control system**. It removes convenient escape routes and can add some containment, but the configured application itself must still be suitable for the user. See [Security assumptions and limitations](#security-assumptions-and-limitations) and [Further Windows restrictions](#further-windows-restrictions) if you need stronger controls.

## Download

Download `RestrictedShell.zip` from the repository's **Latest build** release and extract it somewhere accessible to an administrator.

The package contains:

```text
RestrictedShellSetup.ps1
RestrictedShell.ini
README.md
bin\
    x86\RestrictedShell.exe
    x64\RestrictedShell.exe
    arm64\RestrictedShell.exe
scripts\
    InitializeAudioVolumes.ps1
```

The setup program automatically installs the correct native shell binary for the machine.

## Before converting an account

Do not create the restricted account with RestrictedShell. Create and prepare it normally first.

1. In Windows Settings, create the local account that will eventually be restricted.
2. Sign into that account normally while Explorer is still its shell.
3. Install, configure, authenticate, and test the application that the account will use.
4. Complete any first-run setup that creates files, registry entries, caches, licence state, or user-specific configuration.
5. If the application normally needs a browser for authentication or initial setup, complete that now.
6. Sign out of the account.
7. Sign back into an administrator account.

The account must have been signed into at least once so that its Windows profile and `NTUSER.DAT` exist.

Administrator accounts are deliberately excluded from the list of accounts that RestrictedShell can convert. The administrator currently running setup is excluded as well.

## Running the configurator

You can first try right-clicking `RestrictedShellSetup.ps1` and choosing **Run with PowerShell**.

Depending on Windows security settings or PowerShell execution policy, that may be blocked. In that case, open PowerShell in the extracted package directory and run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\RestrictedShellSetup.ps1
```

The script requests elevation automatically if necessary.

Choose the previously prepared account from **Windows account**.

### Target application

Select the `.exe` that should replace the normal Windows desktop for this account.

The target must be in a location that the restricted user cannot modify or replace. `Program Files` is normally suitable. An executable stored in the restricted user's profile, Downloads folder, Desktop, or another user-writable location will be rejected.

**Arguments** are passed to the target application when it is launched.

### Optional pre-run program or script

A pre-run command is useful when something must happen immediately before the main application starts. It runs without the child-process restriction, RestrictedShell waits for it to finish, and the main application is launched only if the pre-run exits with status `0`.

Supported pre-run file types are:

```text
.exe  .com  .bat  .cmd  .ps1  .py  .pyw
```

Batch files use the Windows system `cmd.exe`. PowerShell scripts use the Windows system PowerShell executable.

Python scripts require a machine-wide Python installation. During conversion the configurator resolves and records an absolute, administrator-controlled `python.exe` or `pythonw.exe`. It does not rely on the restricted user's `PATH` or a per-user Python installation.

Like the main application, the pre-run file and Python interpreter must not be writable or replaceable by the restricted user.

Packaged example scripts are installed into:

```text
C:\ProgramData\RestrictedShell\scripts
```

and protected against modification by ordinary users.

### Account picture

Selecting a target application also attempts to choose a suitable account picture automatically.

The configurator prefers, in order:

1. an ICO whose base name matches the executable;
2. a useful embedded executable icon;
3. conventional `app.ico`, `icon.ico`, or `logo.ico` files;
4. a sole ICO in the application directory;
5. conventional PNG artwork.

Known stock PyInstaller and Electron icons are deprioritized. You can override the choice with **Choose picture...**.

Account-picture replacement is currently the one part of conversion that **Revert Account does not restore**.

## Options

### Disable Task Manager

Sets the selected user's `DisableTaskMgr` policy while converted. The previous value is recorded and restored by **Revert Account**.

This is normally enabled for a restricted account.

### User cannot change password

Prevents that local user from changing its own password. The previous setting is restored on revert.

### Password never expires

Sets the corresponding local-account flag. The previous setting is restored on revert.

### Block Windows shell/application-switching hotkeys

When enabled, RestrictedShell consumes Windows-key chords other than the shortcuts it deliberately permits, and also blocks:

```text
Alt+Tab
Alt+Esc
Ctrl+Esc
Ctrl+Shift+Esc
```

`Ctrl+Alt+Del` is not intercepted. `Win+L` remains available.

This option is intended to remove convenient paths back into the normal Windows shell; it is not an application-control system.

### Prevent target application from starting child processes

Launches the **main target application** with the Windows child-process restriction.

The optional pre-run command is not restricted by this setting.

This can be useful when, for example, an otherwise self-contained application contains a "read our terms" link that would normally open a general-purpose web browser.

It can also break legitimate applications that launch helper programs, browser-based authentication, crash handlers, updaters, render processes, or other subprocesses. Leave it off until the target application has been tested with it.

If it causes trouble, return to an administrator account, run the configurator again, clear the checkbox, and choose **Convert / Update**.

This feature is a containment measure, **not a complete sandbox boundary**.

### Enable Win+Alt volume shortcuts (= / - / M)

Dedicated multimedia volume keys are always supported. This option additionally enables ordinary-keyboard fallbacks:

```text
Win+Alt+=    volume up
Win+Alt+-    volume down
Win+Alt+M    speaker/output mute
```

The option is off by default so those combinations remain available to the target application when they are not wanted.

### Log off when target application exits

Normally enabled. When the main target exits, RestrictedShell logs the current account off.

For initial testing it can be useful to clear this option. When it is disabled, RestrictedShell exits when the target exits instead of immediately logging off.

## Converting the account

When everything is configured, click **Convert / Update**.

The button immediately changes to **Working...** and disables itself so there is no need to click it twice.

On a first conversion the configurator performs the safety-sensitive work in this order:

1. install/update RestrictedShell under `C:\ProgramData\RestrictedShell`;
2. validate the target, pre-run command, and interpreter paths;
3. record the account's existing shell, Task Manager policy, and password flags;
4. write the intended RestrictedShell configuration and rollback journal to the protected INI;
5. install the selected account picture, if any;
6. change the user's shell and other selected account settings;
7. mark the conversion complete.

The rollback information is deliberately written **before** the user's shell is changed. INI updates are performed by replacing the file rather than rewriting the live file in place.

If a first conversion fails after system changes have begun, setup attempts to restore the original account settings automatically. If automatic rollback also fails, the rollback journal is retained so **Revert Account** can be used later.

## Testing the converted account

After conversion:

1. Sign out of the administrator account.
2. Sign into the restricted account.
3. Confirm that the intended application starts.
4. Test any pre-run behaviour.
5. Test volume and microphone controls.
6. If enabled, test the child-process restriction, especially authentication and help/T&C links.
7. Exit the target application and confirm that logoff behaviour is as intended.

The normal Explorer desktop should not appear in the converted account.

### Audio controls

RestrictedShell always handles the standard multimedia keys:

```text
Volume Up
Volume Down
Volume Mute
```

For microphone mute:

```text
Win+Alt+K
```

is always supported. A keyboard that exposes the standard Windows dedicated microphone-mute application command is supported as well.

The on-screen display shows the resulting output volume/mute or microphone state.

Audio controls look up the current default endpoint each time they are used, so changing headphones, Bluetooth devices, speakers, or the default microphone does not leave the shell controlling an obsolete endpoint.

## Updating an existing converted account

Run `RestrictedShellSetup.ps1` again as an administrator, select the account, change the desired settings, and click **Convert / Update**.

The original pre-conversion rollback state is retained. Updating an already converted account does not redefine "revert" to mean the previous RestrictedShell configuration; **Revert Account** still means returning to the settings that existed before the first valid conversion.

The setup program also updates the installed native binary and packaged scripts and adds any newly introduced default INI settings that are missing from an older installation.

## Reverting an account

From an administrator account:

1. Run `RestrictedShellSetup.ps1`.
2. Select the converted account.
3. Click **Revert Account**.

Revert restores the recorded:

- per-user Winlogon shell value;
- Task Manager policy value;
- `UserMayChangePassword` setting;
- `PasswordNeverExpires` setting.

It then removes that user's RestrictedShell configuration and rollback section from the shared INI.

Revert currently does **not** restore the account's previous picture.

A deleted and recreated account with the same username is not treated as the original account: rollback metadata is tied to the account SID.

## Example: initialize public and private audio volumes

The package includes:

```text
scripts\InitializeAudioVolumes.ps1
```

This is an example **one-shot pre-run script**. It does not remain resident after startup.

Its purpose is to prepare both likely audio paths before the application starts. For example, a child may log in with headphones attached; if the headphones later fall out, the speaker endpoint should already be at a sociable level rather than inheriting an unexpectedly high volume.

The script reads:

```ini
[AudioDefaults]
PublicVolume=10
PrivateVolume=60
```

It enumerates active and unplugged render endpoints and tries to identify:

- one likely public/room-audible fallback, such as speakers;
- one distinct private endpoint, such as headphones or a headset.

It presets each independently. If it cannot identify a distinct public endpoint, it errs on the quiet side and treats the best available endpoint as public.

To use the packaged copy, select:

```text
C:\ProgramData\RestrictedShell\scripts\InitializeAudioVolumes.ps1
```

as the pre-run program after installation, or select the copy from the extracted package when configuring the account; setup rewrites packaged-script paths to their protected installed location.

A pre-run failure prevents the main target from being launched, so a failed audio-safety initialization is not silently ignored.

## Installed files and permissions

RestrictedShell installs into:

```text
C:\ProgramData\RestrictedShell\
    RestrictedShell.exe
    RestrictedShell.ini
    scripts\...
    AccountPictures\...
```

The installation directory and security-sensitive files have explicit ACLs: Administrators and `SYSTEM` can modify them; ordinary Users receive read/execute access only.

The INI is security-critical because it selects the application and optional unrestricted pre-run command. Do not weaken its permissions or move the launch chain into user-writable locations.

## INI configuration reference

Normally the configurator should edit the INI rather than the restricted user.

Global defaults live in `[RestrictedShell]`; a section whose name matches the Windows username overrides individual values for that account.

Example:

```ini
[RestrictedShell]
LogoffOnExit=1
BlockShellHotkeys=1
PreventChildProcesses=0
StandardKeyboardVolumeShortcuts=0
PreRunExecutable=
PreRunArguments=
PreRunInterpreter=

[alice]
Executable=C:\Program Files\Example\Example.exe
Arguments=--fullscreen
PreRunExecutable=C:\ProgramData\RestrictedShell\scripts\InitializeAudioVolumes.ps1
PreRunArguments=
PreventChildProcesses=1
StandardKeyboardVolumeShortcuts=1
LogoffOnExit=1
BlockShellHotkeys=1

[AudioDefaults]
PublicVolume=10
PrivateVolume=60
```

`PreRunInterpreter` is written by the configurator for Python pre-run scripts. It should not normally be set by hand.

Sections named `[Setup:username]` contain rollback metadata used by the configurator. RestrictedShell itself ignores them. Do not delete or edit those sections while the corresponding account is converted unless you are deliberately abandoning its rollback information.

## Further Windows restrictions

RestrictedShell deliberately does not configure machine-wide application-control or account-scheduling policy. Those controls can be added separately when the deployment needs them.

### AppLocker

If the converted account should be prevented from launching other executables or scripts even when the target application exposes an unexpected launch path, consider supplementing RestrictedShell with **AppLocker**.

AppLocker can allow or deny executables, scripts, Windows Installer files, DLLs, and packaged apps, and rules can be scoped to particular users or groups. Microsoft describes AppLocker as a **defense-in-depth** feature rather than a complete security boundary; for stronger application control Microsoft recommends evaluating App Control for Business.

RestrictedShell does not create, modify, or remove AppLocker rules. Application-control policy can lock administrators out of tools they need for recovery if it is prepared incorrectly, so build and test the policy separately before enforcing it on a machine you care about.

Useful Microsoft documentation:

- [What is AppLocker?](https://learn.microsoft.com/en-us/windows/security/application-security/application-control/app-control-for-business/applocker/what-is-applocker)
- [Requirements to use AppLocker](https://learn.microsoft.com/en-us/windows/security/application-security/application-control/app-control-for-business/applocker/requirements-to-use-applocker)
- [Understanding AppLocker default rules](https://learn.microsoft.com/en-us/windows/security/application-security/application-control/app-control-for-business/applocker/understanding-applocker-default-rules)
- [Understanding AppLocker rule behavior](https://learn.microsoft.com/en-us/windows/security/application-security/application-control/app-control-for-business/applocker/understanding-applocker-rule-behavior)

### Limit when the local account may sign in

Windows can restrict the days and times during which a local account is permitted to sign in. This is independent of RestrictedShell.

For example, from an elevated Command Prompt:

```cmd
net user alice /times:M-F,15:00-20:00;Sa-Su,08:00-20:00
```

resticts `alice` to those sign-in windows. To remove the restriction:

```cmd
net user alice /times:all
```

Windows accepts multiple day/time ranges and requires the times to be specified in one-hour increments. See Microsoft's [`net user` documentation](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/net-user) for the complete syntax.

The `/times` setting controls when the account is permitted to sign in. Environments that also need Windows to lock, disconnect, or log off a session when permitted hours expire can consult Microsoft's [LogonHours policy documentation](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-winlogon#logonhourspolicydescription) and check its edition/deployment requirements.

## Security assumptions and limitations

RestrictedShell deliberately removes convenient access to Explorer and common shell shortcuts, but it is not intended to replace Windows application-control or sandbox technologies.

In particular:

- The configured target application itself must be appropriate for the user. If it contains a file picker, embedded terminal, scripting engine, plugin loader, unrestricted web browser, or another path to general-purpose execution, RestrictedShell cannot generically make that feature safe.
- The target, pre-run command, interpreter, and security-critical configuration must remain administrator-controlled. The configurator checks common writable/replacement cases before conversion.
- `PreventChildProcesses` stops normal child-process creation by the target but is not a complete security boundary for a sufficiently capable hostile process.
- `Ctrl+Alt+Del` remains a Windows secure attention sequence and is not intercepted by RestrictedShell. Configure Windows/account policy appropriately for the intended deployment.
- Account-picture state is not included in rollback.

For a supervised child/appliance use case, these restrictions are intended to complement sensible Windows account permissions and a deliberately chosen target application.

## Building from source

Visual Studio C++ build tools are required.

From a Visual Studio installation with the required toolchains available, run:

```cmd
src\build-all.bat
```

This produces:

```text
bin\x86\RestrictedShell.exe
bin\x64\RestrictedShell.exe
bin\arm64\RestrictedShell.exe
```

The runtime deliberately avoids the normal CRT startup and remains small, while the release build still enables stack-cookie protection, Control Flow Guard, DEP, and ASLR.

GitHub Actions builds all three architectures, validates the PowerShell scripts and embedded Core Audio C#, packages the result, and publishes the moving **Latest build** for pushes to `main`. Tags matching `v*` create/update versioned releases.
