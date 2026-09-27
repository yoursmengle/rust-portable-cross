[CmdletBinding()]
param(
    [string]$ToolkitRoot,
    [ValidateSet("x86_64")]
    [string]$Arch = "x86_64",
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Regenerates the Windows link inputs that `x86_64-pc-windows-msvc` builds need.
#
# Everything produced here is derived from assets already bundled under tools/zig:
# mingw-w64 module-definition files become import libraries, and a small shim
# archive supplies the handful of symbols no DLL exports. Nothing from a host
# Visual Studio or Windows SDK installation is read or redistributed.

if ([string]::IsNullOrWhiteSpace($ToolkitRoot)) {
    $ToolkitRoot = Split-Path -Parent $PSScriptRoot
}
$ToolkitRoot = (Resolve-Path -LiteralPath $ToolkitRoot).Path
$pathBoundaryScript = Join-Path $PSScriptRoot 'rust_path_boundary.ps1'
if (-not (Test-Path -LiteralPath $pathBoundaryScript -PathType Leaf)) {
    throw "Missing managed path helper: $pathBoundaryScript"
}
. $pathBoundaryScript
$ToolkitRoot = Assert-ManagedRootIsOrdinary -Path $ToolkitRoot
. (Join-Path $PSScriptRoot 'rust_transaction.ps1')
. (Join-Path $PSScriptRoot 'rust_payload_integrity.ps1')
$operationLock = Enter-ToolkitOperation -Root $ToolkitRoot -Scope toolkit -Operation 'generate-windows-sysroot'
$sysrootRoot = $null
$sysrootParent = $null
try {

$script:Triple = "$Arch-pc-windows-msvc"
$script:DllToolMachine = "i386:x86-64"
$script:DefArchMacro = "DEF_X64"

$zigExe = Join-Path $ToolkitRoot "tools\zig\zig.exe"
$mingwRoot = Join-Path $ToolkitRoot "tools\zig\lib\libc\mingw"
$defIncludeRoot = Join-Path $mingwRoot "def-include"
$sysrootParent = Resolve-ManagedRelativePath -Root $ToolkitRoot -RelativePath 'tools/sysroot'
$publishedSysroot = Resolve-ManagedRelativePath -Root $ToolkitRoot -RelativePath "tools/sysroot/$script:Triple"
New-Item -ItemType Directory -Path $sysrootParent -Force | Out-Null
Restore-PreviousManagedDirectory -ManagedRoot $sysrootParent -ActivePath $publishedSysroot
foreach ($stale in @(Get-ChildItem -LiteralPath $sysrootParent -Directory -Filter "$($script:Triple).next.*" -ErrorAction SilentlyContinue)) {
    Remove-TransactionDirectory -ManagedRoot $sysrootParent -Path $stale.FullName
}
$sysrootRoot = Resolve-ManagedRelativePath -Root $ToolkitRoot -RelativePath ("tools/sysroot/$($script:Triple).next." + [guid]::NewGuid().ToString('N'))
$libRoot = Join-Path $sysrootRoot 'lib'
$workRoot = Join-Path $sysrootRoot '.work'

if (-not (Test-Path -LiteralPath $zigExe -PathType Leaf)) {
    throw "Missing bundled Zig compiler: $zigExe`nThe Windows link inputs are generated from assets under tools\zig. Run .\scripts\rust_setup.ps1 first."
}
if (-not (Test-Path -LiteralPath $mingwRoot -PathType Container)) {
    throw "Missing bundled mingw-w64 definition files: $mingwRoot`nThe bundled Zig installation looks incomplete. Run .\scripts\rust_setup.ps1 first."
}

# Import libraries generated from bundled mingw-w64 module definitions.
#
# The first five are named by rustc for every std binary; the rest are the
# libraries that windows-sys style dependencies commonly pull in. Adding a
# library is a one-line change here.
$script:ImportLibraries = @(
    "kernel32",
    "ntdll",
    "userenv",
    "ws2_32",
    "dbghelp",
    "advapi32",
    "user32",
    "ole32",
    "oleaut32",
    "shell32",
    "bcrypt"
)

# Symbols the generated msvcrt.lib must export for a default std binary to link.
$script:RequiredCrtExports = @(
    "__CxxFrameHandler3",
    "_CxxThrowException",
    "_crt_atexit",
    "exit",
    "memcpy",
    "memmove",
    "memcmp",
    "memset",
    "strlen"
)

# Symbols rpc_winshim.lib must define for a build to link.
#
# The two stack-probe spellings are one routine under two names: MSVC codegen
# calls __chkstk, and the GNU-targeted C compiler this toolkit uses for build
# scripts calls libgcc's ___chkstk_ms. Neither libgcc nor compiler-rt is on an
# MSVC link line, so a missing spelling only shows up as an undefined symbol in
# somebody else's project. Adding a symbol is a one-line change here.
$script:RequiredShimSymbols = @(
    "__chkstk",
    "___chkstk_ms",
    "_fltused",
    "mainCRTStartup",
    "atexit",
    "_tls_used",
    "_tls_index",

    # The formatted I/O families ucrtbase.dll keeps as header inlines.
    "printf",
    "vprintf",
    "fprintf",
    "vfprintf",
    "sprintf",
    "vsprintf",
    "snprintf",
    "vsnprintf",
    "_snprintf",
    "_vsnprintf",
    "_scprintf",
    "_vscprintf",
    "scanf",
    "vscanf",
    "fscanf",
    "vfscanf",
    "sscanf",
    "vsscanf"
)

$script:Provenance = New-Object 'System.Collections.Generic.List[object]'

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "==> $Message"
}

function New-DirectoryIfMissing {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-RelativeToToolkit {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-ManagedPathInsideRoot -Root $ToolkitRoot -Path $full)) {
        throw "Sysroot provenance source is outside the toolkit: $full"
    }
    $rootFull = [System.IO.Path]::GetFullPath($ToolkitRoot).TrimEnd('\', '/')
    return $full.Substring($rootFull.Length).TrimStart('\', '/') -replace '\\', '/'
}

function Get-PublishedProvenancePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $relative = Get-RelativeToToolkit -Path $Path
    $candidatePrefix = (Get-RelativeToToolkit -Path $sysrootRoot) + '/'
    if ($relative.StartsWith($candidatePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        return "tools/sysroot/$($script:Triple)/" + $relative.Substring($candidatePrefix.Length)
    }
    return $relative
}

function Add-Provenance {
    param(
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][string[]]$SourcePaths,
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$License
    )

    $script:Provenance.Add([ordered]@{
        file = Get-PublishedProvenancePath -Path $OutputPath
        sources = @($SourcePaths | ForEach-Object { Get-PublishedProvenancePath -Path $_ })
        command = $Command
        license = $License
        sha256 = (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash.ToLowerInvariant()
    })
}

function Invoke-Zig {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$What
    )

    $output = & $zigExe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "$What failed (exit code $LASTEXITCODE).`nzig $($Arguments -join ' ')`n$($output -join "`n")"
    }
    return $output
}

function Assert-GeneratedFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$What
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$What did not produce $Path."
    }
    if ((Get-Item -LiteralPath $Path).Length -le 0) {
        throw "$What produced an empty file: $Path."
    }
}

function Resolve-DefinitionSource {
    param([Parameter(Mandatory = $true)][string]$Name)

    $candidates = @(
        @{ Path = Join-Path $mingwRoot "lib64\$Name.def"; NeedsPreprocess = $false },
        @{ Path = Join-Path $mingwRoot "lib-common\$Name.def"; NeedsPreprocess = $false },
        @{ Path = Join-Path $mingwRoot "lib-common\$Name.def.in"; NeedsPreprocess = $true }
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate.Path -PathType Leaf) {
            return $candidate
        }
    }

    throw "No bundled module-definition file found for '$Name'. Looked under $mingwRoot in lib64\ and lib-common\."
}

function ConvertTo-PreprocessedDefinition {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    # mingw's .def.in files select exports per architecture through the macros in
    # def-include/func.def.in, so they are run through the C preprocessor first.
    # -P suppresses line markers, which dlltool would reject.
    Invoke-Zig -What "Preprocessing $(Split-Path -Leaf $SourcePath)" -Arguments @(
        "cc", "-E", "-P", "-xc",
        "-D$script:DefArchMacro",
        "-I", $defIncludeRoot,
        $SourcePath,
        "-o", $DestinationPath
    ) | Out-Null

    Assert-GeneratedFile -Path $DestinationPath -What "Preprocessing $(Split-Path -Leaf $SourcePath)"
}

function New-ImportLibrary {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$DefinitionPath,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][string[]]$SourcePaths
    )

    Invoke-Zig -What "Generating $Name import library" -Arguments @(
        "dlltool",
        "-m", $script:DllToolMachine,
        "--no-leading-underscore",
        "-d", $DefinitionPath,
        "-l", $OutputPath
    ) | Out-Null

    Assert-GeneratedFile -Path $OutputPath -What "Generating $Name import library"
    Add-Provenance -OutputPath $OutputPath -SourcePaths $SourcePaths `
        -Command "zig dlltool -m $script:DllToolMachine --no-leading-underscore" `
        -License "mingw-w64 (Public Domain / ZPL-derived definition files bundled with Zig)"
}

function Get-DefinitionExports {
    param([Parameter(Mandatory = $true)][string]$DefinitionPath)

    $exports = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($line in Get-Content -LiteralPath $DefinitionPath) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0) { continue }
        if ($trimmed.StartsWith(";")) { continue }
        if ($trimmed -match '^(LIBRARY|EXPORTS)\b') { continue }
        $symbol = ($trimmed -split '\s+')[0]
        if ($symbol.Length -gt 0) {
            [void]$exports.Add($symbol)
        }
    }
    return $exports
}

function Get-ArchiveDefinedSymbols {
    param([Parameter(Mandatory = $true)][string]$ArchivePath)

    # A COFF archive opens with the linker's own symbol directory: the first
    # member is named "/" and holds a big-endian symbol count, one offset per
    # symbol, then the names. Reading it gives exactly the view the linker gets,
    # and keeps this check free of an external nm.
    $bytes = [System.IO.File]::ReadAllBytes($ArchivePath)
    if ($bytes.Length -lt 68) {
        throw "Not a COFF archive (too short): $ArchivePath"
    }
    if ([System.Text.Encoding]::ASCII.GetString($bytes, 0, 8) -ne "!<arch>" + [char]10) {
        throw "Not a COFF archive (bad magic): $ArchivePath"
    }

    # The member header sits at byte 8; its size field is 10 ASCII digits at
    # header offset 48, and the member's data follows the 60-byte header.
    $memberSize = [int]([System.Text.Encoding]::ASCII.GetString($bytes, 8 + 48, 10).Trim())
    $data = 8 + 60
    $limit = $data + $memberSize
    if ($limit -gt $bytes.Length) {
        throw "Truncated archive symbol directory in $ArchivePath"
    }

    $count = ($bytes[$data] -shl 24) -bor ($bytes[$data + 1] -shl 16) -bor `
        ($bytes[$data + 2] -shl 8) -bor $bytes[$data + 3]

    $symbols = New-Object 'System.Collections.Generic.HashSet[string]'
    $cursor = $data + 4 + ($count * 4)
    for ($i = 0; $i -lt $count -and $cursor -lt $limit; $i++) {
        $end = $cursor
        while ($end -lt $limit -and $bytes[$end] -ne 0) { $end++ }
        [void]$symbols.Add([System.Text.Encoding]::ASCII.GetString($bytes, $cursor, $end - $cursor))
        $cursor = $end + 1
    }
    return $symbols
}

function New-ShimSource {
    param([Parameter(Mandatory = $true)][string]$Path)

    # Symbols that no DLL exports, so they cannot come from an import library:
    # the startup and TLS glue, the stack probe, and the formatted I/O functions
    # the platform C runtime keeps as header inlines. Kept in one file - this is
    # the whole surface of code this toolkit invents rather than derives.
    $source = @'
/*
 * Generated by scripts/build_win_link_inputs.ps1 - do not edit by hand.
 *
 * Supplies the link-time symbols that ucrtbase.dll does not export, so that
 * x86_64-pc-windows-msvc binaries link without a Visual Studio or Windows SDK
 * installation. The TLS block is adapted from mingw-w64's crt/tlssup.c, which
 * is placed in the Public Domain.
 */

typedef void (*_PVFV)(void);
typedef struct _iobuf FILE;
typedef __builtin_va_list va_list;
typedef unsigned long ULONG;
typedef unsigned long long ULONG_PTR;

/* Imported from ucrtbase.dll through the generated msvcrt.lib. */
int __cdecl _crt_atexit(_PVFV func);
void __cdecl exit(int status);
int __cdecl _configure_narrow_argv(int mode);
int *__cdecl __p___argc(void);
char ***__cdecl __p___argv(void);
char **__cdecl _get_initial_narrow_environment(void);

/*
 * The formatted I/O primitives. ucrtbase.dll exports these but not one member
 * of the printf or scanf families: in Microsoft's headers those families are
 * inline bodies forwarding to the primitives, so they never become exports.
 * mingw's headers declare them as ordinary functions and leave the bodies to
 * libmingwex.a, which an MSVC-mode link never sees - so they live here.
 */
int __cdecl __stdio_common_vfprintf(unsigned long long options, FILE *stream,
                                    const char *format, void *locale, va_list args);
int __cdecl __stdio_common_vsprintf(unsigned long long options, char *buffer,
                                    ULONG_PTR count, const char *format,
                                    void *locale, va_list args);
int __cdecl __stdio_common_vfscanf(unsigned long long options, FILE *stream,
                                   const char *format, void *locale, va_list args);
int __cdecl __stdio_common_vsscanf(unsigned long long options, const char *buffer,
                                   ULONG_PTR count, const char *format,
                                   void *locale, va_list args);
FILE *__cdecl __acrt_iob_func(unsigned index);

extern int __cdecl main(int argc, char **argv, char **envp);

/* Emitted by the compiler whenever floating point is used. */
int _fltused = 0x9875;

/* ucrtbase.dll exports _crt_atexit but not atexit itself. */
int __cdecl atexit(_PVFV func)
{
    return _crt_atexit(func);
}

/* ---------------------------------------------------------------------------
 * Formatted input and output.
 *
 * Each function below is the body of the corresponding inline in Microsoft's
 * own <stdio.h>, transcribed. The option flags are not interchangeable: C99's
 * snprintf always null terminates and returns the length it wanted, while the
 * legacy MSVC _snprintf does neither, and that difference is exactly the
 * STANDARD_SNPRINTF_BEHAVIOR bit. printf and scanf reach the standard streams
 * through __acrt_iob_func, as the headers do.
 * ------------------------------------------------------------------------- */

#define CRT_LEGACY_VSPRINTF_NULL_TERMINATION 0x0001ULL
#define CRT_STANDARD_SNPRINTF_BEHAVIOR       0x0002ULL

#define CRT_STDIN  0
#define CRT_STDOUT 1

int __cdecl vfprintf(FILE *stream, const char *format, va_list args)
{
    return __stdio_common_vfprintf(0, stream, format, 0, args);
}

int __cdecl fprintf(FILE *stream, const char *format, ...)
{
    int result;
    va_list args;
    __builtin_va_start(args, format);
    result = __stdio_common_vfprintf(0, stream, format, 0, args);
    __builtin_va_end(args);
    return result;
}

int __cdecl vprintf(const char *format, va_list args)
{
    return __stdio_common_vfprintf(0, __acrt_iob_func(CRT_STDOUT), format, 0, args);
}

int __cdecl printf(const char *format, ...)
{
    int result;
    va_list args;
    __builtin_va_start(args, format);
    result = __stdio_common_vfprintf(0, __acrt_iob_func(CRT_STDOUT), format, 0, args);
    __builtin_va_end(args);
    return result;
}

int __cdecl vsprintf(char *buffer, const char *format, va_list args)
{
    return __stdio_common_vsprintf(CRT_LEGACY_VSPRINTF_NULL_TERMINATION,
                                   buffer, (ULONG_PTR)-1, format, 0, args);
}

int __cdecl sprintf(char *buffer, const char *format, ...)
{
    int result;
    va_list args;
    __builtin_va_start(args, format);
    result = __stdio_common_vsprintf(CRT_LEGACY_VSPRINTF_NULL_TERMINATION,
                                     buffer, (ULONG_PTR)-1, format, 0, args);
    __builtin_va_end(args);
    return result;
}

/* C99: always null terminates, returns the length the output wanted. */
int __cdecl vsnprintf(char *buffer, ULONG_PTR count, const char *format, va_list args)
{
    int result = __stdio_common_vsprintf(CRT_STANDARD_SNPRINTF_BEHAVIOR,
                                         buffer, count, format, 0, args);
    return result < 0 ? -1 : result;
}

int __cdecl snprintf(char *buffer, ULONG_PTR count, const char *format, ...)
{
    int result;
    va_list args;
    __builtin_va_start(args, format);
    result = __stdio_common_vsprintf(CRT_STANDARD_SNPRINTF_BEHAVIOR,
                                     buffer, count, format, 0, args);
    __builtin_va_end(args);
    return result < 0 ? -1 : result;
}

/* Legacy MSVC: truncates without a terminator and returns -1 when it does. */
int __cdecl _vsnprintf(char *buffer, ULONG_PTR count, const char *format, va_list args)
{
    int result = __stdio_common_vsprintf(CRT_LEGACY_VSPRINTF_NULL_TERMINATION,
                                         buffer, count, format, 0, args);
    return result < 0 ? -1 : result;
}

int __cdecl _snprintf(char *buffer, ULONG_PTR count, const char *format, ...)
{
    int result;
    va_list args;
    __builtin_va_start(args, format);
    result = __stdio_common_vsprintf(CRT_LEGACY_VSPRINTF_NULL_TERMINATION,
                                     buffer, count, format, 0, args);
    __builtin_va_end(args);
    return result < 0 ? -1 : result;
}

/* How long the output would have been, formatting nothing. */
int __cdecl _vscprintf(const char *format, va_list args)
{
    return __stdio_common_vsprintf(CRT_STANDARD_SNPRINTF_BEHAVIOR, 0, 0, format, 0, args);
}

int __cdecl _scprintf(const char *format, ...)
{
    int result;
    va_list args;
    __builtin_va_start(args, format);
    result = __stdio_common_vsprintf(CRT_STANDARD_SNPRINTF_BEHAVIOR, 0, 0, format, 0, args);
    __builtin_va_end(args);
    return result;
}

int __cdecl vfscanf(FILE *stream, const char *format, va_list args)
{
    return __stdio_common_vfscanf(0, stream, format, 0, args);
}

int __cdecl fscanf(FILE *stream, const char *format, ...)
{
    int result;
    va_list args;
    __builtin_va_start(args, format);
    result = __stdio_common_vfscanf(0, stream, format, 0, args);
    __builtin_va_end(args);
    return result;
}

int __cdecl vscanf(const char *format, va_list args)
{
    return __stdio_common_vfscanf(0, __acrt_iob_func(CRT_STDIN), format, 0, args);
}

int __cdecl scanf(const char *format, ...)
{
    int result;
    va_list args;
    __builtin_va_start(args, format);
    result = __stdio_common_vfscanf(0, __acrt_iob_func(CRT_STDIN), format, 0, args);
    __builtin_va_end(args);
    return result;
}

int __cdecl vsscanf(const char *buffer, const char *format, va_list args)
{
    return __stdio_common_vsscanf(0, buffer, (ULONG_PTR)-1, format, 0, args);
}

int __cdecl sscanf(const char *buffer, const char *format, ...)
{
    int result;
    va_list args;
    __builtin_va_start(args, format);
    result = __stdio_common_vsscanf(0, buffer, (ULONG_PTR)-1, format, 0, args);
    __builtin_va_end(args);
    return result;
}

/* ---------------------------------------------------------------------------
 * TLS directory.
 *
 * Rust's std uses #[thread_local] statics and registers thread callbacks in
 * .CRT$XLB. Both need a real IMAGE_TLS_DIRECTORY, a _tls_index for the loader
 * to fill in, and the __xl_a/__xl_z pair bracketing the callback array.
 * ------------------------------------------------------------------------- */

typedef struct _IMAGE_TLS_DIRECTORY64 {
    ULONG_PTR StartAddressOfRawData;
    ULONG_PTR EndAddressOfRawData;
    ULONG_PTR AddressOfIndex;
    ULONG_PTR AddressOfCallBacks;
    ULONG SizeOfZeroFill;
    ULONG Characteristics;
} IMAGE_TLS_DIRECTORY64;

typedef void(__stdcall *PIMAGE_TLS_CALLBACK)(void *, ULONG, void *);

ULONG _tls_index = 0;

__attribute__((section(".tls"))) char *_tls_start = 0;
__attribute__((section(".tls$ZZZ"))) char *_tls_end = 0;

__attribute__((section(".CRT$XLA"))) PIMAGE_TLS_CALLBACK __xl_a = 0;
__attribute__((section(".CRT$XLZ"))) PIMAGE_TLS_CALLBACK __xl_z = 0;

__attribute__((used))
const IMAGE_TLS_DIRECTORY64 _tls_used = {
    (ULONG_PTR)&_tls_start,
    (ULONG_PTR)&_tls_end,
    (ULONG_PTR)&_tls_index,
    (ULONG_PTR)(&__xl_a + 1),
    0,
    0
};

/* ---------------------------------------------------------------------------
 * Entry point.
 * ------------------------------------------------------------------------- */

void mainCRTStartup(void)
{
    /* 2 == _crt_argv_expanded_arguments */
    _configure_narrow_argv(2);
    exit(main(*__p___argc(), *__p___argv(), _get_initial_narrow_environment()));
}

/* ---------------------------------------------------------------------------
 * The stack probe, under both names it is called by.
 *
 * RAX holds the frame size on entry and must be preserved; the caller subtracts
 * it from RSP afterwards. MSVC codegen calls this __chkstk. The toolkit compiles C
 * through `zig cc -target x86_64-windows-gnu` - windows-msvc would need MSVC
 * headers we cannot ship - and GNU-ABI codegen calls libgcc's ___chkstk_ms instead
 * for any frame over one page. The two are the same routine with the same contract,
 * and neither libgcc nor compiler-rt is on an MSVC link line, so both names are
 * labels on the one body below.
 *
 * const type_info::`vftable' is referenced from the unwind tables of the
 * precompiled MSVC std. The throw path itself lives in ucrtbase.dll, so this
 * only ever has to satisfy the reference.
 * ------------------------------------------------------------------------- */

__asm__(
    ".text\n"
    ".globl ___chkstk_ms\n"
    ".def ___chkstk_ms; .scl 2; .type 32; .endef\n"
    "___chkstk_ms:\n"
    ".globl __chkstk\n"
    ".def __chkstk; .scl 2; .type 32; .endef\n"
    "__chkstk:\n"
    "    push   %rcx\n"
    "    push   %rax\n"
    "    cmp    $0x1000, %rax\n"
    "    lea    24(%rsp), %rcx\n"
    "    jb     1f\n"
    "2:\n"
    "    sub    $0x1000, %rcx\n"
    "    test   %rcx, (%rcx)\n"
    "    sub    $0x1000, %rax\n"
    "    cmp    $0x1000, %rax\n"
    "    ja     2b\n"
    "1:\n"
    "    sub    %rax, %rcx\n"
    "    test   %rcx, (%rcx)\n"
    "    pop    %rax\n"
    "    pop    %rcx\n"
    "    ret\n"
);

__asm__(
    ".section .rdata,\"dr\"\n"
    ".globl \"??_7type_info@@6B@\"\n"
    ".p2align 4\n"
    "\"??_7type_info@@6B@\":\n"
    "    .quad 0\n"
    "    .quad 0\n"
);
'@

    Set-Content -LiteralPath $Path -Value $source -Encoding ASCII
}

function New-ShimArchive {
    param([Parameter(Mandatory = $true)][string]$OutputPath)

    $shimSource = Join-Path $workRoot "rpc_winshim.c"
    $shimObject = Join-Path $workRoot "rpc_winshim.obj"
    New-ShimSource -Path $shimSource

    # -ffreestanding/-nostdinc keep this off mingw's headers: the shim declares
    # everything it uses, so the object stays free of mingw runtime entanglement.
    Invoke-Zig -What "Compiling rpc_winshim" -Arguments @(
        "cc", "-target", "$Arch-windows-gnu",
        "-c", "-O2", "-ffreestanding", "-nostdinc",
        "-fno-stack-protector",
        # Without -fno-builtin clang may recognize printf and friends as builtins
        # and rewrite a forwarder body into a call to itself.
        "-fno-builtin",
        $shimSource,
        "-o", $shimObject
    ) | Out-Null
    Assert-GeneratedFile -Path $shimObject -What "Compiling rpc_winshim"

    if (Test-Path -LiteralPath $OutputPath) {
        Remove-Item -LiteralPath $OutputPath -Force
    }
    Invoke-Zig -What "Archiving rpc_winshim.lib" -Arguments @(
        "lib", "/nologo", "/out:$OutputPath", $shimObject
    ) | Out-Null
    Assert-GeneratedFile -Path $OutputPath -What "Archiving rpc_winshim.lib"

    $defined = Get-ArchiveDefinedSymbols -ArchivePath $OutputPath
    $missingSymbols = @($script:RequiredShimSymbols | Where-Object { -not $defined.Contains($_) })
    if ($missingSymbols.Count -gt 0) {
        throw (("rpc_winshim.lib does not define required symbols: " +
            ($missingSymbols -join ', ') + '.') + [System.Environment]::NewLine +
            'They are declared in $script:RequiredShimSymbols and must be supplied by New-ShimSource.')
    }

    Add-Provenance -OutputPath $OutputPath `
        -SourcePaths @($shimSource, (Join-Path $mingwRoot "crt\tlssup.c")) `
        -Command "zig cc -target $Arch-windows-gnu -ffreestanding -nostdinc -fno-builtin; zig lib" `
        -License "mingw-w64 (Public Domain) and this project"
}

Write-Step "Regenerating Windows link inputs for $script:Triple"

New-DirectoryIfMissing -Path $libRoot
New-DirectoryIfMissing -Path $workRoot

try {
    Write-Step "Generating $($script:ImportLibraries.Count) Windows import libraries"
    foreach ($name in $script:ImportLibraries) {
        $definition = Resolve-DefinitionSource -Name $name
        $definitionPath = $definition.Path
        $sourcePaths = @($definitionPath)

        if ($definition.NeedsPreprocess) {
            $preprocessed = Join-Path $workRoot "$name.def"
            ConvertTo-PreprocessedDefinition -SourcePath $definitionPath -DestinationPath $preprocessed
            $definitionPath = $preprocessed
            $sourcePaths += (Join-Path $defIncludeRoot "func.def.in")
        }

        New-ImportLibrary -Name $name `
            -DefinitionPath $definitionPath `
            -OutputPath (Join-Path $libRoot "$name.lib") `
            -SourcePaths $sourcePaths
    }

    # rustc emits /defaultlib:msvcrt for this target. MSVC's msvcrt.lib is not
    # redistributable, so the reference is satisfied with an import library for
    # ucrtbase.dll - an operating system component on Windows 10 and later, not a
    # Visual C++ redistributable. It exports the C runtime entry points and the
    # MSVC C++ exception personality that Rust's precompiled std references.
    Write-Step "Generating msvcrt.lib as an import library for ucrtbase.dll"
    $ucrtDefIn = Join-Path $mingwRoot "lib-common\ucrtbase.def.in"
    if (-not (Test-Path -LiteralPath $ucrtDefIn -PathType Leaf)) {
        throw "Missing bundled definition file: $ucrtDefIn"
    }
    $ucrtDef = Join-Path $workRoot "msvcrt.def"
    ConvertTo-PreprocessedDefinition -SourcePath $ucrtDefIn -DestinationPath $ucrtDef

    $exports = Get-DefinitionExports -DefinitionPath $ucrtDef
    $missing = @($script:RequiredCrtExports | Where-Object { -not $exports.Contains($_) })
    if ($missing.Count -gt 0) {
        throw "The generated CRT definition is missing required exports: $($missing -join ', ').`nSource: $ucrtDefIn"
    }

    New-ImportLibrary -Name "msvcrt" `
        -DefinitionPath $ucrtDef `
        -OutputPath (Join-Path $libRoot "msvcrt.lib") `
        -SourcePaths @($ucrtDefIn, (Join-Path $defIncludeRoot "func.def.in"), (Join-Path $mingwRoot "def-include\msvcrt-common.def.in"))

    Write-Step "Building rpc_winshim.lib"
    New-ShimArchive -OutputPath (Join-Path $libRoot "rpc_winshim.lib")

    $provenancePath = Join-Path $sysrootRoot "PROVENANCE.json"
    $document = [ordered]@{
        triple = $script:Triple
        generatedBy = "scripts/build_win_link_inputs.ps1"
        requiredShimSymbols = @($script:RequiredShimSymbols)
        zigVersion = ((& $zigExe version) | Select-Object -First 1)
        note = "Every file below is generated from assets bundled under tools/zig. No Microsoft Visual C++ runtime or Windows SDK library is redistributed."
        files = @($script:Provenance | Sort-Object -Property file)
    }
    Set-Content -LiteralPath $provenancePath -Value ($document | ConvertTo-Json -Depth 6) -Encoding UTF8
}
finally {
    if (Test-Path -LiteralPath $workRoot) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Assert-WindowsLinkInputProvenance -ToolkitRoot $ToolkitRoot -SysrootRoot $sysrootRoot
Promote-ManagedDirectory -ManagedRoot $sysrootParent -ActivePath $publishedSysroot -CandidatePath $sysrootRoot
$libRoot = Join-Path $publishedSysroot 'lib'
Write-Step "Windows link inputs written to $libRoot"
Get-ChildItem -LiteralPath $libRoot -Filter *.lib | Sort-Object Name | ForEach-Object {
    Write-Host ("    {0,-20} {1,10:N0} bytes" -f $_.Name, $_.Length)
}
}
finally {
    try {
        if ($sysrootRoot -and (Test-Path -LiteralPath $sysrootRoot)) {
            Remove-TransactionDirectory -ManagedRoot $sysrootParent -Path $sysrootRoot
        }
    }
    finally { Exit-ToolkitOperation -Handle $operationLock }
}
