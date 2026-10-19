[Setup]
AppId={{3C3065D9-B74A-4B06-83DC-AB1595CED735}
AppName=Hongguo
AppVersion={#AppVersion}
DefaultDirName={localappdata}\Programs\Hongguo
DefaultGroupName=Hongguo
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=Hongguo-{#AppVersion}-windows-x64-setup
Compression=lzma2
SolidCompression=yes
UninstallDisplayIcon={app}\hongguo_app.exe
WizardStyle=modern
[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
[Icons]
Name: "{group}\Hongguo"; Filename: "{app}\hongguo_app.exe"
Name: "{userdesktop}\Hongguo"; Filename: "{app}\hongguo_app.exe"; Tasks: desktopicon
[Tasks]
Name: desktopicon; Description: "Create a desktop shortcut"; Flags: unchecked
[Run]
Filename: "{app}\hongguo_app.exe"; Description: "Launch Hongguo"; Flags: nowait postinstall skipifsilent
