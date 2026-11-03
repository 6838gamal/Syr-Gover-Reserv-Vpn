; ============================================
;  Inno Setup Script - Syr Gover Reserv VPN
; ============================================

#define AppName "Syr Gover Reserv VPN"
#define AppVersion "1.0.0"
#define AppPublisher "MyCompany"
#define AppExeName "SyrGoverReservVpn.exe"   ; ← طابق BINARY_NAME
#define BuildDir "build\windows\x64\runner\Release"

[Setup]
AppId={{8F3A9C21-4B7D-4E6A-9C1F-2D5E8A7B3C10}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
OutputDir=build\installer
OutputBaseFilename={#AppName}-Setup-{#AppVersion}
Compression=lzma2/ultra
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

; --- تحسينات ---
SetupIconFile=windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExeName}
CloseApplications=yes
RestartApplications=no
AppMutex={#AppName}Mutex

; --- صلاحيات: اختر واحدة ---
; PrivilegesRequired=admin      ; إذا VPN يحتاج تعديل شبكة
PrivilegesRequired=lowest       ; إذا يعتمد على HKCU فقط (launch_at_startup)

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
