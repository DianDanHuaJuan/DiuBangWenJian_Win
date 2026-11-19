; 铥棒文件 Windows 安装包脚本（Inno Setup 6）
; 编译前请先执行 flutter build windows --release，或使用 build_installer.ps1

#ifndef MyAppVersion
  #define MyAppVersion "0.1.0"
#endif

#ifndef MyAppVersionFull
  #define MyAppVersionFull "0.1.0+1"
#endif

#define MyAppName "铥棒文件"
#define MyAppDirName "DiuBangWenJian"
#define MyAppPublisher "铥棒文件"
#define MyAppExeName "diubangwenjian.exe"
#define MyAppId "{{B7E2D4A9-5C1F-4E8B-9A3D-6F0C8E2B1D47}"
#define ReleaseDir "..\..\build\windows\x64\runner\Release"

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersionFull}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppDirName}
DefaultGroupName={#MyAppName}
AllowNoIcons=yes
OutputDir=output
OutputBaseFilename=DiuBangWenJian-Setup-{#MyAppVersion}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
PrivilegesRequired=admin
CloseApplications=yes
CloseApplicationsFilter=*.exe,*.dll,*.so
; 安装向导 / Setup.exe 图标（绿标铥棒）
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
; 控制面板卸载项图标
UninstallDisplayIcon={app}\app_icon.ico
DisableProgramGroupPage=yes

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加图标:"; Flags: unchecked

[Files]
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "vc_redist.x64.exe"

[Icons]
; 明确指定 IconFilename，避免快捷方式仍沿用旧 exe 缓存图标
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\app_icon.ico"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\app_icon.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "启动 {#MyAppName}"; Flags: nowait postinstall skipifsilent

[Messages]
chinesesimplified.BeveledLabel=铥棒文件（Windows 10/11 x64）

; 兜底清理安装目录残留（仅限 {app}，不触及用户共享目录）
[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Code]
const
  LaunchAtStartupValueName = '{#MyAppName}';

procedure TryTaskKill(const ImageName: String);
var
  ResultCode: Integer;
begin
  Exec(ExpandConstant('{sys}\taskkill.exe'),
    '/F /T /IM ' + ImageName, '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

procedure TerminateAppProcesses;
begin
  TryTaskKill('{#MyAppExeName}');
  TryTaskKill('ffmpeg.exe');
end;

procedure CleanupLaunchAtStartup;
begin
  if RegValueExists(HKEY_CURRENT_USER,
    'Software\Microsoft\Windows\CurrentVersion\Run', LaunchAtStartupValueName) then
    RegDeleteValue(HKEY_CURRENT_USER,
      'Software\Microsoft\Windows\CurrentVersion\Run', LaunchAtStartupValueName);
end;

procedure ForceRemoveInstallDir;
var
  AppDir: String;
begin
  AppDir := ExpandConstant('{app}');
  if DirExists(AppDir) then
    DelTree(AppDir, True, True, True);
end;

function InitializeUninstall(): Boolean;
begin
  TerminateAppProcesses;
  Result := True;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
  begin
    TerminateAppProcesses;
  end
  else if CurUninstallStep = usPostUninstall then
  begin
    TerminateAppProcesses;
    Sleep(500);
    ForceRemoveInstallDir;
    CleanupLaunchAtStartup;
  end;
end;
