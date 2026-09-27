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
5. Convert the account. The matching native binary and active INI are installed under `C:\ProgramData\RestrictedShell`.
6. `Revert Account` restores the rollback state recorded by the configurator for supported settings.

The selected account picture is installed during conversion; the current revert operation does not restore the previous picture.

## Configuration

`RestrictedShell.ini` supports global defaults in `[RestrictedShell]` and per-account overrides in `[username]`, including `Executable`, `Arguments`, `LogoffOnExit`, and `BlockShellHotkeys`.

Configurator rollback metadata is stored in `[Setup:username]` sections and is ignored by RestrictedShell.
