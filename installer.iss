; Inno Setup script (design/windows-port.md W13) — per-user install, no
; elevation, unsigned (SmartScreen notes go in the release notes, C3).
; Build: iscc /DMyAppVersion=1.8.0 installer.iss
; (build.ps1 package passes the version from Sources/Core/Version.swift.)

#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif

[Setup]
AppId={{8F5B7A64-5D9E-4C1B-9B1E-2C7D41F0A311}}
AppName=Pokémon Mouse Follower
AppVersion={#MyAppVersion}
AppPublisher=LimFull
AppPublisherURL=https://github.com/LimFull/pokemon-mouse-follower
; {autopf} follows the chosen mode: per-user (default, no elevation) installs
; under %LOCALAPPDATA%\Programs, "all users" under Program Files. The dir page
; lets the user pick any location; upgrades reuse the previous dir/mode.
DefaultDirName={autopf}\PokemonMouseFollower
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog commandline
DisableProgramGroupPage=yes
DisableDirPage=no
OutputDir=build-win
OutputBaseFilename=PokemonMouseFollower-Setup
SetupIconFile=res\app.ico
UninstallDisplayIcon={app}\PokemonMouseFollower.exe
Compression=lzma2
SolidCompression=yes
; The updater runs this silently while the app is alive: close it, swap, relaunch.
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "korean"; MessagesFile: "compiler:Languages\Korean.isl"
Name: "japanese"; MessagesFile: "compiler:Languages\Japanese.isl"

[Files]
Source: "build-win\PokemonMouseFollower\*"; DestDir: "{app}"; \
    Excludes: "build-log.txt,build-err.txt,sources.rsp,*.lib,*.exp"; \
    Flags: recursesubdirs ignoreversion

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Icons]
; ASCII shortcut names: Windows Start-menu search misses the accented
; "Pokémon" when users type "pokemon".
Name: "{userprograms}\Pokemon Mouse Follower"; Filename: "{app}\PokemonMouseFollower.exe"
Name: "{userdesktop}\Pokemon Mouse Follower"; Filename: "{app}\PokemonMouseFollower.exe"; Tasks: desktopicon

[Run]
; Interactive install: offer to launch. Silent (self-update): always relaunch.
Filename: "{app}\PokemonMouseFollower.exe"; Description: "{cm:LaunchProgram,Pokémon Mouse Follower}"; \
    Flags: nowait postinstall skipifsilent
Filename: "{app}\PokemonMouseFollower.exe"; Flags: nowait; Check: WizardSilent
