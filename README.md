# RestrictedShell

A small alternative Windows login shell for a deliberately restricted local account. It launches one configured application, supplies volume/speaker-mute/microphone-mute handling with an OSD, and can log the account off when the application exits.

## Build

Run `src\build-all.bat` with the Visual Studio C++ toolchain installed. It builds separate x86, x64, and ARM64 executables under `bin\`.

GitHub Actions builds all three architectures automatically and publishes a `RestrictedShell-bundle` workflow artifact. Main-branch builds also replace the prerelease named `latest`; `v*` tags create versioned releases.

## Setup workflow

1. Create the intended Windows account normally.
2. Sign into it and configure/test the target application.
3. Sign out and return to an administrator account.
4. Run `RestrictedShellSetup.ps1` and select the existing account.
5. Convert the account. The matching native binary, active INI, and packaged example scripts are installed under `C:\ProgramData\RestrictedShell`.
6. `Revert Account` restores the rollback state recorded by the configurator for supported settings.

Administrator accounts and the administrator currently running setup are not offered as conversion targets. The selected target application, pre-run program/script, and any Python interpreter used for a Python pre-run must be in locations the restricted account cannot write or replace. Packaged scripts are copied into the protected RestrictedShell installation before use.

Before a first conversion changes the user's Winlogon shell, the configurator writes the intended launch configuration and rollback state to the protected INI. INI replacement is atomic. If setup fails after system changes begin, it attempts to restore the original shell, Task Manager policy, and password flags automatically. The persisted rollback journal also allows `Revert Account` to recover a conversion interrupted by a crash or reboot.

The selected account picture is installed during conversion; the current revert operation does not restore the previous picture.

## Configuration

`RestrictedShell.ini` supports global defaults in `[RestrictedShell]` and per-account overrides in `[username]`, including:

- `Executable`
- `Arguments`
- `PreRunExecutable`
- `PreRunArguments`
- `PreRunInterpreter`
- `PreventChildProcesses`
- `StandardKeyboardVolumeShortcuts`
- `LogoffOnExit`
- `BlockShellHotkeys`

Configurator rollback metadata is stored in `[Setup:username]` sections and is ignored by RestrictedShell.

The setup tool adds newly introduced default keys to an existing installed INI rather than requiring the INI to be recreated.

## Input handling

Dedicated speaker volume up/down/mute keys are always supported. Win+Alt+K toggles the default communications microphone, and keyboards that expose the standard Windows microphone-mute application command are supported as well.

The optional `StandardKeyboardVolumeShortcuts` setting enables these additional 104-key mappings:

```text
Win+Alt+=    volume up
Win+Alt+-    volume down
Win+Alt+M    speaker mute
```

When `BlockShellHotkeys=1`, RestrictedShell consumes all other Win-key chords after handling its explicitly allowed shortcuts, plus Alt+Tab, Alt+Esc, Ctrl+Esc, and Ctrl+Shift+Esc. Win+L remains available.

Audio controls reacquire the current default endpoint when a key is pressed, so a changed headphone, speaker, Bluetooth, or microphone default does not leave the controls bound to the old device.

## Pre-run programs and scripts

The optional pre-run stage runs before the main target and must exit with status 0. RestrictedShell continues pumping its Windows message queue while it waits, so keyboard restrictions remain active during a long-running pre-run.

Supported pre-run types are `.exe`, `.com`, `.bat`, `.cmd`, `.ps1`, `.py`, and `.pyw`. Batch files use the fixed system `cmd.exe`, and PowerShell scripts use the fixed Windows PowerShell executable. Python scripts use an absolute machine-wide interpreter path resolved and security-checked by the configurator; RestrictedShell does not search the restricted user's `PATH` at login.

## Child-process restriction

`PreventChildProcesses=1` launches the main target with Windows' child-process restriction. This is useful for appliance-style applications that should not casually open a web browser or helper executable.

It is **not a complete sandbox or application-control boundary**. It can also break legitimate applications that need helper processes, authentication browsers, crash handlers, or updaters. The option is therefore off by default and can be disabled later by an administrator with Convert / Update.

## Example pre-run script

Packaged scripts are installed under `C:\ProgramData\RestrictedShell\scripts` and can be selected as the optional pre-run program/script.

`InitializeAudioVolumes.ps1` reads:

```ini
[AudioDefaults]
PublicVolume=10
PrivateVolume=60
```

It enumerates active and unplugged render endpoints, chooses a likely room-audible fallback and a distinct headphone/headset-style private endpoint when available, then presets both before the target application starts. If Windows exposes no distinct public endpoint, it conservatively treats the best available endpoint as public and applies `PublicVolume`.

A typical configured account can use:

```ini
PreRunExecutable=C:\ProgramData\RestrictedShell\scripts\InitializeAudioVolumes.ps1
PreRunArguments=
```
