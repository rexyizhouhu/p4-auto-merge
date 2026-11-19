#ifndef PackageDir
  #error PackageDir is required
#endif
#ifndef OutputDir
  #error OutputDir is required
#endif
#ifndef AppVersion
  #error AppVersion is required
#endif
#ifdef ValidationRoot
  #define InstallerId "P4AM.Test." + ValidationId
  #define AppLabel "P4AutoMerge Installer Validation"
  #define DesktopRoot ValidationRoot + "\Desktop"
  #define MenuRoot ValidationRoot + "\StartMenu"
  #define OutputStem "P4AutoMerge-Validation"
#else
  #define InstallerId "FlamesTools.P4AutoMerge"
  #define AppLabel "P4 自动合并工具"
  #define DesktopRoot "{userdesktop}"
  #define MenuRoot "{userprograms}\P4 自动合并工具"
  #define OutputStem "P4AutoMerge-" + AppVersion + "-Setup-x64"
#endif

[Setup]
AppId={#InstallerId}
AppName={#AppLabel}
AppVersion={#AppVersion}
AppPublisher=FlamesTools
DefaultDirName={localappdata}\Programs\P4AutoMerge
DefaultGroupName=P4 自动合并工具
DisableDirPage=no
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
SetupArchitecture=x64
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
WizardStyle=modern dynamic
OutputDir={#OutputDir}
OutputBaseFilename={#OutputStem}
Compression=lzma2
SolidCompression=yes
SetupLogging=yes
UninstallDisplayIcon={app}\P4AutoMerge.exe
AppMutex=Local\FlamesTools.P4AutoMerge.Running
CloseApplications=no
RestartApplications=no

[Languages]
Name: "chinesesimp"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "在桌面创建快捷方式"; GroupDescription: "快捷方式："

[Files]
Source: "{#PackageDir}\P4AutoMerge.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PackageDir}\使用说明.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PackageDir}\release.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PackageDir}\SHA256SUMS.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PackageDir}\.p4ignore"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{#DesktopRoot}\P4 自动合并工具"; Filename: "{app}\P4AutoMerge.exe"; WorkingDir: "{app}"; Tasks: desktopicon
Name: "{#MenuRoot}\P4 自动合并工具"; Filename: "{app}\P4AutoMerge.exe"; WorkingDir: "{app}"
Name: "{#MenuRoot}\卸载 P4 自动合并工具"; Filename: "{uninstallexe}"

[Run]
Filename: "{app}\P4AutoMerge.exe"; Description: "启动 P4 自动合并工具"; Flags: nowait postinstall skipifsilent

[Code]
function InitializeSetup(): Boolean;
begin
  Result := IsDotNetInstalled(net48, 0);
  if not Result then
    MsgBox('需要先安装 Microsoft .NET Framework 4.8。', mbError, MB_OK);
end;
