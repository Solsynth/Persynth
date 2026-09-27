; ==================================================
; Defaults only: the release workflow passes the real
; values from pubspec.yaml as /DAppVersion and /DBuildNumber.
#define AppVersion "1.0.0"
#define BuildNumber "1"
; ==================================================

#define FullVersion AppVersion + "." + BuildNumber

[Setup]
AppName=Persynth
AppVersion={#AppVersion}
AppPublisher=dev.solsynth
AppPublisherURL=https://solsynth.dev
AppUpdatesURL=https://github.com/Solsynth/SynthPet/releases
AppCopyright=Copyright © 2026 dev.solsynth
VersionInfoVersion={#FullVersion}
UninstallDisplayName=Persynth
UninstallDisplayIcon={app}\persynth.exe

DefaultDirName={commonpf}\Persynth
UsePreviousAppDir=no

OutputDir=.\Installer
OutputBaseFilename=windows-x86_64-setup
SetupIconFile=.\assets\icons\icon.ico

Compression=lzma2/ultra64
SolidCompression=yes
LZMAUseSeparateProcess=yes
LZMANumBlockThreads=4

ArchitecturesAllowed=x64compatible
PrivilegesRequired=admin

[Files]
Source: ".\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Persynth"; Filename: "{app}\persynth.exe"; IconFilename: "{app}\persynth.exe"
Name: "{group}\{cm:UninstallProgram,Persynth}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\Persynth"; Filename: "{app}\persynth.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Run]
Filename: "{app}\persynth.exe"; Description: "Launch Persynth"; Flags: nowait postinstall skipifsilent

; Stop the app before removing files locked by Flutter/the embedded browser.
[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/F /T /IM persynth.exe"; Flags: runhidden waituntilterminated skipifdoesntexist

[UninstallDelete]
Type: filesandordirs; Name: "{userappdata}\dev.solsynth\persynth"
Type: files; Name: "{group}\Persynth.lnk"
Type: files; Name: "{autodesktop}\Persynth.lnk"
