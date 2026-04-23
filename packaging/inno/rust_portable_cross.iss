#define MyAppName "Rust Portable Cross"
#define MyAppVersion "0.1.0"
#define MyAppPublisher "Rust Portable Cross"
#define MyAppExeName "Activate Rust Portable Cross.ps1"
#define StageRoot "..\..\dist\staging"

[Setup]
AppId={{8A3B77B4-BF0E-4B30-B6AC-8FA8302B3E10}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={code:GetDefaultInstallDir}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=..\..\dist\installer
OutputBaseFilename=rust-portable-cross-offline-{#MyAppVersion}
Compression=lzma2/max
SolidCompression=yes
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
WizardStyle=modern
UsePreviousAppDir=no
DisableDirPage=yes
UsePreviousGroup=yes
UsePreviousSetupType=yes

[Types]
Name: "default"; Description: "Default installation"
Name: "custom"; Description: "Custom installation"; Flags: iscustom

[Components]
Name: "core"; Description: "Core toolkit files"; Types: default custom; Flags: fixed
Name: "armv7"; Description: "ARMv7 Linux support"; Types: default custom
Name: "aarch64"; Description: "AArch64 Linux support"; Types: custom
Name: "x64_win"; Description: "Windows x64 support"; Types: custom

[Dirs]
Name: "{app}\tools\cargo-home\registry"
Name: "{app}\tools\cargo-home\git"
Name: "{app}\tools\zig-local-cache"
Name: "{app}\tools\zig-global-cache"

[Files]
Source: "{#StageRoot}\core\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#StageRoot}\targets\armv7\*"; DestDir: "{app}"; Components: armv7; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#StageRoot}\targets\aarch64\*"; DestDir: "{app}"; Components: aarch64; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#StageRoot}\targets\x64_win\*"; DestDir: "{app}"; Components: x64_win; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Activate Rust Portable Cross (PowerShell)"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoExit -ExecutionPolicy Bypass -File ""{app}\Activate Rust Portable Cross.ps1"""
Name: "{group}\README"; Filename: "{app}\docs\README-offline.md"
Name: "{group}\Uninstall Rust Portable Cross"; Filename: "{uninstallexe}"

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\finalize_offline_install.ps1"" -InstallRoot ""{app}"" -InstallScope ""{code:GetInstallScope}"" -SelectedComponents ""{code:GetSelectedComponents}"" -Validate"; Flags: runhidden waituntilterminated

[Code]
const
  EnvKeyMachine = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment';
  EnvKeyUser = 'Environment';
  WM_SETTINGCHANGE_MSG = $1A;
  HWND_BROADCAST_ALL = $FFFF;
  SMTO_ABORT_IF_HUNG = $0002;

function SendMessageTimeout(hWnd: LongInt; Msg: LongInt; wParam: LongInt;
  lParam: AnsiString; fuFlags: LongInt; uTimeout: LongInt;
  out lpdwResult: LongInt): LongInt;
  external 'SendMessageTimeoutA@user32.dll stdcall';

function GetDefaultInstallDir(Param: String): String;
begin
  if DirExists('D:\') then
    Result := 'D:\rust-portable-cross'
  else
    Result := 'C:\rust-portable-cross';
end;

function GetEnvRootKey(): Integer;
begin
  if IsAdminInstallMode then
    Result := HKEY_LOCAL_MACHINE
  else
    Result := HKEY_CURRENT_USER;
end;

function GetEnvSubKey(): String;
begin
  if IsAdminInstallMode then
    Result := EnvKeyMachine
  else
    Result := EnvKeyUser;
end;

function PathContainsEntry(const PathValue, Entry: String): Boolean;
var
  Lower, LowerEntry: String;
begin
  Lower := ';' + Lowercase(PathValue) + ';';
  StringChangeEx(Lower, '/', '\', True);
  LowerEntry := ';' + Lowercase(Entry) + ';';
  StringChangeEx(LowerEntry, '/', '\', True);
  Result := Pos(LowerEntry, Lower) > 0;
end;

procedure BroadcastEnvChange();
var
  ResultCode: LongInt;
begin
  SendMessageTimeout(HWND_BROADCAST_ALL, WM_SETTINGCHANGE_MSG, 0, 'Environment',
    SMTO_ABORT_IF_HUNG, 5000, ResultCode);
end;

procedure AddScriptsToPath();
var
  RootKey: Integer;
  SubKey, NewEntry, Existing, Updated: String;
begin
  RootKey := GetEnvRootKey();
  SubKey := GetEnvSubKey();
  NewEntry := ExpandConstant('{app}\scripts');

  if not RegQueryStringValue(RootKey, SubKey, 'Path', Existing) then
    Existing := '';

  if PathContainsEntry(Existing, NewEntry) then
    Exit;

  if (Length(Existing) > 0) and (Existing[Length(Existing)] <> ';') then
    Updated := Existing + ';' + NewEntry
  else
    Updated := Existing + NewEntry;

  if IsAdminInstallMode then
    RegWriteExpandStringValue(RootKey, SubKey, 'Path', Updated)
  else
    RegWriteStringValue(RootKey, SubKey, 'Path', Updated);

  BroadcastEnvChange();
end;

procedure RemoveScriptsFromPath();
var
  RootKey: Integer;
  SubKey, Entry, Existing, Rebuilt, Token: String;
  Parts: TArrayOfString;
  I, Count: Integer;
begin
  RootKey := GetEnvRootKey();
  SubKey := GetEnvSubKey();
  Entry := ExpandConstant('{app}\scripts');

  if not RegQueryStringValue(RootKey, SubKey, 'Path', Existing) then
    Exit;

  Count := 0;
  SetArrayLength(Parts, 0);
  while Length(Existing) > 0 do
  begin
    if Pos(';', Existing) > 0 then
    begin
      Token := Copy(Existing, 1, Pos(';', Existing) - 1);
      Existing := Copy(Existing, Pos(';', Existing) + 1, Length(Existing));
    end
    else
    begin
      Token := Existing;
      Existing := '';
    end;

    if (Length(Token) > 0) and (CompareText(Token, Entry) <> 0) then
    begin
      SetArrayLength(Parts, Count + 1);
      Parts[Count] := Token;
      Count := Count + 1;
    end;
  end;

  Rebuilt := '';
  for I := 0 to Count - 1 do
  begin
    if I > 0 then
      Rebuilt := Rebuilt + ';';
    Rebuilt := Rebuilt + Parts[I];
  end;

  if IsAdminInstallMode then
    RegWriteExpandStringValue(RootKey, SubKey, 'Path', Rebuilt)
  else
    RegWriteStringValue(RootKey, SubKey, 'Path', Rebuilt);

  BroadcastEnvChange();
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    AddScriptsToPath();
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
    RemoveScriptsFromPath();
end;

function GetInstallScope(Param: String): String;
begin
  if IsAdminInstallMode then
    Result := 'perMachine'
  else
    Result := 'perUser';
end;

function GetSelectedComponents(Param: String): String;
var
  Value: String;
begin
  Value := '';

  if WizardIsComponentSelected('armv7') then
    Value := Value + 'armv7,';

  if WizardIsComponentSelected('aarch64') then
    Value := Value + 'aarch64,';

  if WizardIsComponentSelected('x64_win') then
    Value := Value + 'x64_win,';

  if (Length(Value) > 0) and (Value[Length(Value)] = ',') then
    Delete(Value, Length(Value), 1);

  Result := Value;
end;
