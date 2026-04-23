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
UsePreviousAppDir=yes
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
function GetDefaultInstallDir(Param: String): String;
begin
  if IsAdminInstallMode then
    Result := ExpandConstant('{autopf}\RustPortableCross')
  else
    Result := ExpandConstant('{localappdata}\Programs\RustPortableCross');
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
