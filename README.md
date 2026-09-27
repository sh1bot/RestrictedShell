# RestrictedShell

A small alternative Windows login shell for a deliberately restricted local account. It launches one configured application, supplies volume/speaker-mute/microphone-mute handling with an OSD, and can log the account off when the application exits.

## Build

Run `src\build-all.bat` with the Visual Studio C++ toolchain installed. It builds separate x86, x64, and ARM64 executables under `bin\`.

The GitHub Actions workflow also builds all three architectures automatically and publishes a `RestrictedShell-bundle` workflow artifact.

## Setup workflow

1. Create the intended Windows account normally.
2. Sign into it and configure/test the target application.
3. Sign out and return to an administrator account.
4. Run `RestrictedShellSetup.ps1` and select the existing account.
5. Convert the account. The matching native binary, active INI, and packaged example scripts are installed under `C:\ProgramData\RestrictedShell`.
6. `Revert Account` restores the rollback state recorded by the configurator for supported settings.

The selected account picture is installed during conversion; the current revert operation does not restore the previous picture.

## Configuration

`RestrictedShell.ini` supports global defaults in `[RestrictedShell]` and per-account overrides in `[username]`, including `Executable`, `Arguments`, `PreRunExecutable`, `PreRunArguments`, `PreventChildProcesses`, `StandardKeyboardVolumeShortcuts`, `LogoffOnExit`, and `BlockShellHotkeys`.

Configurator rollback metadata is stored in `[Setup:username]` sections and is ignored by RestrictedShell.

## Example pre-run scripts

Packaged scripts are installed under `C:\ProgramData\RestrictedShell\scripts` and are intended as examples that can be selected as the optional pre-run program/script.

`InitializeAudioVolumes.ps1` reads the shared INI section:

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
