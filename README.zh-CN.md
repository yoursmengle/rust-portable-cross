# rust-portable-cross

[English](README.md) | **简体中文**

一套可移动、自包含的 Windows 版 Rust 交叉编译工具链。

在一台 Windows 机器上，就能为 ARM Linux 开发板、ARM64 Linux 开发板、Cortex-M 单片机以及 Windows 本身
编译 Rust 程序，不需要 Visual Studio、Windows SDK、GCC 交叉工具链，也不需要系统里装有 Rust。所有内容都在
一个目录里，可以复制、移动或直接删除。

- **自包含。** rustup、cargo、rustc 和 Zig 都安装在工具链自己的 `tools/` 目录下，不改动系统 `PATH`、
  注册表，也不影响已有的 Rust 安装。
- **不用另装 C 工具链。** Linux 目标由 [Zig](https://ziglang.org/) 充当 C 编译器和链接器；Windows
  主机构建使用工具链自带的链接输入。
- **可离线使用。** 发布形式是单个离线安装包，安装后构建不需要联网。自带示例的依赖也一并打包。
- **版本固定、可校验。** Rust 和 Zig 的版本是固定的，下载的文件要与记录的 SHA-256 摘要一致，发布的每个
  文件都在完整性索引里。
- **可搬迁。** 移动目录后重新激活即可，不需要改其他东西。

## 目录

- [支持的目标](#支持的目标)
- [环境要求](#环境要求)
- [安装](#安装)
- [快速上手](#快速上手)
- [在自己的项目中使用](#在自己的项目中使用)
- [示例项目](#示例项目)
- [工作原理](#工作原理)
- [脚本参考](#脚本参考)
- [下载配置](#下载配置)
- [构建发布包](#构建发布包)
- [开发](#开发)
- [仓库结构](#仓库结构)
- [常见问题](#常见问题)
- [已知限制](#已知限制)
- [参与贡献](#参与贡献)
- [许可证](#许可证)

## 支持的目标

| 目标 | 平台 | 构建脚本 | 链接器 |
|---|---|---|---|
| `armv7-unknown-linux-musleabihf` | ARMv7 Linux，musl libc，硬浮点 | `scripts/rust_build_armv7.ps1` | Zig |
| `aarch64-unknown-linux-musl` | ARM64 Linux，musl libc | `scripts/rust_build_aarch64.ps1` | Zig |
| `thumbv7em-none-eabihf` | ARM Cortex-M4F / M7 裸机（`no_std`），硬浮点 | `scripts/rust_build_thumbv7em.ps1` | `rust-lld` |
| `x86_64-pc-windows-msvc` | Windows x64（主机） | `scripts/rust_build_x64_win_native.ps1` | `rust-lld` |

Linux 目标生成静态链接的 musl 可执行文件，放到板子上直接运行，不依赖任何运行时库。Windows 可执行文件
可在 Windows 10 / Server 2016 及以上运行，不需要 Visual C++ 运行库。

固定版本：Rust `1.98.0`（主机工具链 `1.98.0-x86_64-pc-windows-msvc`），Zig `0.13.0`。

## 环境要求

- Windows 10 / Windows Server 2019 或更高版本，x86-64
- PowerShell 5.1 或 PowerShell 7+
- 约 2 GB 可用磁盘空间用于安装工具链，另需空间存放构建产物
- 只有从源码搭建时需要联网（支持镜像和代理，见[下载配置](#下载配置)）；离线安装包不需要联网

不需要：Visual Studio、MSVC 链接器、Windows SDK、系统级 Rust 安装，或任何 GCC / Clang 交叉工具链。

## 安装

有两种方式。只想**使用**工具链，用离线安装包；要**开发**工具链或自己制作安装包，从源码搭建。

### 方式 A：离线安装包

运行 `rust-portable-cross-offline-<version>.exe`。安装过程不下载任何东西。

- 默认为当前用户安装；安装界面里可以选择为所有用户安装。
- 有 `D:` 盘时默认装到 `D:\rust-portable-cross`，否则装到 `C:\rust-portable-cross`。
- 四个目标一起安装。

安装完成后，从开始菜单打开 **Activate Rust Portable Cross (PowerShell)**。随安装包一起发布的用户
指南是 `docs/customer/README-offline.md`。

如何自己制作安装包，见[构建发布包](#构建发布包)。

### 方式 B：从源码搭建

克隆仓库，在仓库根目录运行一次安装脚本：

```powershell
git clone https://gitee.com/yoursmengle/rust-portable-cross.git
cd rust-portable-cross
.\scripts\rust_setup.ps1
```

安装脚本会：

- 下载 `rustup-init.exe`，把固定版本的 Rust 工具链安装到 `tools/`；
- 添加三个交叉编译目标；
- 下载 Zig，核对摘要，并删掉其库目录里属于工具链不支持的平台的部分；
- 在 `tools/wrappers/` 生成基于 Zig 的编译器包装脚本；
- 在 `tools/sysroot/x86_64-pc-windows-msvc/` 生成 Windows 链接输入；
- 校验已安装的工具和目标库。

安装脚本可以重复运行。`.\scripts\rust_setup.ps1 -Force` 会先清掉缓存的 registry 和包数据。

## 快速上手

每开一个新的 PowerShell 会话都要先激活，然后在 Rust 项目目录里运行构建脚本。下面的例子假设工具链
装在 `D:\rust-portable-cross`。

```powershell
# 1. 激活（注意开头的点：脚本必须用点号加载）
. D:\rust-portable-cross\scripts\rust_env.ps1

# 2. 为 ARM64 Linux 编译自带示例
cd D:\rust-portable-cross\sample
rust_build_aarch64.ps1

# 3. 产物是一个静态链接的 Linux 可执行文件
dir target\aarch64-unknown-linux-musl\release\sample
```

其他目标用法相同：

```powershell
rust_build_armv7.ps1                                  # ARMv7 Linux
rust_build_thumbv7em.ps1                              # Cortex-M4F / M7 固件
rust_build_x64_win_native.ps1 -ProjectPath .          # Windows x64
```

构建产物在项目目录的 `target/<triple>/release/` 下。各构建脚本都按 release 模式构建；
`rust_build_x64_win_native.ps1` 另外支持 `-DebugBuild`。

要检查安装是否正常，在工具链根目录运行各目标的检查脚本：

```powershell
.\check_tool_armv7.ps1
.\check_tool_aarch64.ps1
.\check_tool_thumbv7em.ps1
.\check_tool_x64_win.ps1
```

## 在自己的项目中使用

### 使用构建脚本

在项目目录（含 `Cargo.toml` 的目录）里运行对应目标的构建脚本。脚本会把 `config/.cargo/config.toml`
复制到项目的 `.cargo/` 目录，设置该目标的编译器和链接器变量，然后执行 `cargo build --release`。

### 直接使用 `cargo`

激活之后，`PATH` 上的 `cargo`、`rustc`、`rustup` 就是工具链自带的，普通命令可以直接用：

```powershell
. D:\rust-portable-cross\scripts\rust_env.ps1
cargo build --release --target aarch64-unknown-linux-musl
cargo test
```

Linux 目标需要 `config/.cargo/config.toml` 里的链接器设置。把这个文件复制到项目的 `.cargo` 目录，
或者先运行一次构建脚本让它来复制。

### 含 C 或 C++ 代码的 crate

通过 [`cc`](https://crates.io/crates/cc) 编译 C 代码的 crate 在所有目标上都能用。激活时会为两个
Linux 目标设置按目标区分的编译器和归档器变量（`CC_<target>`、`AR_<target>`、`RANLIB_<target>`），
它们的 C 代码由 Zig 编译。

即使在交叉编译时，Cargo 也会为**主机**编译构建脚本和过程宏。工具链用自带的 Windows 链接输入来链接
这些主机程序，所以交叉编译同样不需要 Visual Studio。

主机的 C 代码是两种构建方式唯一不同的地方：

| 为 Windows 构建的方式 | 使用的 C 编译器 | 是否需要 Visual Studio |
|---|---|---|
| `rust_build_x64_win_native.ps1` | 自带的 Zig | 不需要 |
| 激活后直接用 `cargo` | `cc` 在本机找到的编译器 | crate 含 C 代码时需要 |

### 裸机固件

`thumbv7em-none-eabihf` 是 `no_std` 目标，固件项目要自己提供链接脚本和启动代码。`sample_embedded`
是一个完整、无外部依赖的例子，可以作为起点，见[示例项目](#示例项目)。

## 示例项目

| 目录 | 说明 |
|---|---|
| `sample/` | 使用常见 crate（`tokio`、基于 rustls 的 `reqwest`、`serde`、`clap` 等）的 `std` 程序，可为 Windows、ARMv7、ARM64 目标构建。它的依赖随离线安装包一起发布，构建时不需要联网。 |
| `sample_embedded/` | 面向 HEM6801E 板（GD32F427ZE，Cortex-M4F）的可烧录 `no_std` 固件：自带 `link.x`、向量表和 1 Hz 的 LED 闪烁。 |

生成可下载的固件镜像：

```powershell
. D:\rust-portable-cross\scripts\rust_env.ps1
D:\rust-portable-cross\sample_embedded\make_image.ps1
```

它会构建固件，并用自带的 `rust-objcopy` 生成 `sample_embedded.bin` 和 `sample_embedded.hex`，对应
`0x08008000` 处的应用区。板级接线和烧录说明见 `sample_embedded/README.md`。

## 工作原理

**Linux 目标。** Rust 的 musl 目标需要 C 链接器和 libc，这两样都由 Zig 提供：`tools/wrappers/` 里的
小包装脚本转调 `zig cc -target <zig-triple>`，Zig 在首次使用时编译 musl 和编译器运行时并缓存起来。
包装脚本还会去掉 `cc` 和 `rustc` 传入、但 Zig 不接受的参数。

**不依赖 Visual Studio 的 Windows 目标。** 链接 `x86_64-pc-windows-msvc` 程序通常需要微软的导入库和
C 运行时。工具链用 Zig 自带的文件生成替代品，放在 `tools/sysroot/x86_64-pc-windows-msvc/lib/`：

- 系统 DLL 的导入库，由 mingw-w64 的模块定义文件生成；
- `msvcrt.lib`，作为 `ucrtbase.dll` 的导入库，后者是 Windows 10 及以上系统的组成部分；
- `rpc_winshim.lib`，一个小的补充库，提供没有任何 Windows DLL 导出的符号：栈探测、`printf` /
  `scanf` 系列、程序入口等。

链接由 Rust 自带的 `rust-lld` 完成，不再分发任何微软许可的文件。这个 sysroot 的位置是稳定的约定：
其他工具可以通过检查它来判断某个安装能否链接 Windows 程序。

**裸机目标。** `thumbv7em-none-eabihf` 用 `rust-lld` 链接，完全不使用 C 工具链。

**隔离。** 激活时把 `CARGO_HOME`、`RUSTUP_HOME` 和 Zig 缓存目录指向工具链内部，并把工具链的程序放到
`PATH` 最前面，只对当前会话有效。每个构建脚本还会清掉不属于它的编译器相关环境变量，避免构建受其他
工具遗留设置的影响。

**精简过的 Zig。** Zig 自带它能支持的所有平台的头文件和 libc 源码。安装时会删掉工具链用不到的部分
（macOS、glibc、WASI、其他 CPU 架构），约占 Zig 文件数的 40%。受支持的目标能用到的内容全部保留，
包括完整的 C++ 运行时。

## 脚本参考

### 安装与激活

| 脚本 | 用途 |
|---|---|
| `scripts/rust_setup.ps1` | 下载工具链并安装到 `tools/`。可重复运行；`-Force` 会先清缓存。 |
| `scripts/rust_env.ps1` | 在当前会话中激活工具链。必须用点号加载。 |

`rust_env.ps1` 导出 `RUST_PORTABLE_CROSS_ROOT`、`CARGO_HOME`、`RUSTUP_HOME`、`RUSTUP_TOOLCHAIN`、
`ZIG_LOCAL_CACHE_DIR` 和 `ZIG_GLOBAL_CACHE_DIR`，为 ARMv7 和 ARM64 目标设置 `CC_*`、`AR_*`、
`RANLIB_*`，并更新 `PATH`。

它不会设置不带后缀的 `AR` 和 `RANLIB`：`cc` 会把它们用于所有目标，包括 Windows 主机，而 GNU 风格的
归档器在那里会失败。如果旧版本留下了 `AR=zig-ar.cmd` 或 `RANLIB=zig-ranlib.cmd`，激活时会把它删掉；
其他值会保留并给出警告。

### 构建脚本

| 脚本 | 目标 | 参数 |
|---|---|---|
| `scripts/rust_build_armv7.ps1` | `armv7-unknown-linux-musleabihf` | 无；在项目目录中运行 |
| `scripts/rust_build_aarch64.ps1` | `aarch64-unknown-linux-musl` | 无；在项目目录中运行 |
| `scripts/rust_build_thumbv7em.ps1` | `thumbv7em-none-eabihf` | 无；在项目目录中运行 |
| `scripts/rust_build_x64_win_native.ps1` | `x86_64-pc-windows-msvc` | `-ProjectPath`（默认当前目录）、`-DebugBuild` |

### 检查脚本

| 脚本 | 验证的内容 |
|---|---|
| `check_tool_armv7.ps1` | 自带示例能为 ARMv7 Linux 构建。 |
| `check_tool_aarch64.ps1` | 自带示例能为 ARM64 Linux 构建。 |
| `check_tool_thumbv7em.ps1` | 在去掉主机 Visual Studio 环境的情况下，嵌入式示例能构建。 |
| `check_tool_x64_win.ps1` | Windows 构建是自包含的：去掉主机 Visual Studio 环境后构建并运行产物，只要链接器用到了工具链之外的文件就判为失败。 |

### 维护与发布

| 脚本 | 用途 |
|---|---|
| `scripts/build_win_link_inputs.ps1` | 用自带的 Zig 重新生成 Windows 链接输入（`-Force` 全部重建）。不需要联网，也不需要微软的工具。 |
| `scripts/prepare_offline_release.ps1` | 在 `dist/staging` 下组装并校验安装包内容。 |
| `build.ps1` | 构建离线安装包，见[构建发布包](#构建发布包)。 |
| `ci.ps1` | 运行仓库的各项检查，见[开发](#开发)。 |

## 下载配置

`rust_setup.ps1` 按以下顺序尝试下载源：

1. 直接指定的 URL（`RUST_PORTABLE_CROSS_RUSTUP_INIT_URL`、`RUST_PORTABLE_CROSS_ZIG_URL`）；
2. 镜像列表（`RUST_PORTABLE_CROSS_RUSTUP_MIRRORS`、`RUST_PORTABLE_CROSS_ZIG_MIRRORS`）；
3. 镜像基础 URL（`RUST_PORTABLE_CROSS_RUSTUP_MIRROR_BASE`、`RUST_PORTABLE_CROSS_ZIG_MIRROR_BASE`）；
4. 代理前缀（`RUST_PORTABLE_CROSS_DOWNLOAD_PROXY_PREFIX`）；
5. 官方上游。

无论来自哪个源，下载的文件只有在 SHA-256 摘要与 `scripts/dependency-lock.json` 中记录的值一致时才会
被接受。

| 变量 | 说明 |
|---|---|
| `RUST_PORTABLE_CROSS_RUSTUP_INIT_URL` | `rustup-init.exe` 的直接下载地址 |
| `RUST_PORTABLE_CROSS_ZIG_URL` | Zig 压缩包的直接下载地址 |
| `RUST_PORTABLE_CROSS_RUSTUP_MIRRORS` | rustup 的镜像地址，用 `;`、`,` 或换行分隔 |
| `RUST_PORTABLE_CROSS_ZIG_MIRRORS` | Zig 的镜像地址，用 `;`、`,` 或换行分隔 |
| `RUST_PORTABLE_CROSS_RUSTUP_MIRROR_BASE` | 镜像基础 URL，与内置的相对路径拼接 |
| `RUST_PORTABLE_CROSS_ZIG_MIRROR_BASE` | 镜像基础 URL，与内置的相对路径拼接 |
| `RUST_PORTABLE_CROSS_DOWNLOAD_PROXY_PREFIX` | 加在官方上游 URL 前面的前缀 |
| `RUST_PORTABLE_CROSS_WGET_PATH` | 用于下载的 `wget` 可执行文件的完整路径 |
| `RUST_PORTABLE_CROSS_DOWNLOAD_RETRIES` | wget 和 curl 的重试次数（默认 6） |
| `RUST_PORTABLE_CROSS_CURL_IP_MODE` | 强制 curl 使用 IPv4 或 IPv6：`4`、`6` 或 `auto` |

如果你没有自己设置，安装脚本会把 `RUSTUP_DIST_SERVER` 指向 `https://rsproxy.cn`，把
`RUSTUP_UPDATE_ROOT` 指向 `https://rsproxy.cn/rustup`，在中国大陆下载更稳定。

## 构建发布包

`build.ps1` 用来生成离线安装包。它需要一套已搭建好的工具链（上面的方式 B）和
[Inno Setup](https://jrsoftware.org/isdl.php) 6。

准备 staging 前，脚本会用 `cargo fetch --locked --offline` 检查自带的 Cargo 缓存。缺少依赖时，
它会使用自带的工具链，把锁文件中的全部依赖下载到 `tools/cargo-home`。首次补齐缓存需要联网；
缓存完整且 `sample/Cargo.lock` 未变化时，后续构建可以离线运行。直接运行
`prepare_offline_release.ps1` 仍会检查离线依赖，缓存不完整时会报错。

```powershell
git tag v1.6.0          # 版本号取自最新的标签
.\build.ps1
```

| 参数 | 作用 |
|---|---|
| `-Version` | 使用指定的 `x.y.z` 版本号，而不是最新的 git 标签。 |
| `-IsccPath` | `ISCC.exe` 不在标准位置时指定其路径。 |
| `-SkipStaging` | 复用已有的 staging，不重新生成。仍然会做校验。 |
| `-ValidateInstall` | 额外把生成的 EXE 安装到一个临时目录，并对它运行离线冒烟构建。会多花几分钟。 |

一次构建的步骤：

1. **准备 staging。** `prepare_offline_release.ps1` 检查工具链，重新生成 Windows 链接输入，运行自包含
   检查，把内容复制到 `dist/staging`，并写出包含每个文件 SHA-256 摘要的完整性索引。
2. **校验。** 检查 staging 的版本、固定的工具、文件清单和摘要。
3. **编译。** Inno Setup 把内容压缩成
   `dist/installer/rust-portable-cross-offline-<version>.exe`。
4. **验证（仅在使用 `-ValidateInstall` 时）。** 把 EXE 安装到 `dist/v` 下，为每个目标离线构建完整的
   示例，检查产物，然后删除这次安装。
5. **发布。** 把 EXE 复制到仓库旁边的 `output` 目录，并切成 24 MB 的分片，附带清单，便于放在有大小
   限制的下载服务上。

如果安装包的内容有变化，对外发布前请带 `-ValidateInstall` 构建一次。

发布内容约有 1 万个小文件。如果构建很慢，请把 `dist` 加入杀毒软件的实时扫描排除项。使用 Microsoft
Defender 时，在仓库根目录用管理员身份的 PowerShell 执行：

```powershell
Add-MpPreference -ExclusionPath (Join-Path (Get-Location) 'dist')
```

## 开发

### 测试

`ci.ps1` 是唯一的验证入口。它并行运行各项检查，一次运行报告所有失败，只要有检查失败就以非零退出。

```powershell
.\ci.ps1          # 默认检查：一到两分钟，不需要已安装的工具链
.\ci.ps1 -Full    # 另外运行四个 check_tool_*.ps1 和 test/full/*.ps1；需要 tools\
```

| 检查 | 覆盖的内容 |
|---|---|
| `powershell-syntax` | 所有被跟踪的 `.ps1` 文件都能解析。 |
| `documentation-integrity` | 英文 README 和用户指南里引用的每个工具链路径都存在，并且所有被跟踪的文档都不含多余的控制字符。 |
| `test/*.tests.ps1` | `test\` 下的每个测试套件，自动发现而不是手工列出。 |
| `openspec-validate` | 对规格文件执行 `openspec validate --all --strict`。 |

前置条件不满足的检查会报告 `SKIP` 并说明原因。跳过不算通过，最终结论里会写明有多少项没有运行。
测试套件通过打印 `SKIP: <reason>` 并以退出码 3 结束来表示跳过。

单独运行一个测试套件：

```powershell
pwsh -NoProfile -File .\test\rust_setup.tests.ps1
```

### 提交检查

```powershell
.\ci.ps1 -InstallHook
```

这会把当前克隆的 `core.hooksPath` 指向受版本控制的 `.githooks\`，之后 `git commit` 会运行默认检查，
检查失败就拒绝提交。它需要每个克隆各自启用一次，重复安装不会有任何影响；如果 `core.hooksPath` 不是
它设置的，安装程序会拒绝覆盖。

| 绕过方式 | 效果 |
|---|---|
| `git commit --no-verify` | 这一次提交跳过检查。 |
| `$env:RUST_PORTABLE_CROSS_SKIP_CI = "1"` | 脚本化的提交跳过检查。 |
| `git config --unset core.hooksPath` | 在这个克隆里卸载提交检查。 |

提交检查针对的是工作区，而不是暂存区；两者不一致时会给出警告。合并或变基进行中时它会自动跳过。
每次跳过都会单独写明，不会被报告成通过。

### 规格

项目承诺的行为记录在 `openspec/specs/` 下，每项能力一个目录；变更的提出和归档在
`openspec/changes/` 下。改变行为的修改要在同一个提交里更新对应的规格。

## 仓库结构

```
rust-portable-cross/
├── build.ps1                     # 构建离线安装包
├── ci.ps1                        # 验证入口和提交检查
├── check_tool_*.ps1              # 各目标的健康检查
├── .githooks/pre-commit          # 运行 ci.ps1；用 ci.ps1 -InstallHook 安装
├── config/.cargo/config.toml     # Linux 目标的 Cargo 链接器设置
├── docs/
│   └── customer/README-offline.md  # 随安装包发布的用户指南
├── openspec/                     # 规格和变更记录
├── packaging/inno/               # Inno Setup 安装脚本
├── sample/                       # std 示例项目
├── sample_embedded/              # no_std 固件示例（HEM6801E）
├── scripts/
│   ├── rust_setup.ps1            # 一次性安装工具链
│   ├── rust_env.ps1              # 激活（用点号加载）
│   ├── rust_build_*.ps1          # 各目标的构建脚本
│   ├── build_win_link_inputs.ps1 # 生成 Windows 链接输入
│   ├── prepare_offline_release.ps1  # 组装安装包内容
│   ├── finalize_offline_install.ps1 # 安装结束时运行
│   ├── dependency-lock.json      # 固定的版本和下载摘要
│   └── ...                       # 公共辅助脚本
├── test/                         # 由 ci.ps1 运行的测试套件
│   └── full/                     # 需要工具链的慢速检查
├── tools/                        # 已安装的工具链（生成的，不入库）
│   ├── cargo-home/               # CARGO_HOME
│   ├── rustup-home/              # RUSTUP_HOME
│   ├── zig/                      # Zig 编译器
│   ├── wrappers/                 # Zig 编译器和归档器的包装脚本
│   ├── sysroot/                  # 生成的 Windows 链接输入
│   └── downloads/                # 下载缓存
└── dist/                         # 构建输出（生成的，不入库）
```

## 常见问题

**提示找不到构建脚本或 `cargo`。**
当前会话没有激活。在工具链目录里用点号加载 `scripts/rust_env.ps1`，开头的点和空格不能少。不带点
直接运行脚本，不会改变当前会话。

**出现 "Missing Windows link inputs" 或 `could not open 'kernel32.lib'`。**
生成的链接输入缺失或不完整。重新生成：

```powershell
.\scripts\build_win_link_inputs.ps1 -Force
```

**编译含 C 代码的 crate 时出现 `ar: error: unknown option n`。**
为 Windows 主机构建时，不带后缀的 `AR` 变量指向了 GNU 风格的归档器。用当前版本的工具链重新激活，
它会清掉旧版本设置的值。如果 `AR` 是你自己设置的，请取消，或者改用 `AR_<target>`。

**Windows 目标上找不到 `afx.h` 或 ATL 之类的 C 头文件。**
这个 crate 的 C 代码需要微软自己的头文件。自带的编译器提供 mingw-w64 头文件，覆盖 Windows API，但不
包含 MFC、ATL 等 Visual Studio 的库。这种 crate 需要真正的 MSVC 环境。

**链接时出现未定义的 `wprintf`、`swprintf` 等宽字符格式化函数。**
补充库只提供窄字符的 `printf` 和 `scanf` 系列。把缺少的函数加到
`scripts/build_win_link_inputs.ps1` 的符号列表里，然后重新生成。

**`thumbv7em-none-eabihf` 的固件在链接时失败。**
裸机程序需要一个描述芯片内存布局的链接脚本。可以从 `sample_embedded/link.x` 和
`sample_embedded/build.rs` 开始改。

**某个目标的第一次构建很慢。**
Zig 在首次使用时要为该目标编译 C 库和编译器运行时，然后缓存到 `tools/zig-global-cache/`。之后的
构建会复用缓存。

**在装有杀毒软件的机器上，构建或安装很慢。**
时间主要花在对上万个小文件的实时扫描上。把工具链目录（制作发布包时是 `dist`）加入排除项，可以消除
大部分延迟。

**工具链目录被移动了。**
从新位置重新激活即可。路径是根据脚本所在位置推导出来的，没有保存在别处。

## 已知限制

- 只支持 Windows x86-64 作为主机。
- Rust 和 Zig 的版本是固定的；要更换版本，需要更新 `scripts/dependency-lock.json` 并重新验证发布包。
- Linux 目标只支持 musl，不支持 glibc。
- Windows 目标的 C 代码是按 mingw-w64 头文件编译的，依赖微软专有头文件的代码需要主机上有 MSVC。
- Windows 目标的 C 代码不能使用 `pthread.h`。
- Windows 目标的 C 代码没有宽字符的 `printf` / `scanf` 函数。
- 激活后直接用 `cargo` 时，**主机**的 C 代码由本机自己的 C 编译器编译；只有
  `rust_build_x64_win_native.ps1` 能在没有 Visual Studio 的情况下编译主机的 C 代码。

## 参与贡献

欢迎在 <https://gitee.com/yoursmengle/rust-portable-cross> 提交 issue 和 pull request。

提交修改之前：

1. 运行 `.\ci.ps1`；如果修改涉及工具链、构建脚本或发布内容，再运行 `.\ci.ps1 -Full`。
2. 改变了行为，就在 `test/` 下新增或更新相应的测试。
3. 行为有变化时，更新 `openspec/specs/` 下对应的规格。
4. 如果用户能感知到这次修改，请同步更新 `README.md`、本文件或
   `docs/customer/README-offline.md`。英文 README 和用户指南里出现不存在的路径时，文档检查会失败。

安装提交检查（`.\ci.ps1 -InstallHook`）后，每次提交都会运行默认检查。

## 许可证

rust-portable-cross 以 GNU Affero General Public License 第 3 版授权，见 [`LICENSE`](LICENSE)。

工具链会下载并再分发第三方软件，它们各自遵循自己的许可证，包括
[Rust](https://www.rust-lang.org/)（MIT / Apache-2.0）、[Zig](https://ziglang.org/)（MIT）及其自带的
musl、mingw-w64、LLVM libc++ 和 libunwind 源码，以及示例项目使用的 crate。生成的 Windows 链接输入在
旁边的 `PROVENANCE.json` 里记录了每个文件的来源和许可证；安装包里还附带示例依赖及其许可证的清单。
