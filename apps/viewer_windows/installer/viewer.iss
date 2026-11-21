; The club PC's installer (SPEC 8.6, 10.1), built by tools/brand/brand.ts windows <brand>:
;   ISCC /DAppName=... /DAppId=... /DAppVersion=... /DSourceDir=<Release folder> /DOutputDir=... /DOutputName=...
;        /DIconFile=<app_icon.ico> viewer.iss
; Installs for the current user, without administrator rights; the C++ runtime is in the Release folder already.

#ifndef AppName
  #error Run through tools/brand/brand.ts, which passes the brand: /DAppName= and the rest
#endif

[Setup]
AppId={#AppId}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppName}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename={#OutputName}
SetupIconFile={#IconFile}
UninstallDisplayIcon={app}\viewer_windows.exe
UninstallDisplayName={#AppName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; The program keeps running in the tray of nobody: close it before an update.
CloseApplications=yes

[Languages]
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\viewer_windows.exe"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\viewer_windows.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\viewer_windows.exe"; Description: "{cm:LaunchProgram,{#StringChange(AppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
