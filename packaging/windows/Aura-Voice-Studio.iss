#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif

#define AppName "Aura Voice Studio"
#define AppExe "aura_voice_ai.exe"

[Setup]
AppId={{A6E1A143-4C2E-46BD-8C98-2B0D7F8DCA31}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=Aura Voice Studio
DefaultDirName={autopf}\Aura Voice Studio
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
PrivilegesRequired=admin
OutputDir=..\..\dist\installer
OutputBaseFilename=Aura-Voice-Studio-Setup-x64
SetupLogging=yes
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\{#AppExe}
CloseApplications=yes
RestartApplications=no
ChangesAssociations=no

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "..\..\app\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\..\dist\prerequisites\vc_redist.x64.exe"; DestDir: "{app}\_prerequisites"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\Aura Voice Studio"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"
Name: "{autodesktop}\Aura Voice Studio"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\_prerequisites\vc_redist.x64.exe"; Parameters: "/install /quiet /norestart"; StatusMsg: "Installing Microsoft Visual C++ runtime..."; Flags: runhidden waituntilterminated
Filename: "{app}\{#AppExe}"; Description: "Launch Aura Voice Studio"; WorkingDir: "{app}"; Flags: postinstall nowait skipifsilent

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/F /T /IM aura-ai-server.exe"; Flags: runhidden waituntilterminated; RunOnceId: "StopAuraAiServer"

[UninstallDelete]
Type: filesandordirs; Name: "{app}\_prerequisites"
