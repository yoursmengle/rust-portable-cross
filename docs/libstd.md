# rust-portable-cross 补齐 Rust target libstd 组件需求

  ## 1. 背景

  HEC AI Studio 使用 rust-portable-cross 提供受管 Rust 工具链。当前工具链存在以下问题：

  - rustup target list --installed 显示目标已安装；
  - 但实际目标目录不存在，或目录中没有 libstd 文件；
  - 因此 rustc 无法真正编译 armv7-unknown-linux-musleabihf 项目；
  - HEC AI Studio 已增加实际文件探测，会将此状态报告为工具链损坏或目标组件缺失。

  这不是 HEC 项目生成 libstd 失败，而是 portable toolchain 发布内容不完整，或者安装后文件与 rustup 元数据不一致。

  ## 2. 必须提供的标准库目标

  以下目标必须随同一个受管 Rust toolchain 提供完整 rust-std 组件：

   Rust target                       是否必须提供 libstd    用途
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  ━━━━━━━━━━━━━━━━━━━━━  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   x86_64-pc-windows-msvc                             是    Windows 主机程序、HEC Core、主机测试
  ────────────────────────────────  ─────────────────────  ──────────────────────────────────────
   armv7-unknown-linux-musleabihf                     是    hec1020 等 ARMv7 Linux 目标
  ────────────────────────────────  ─────────────────────  ──────────────────────────────────────
   aarch64-unknown-linux-musl                         是    ARM64 Linux 目标
  ────────────────────────────────  ─────────────────────  ──────────────────────────────────────
   thumbv7em-none-eabihf                              否    裸机固件，使用 no_std

  必须保证前三个目标在同一个 toolchain 目录中，并且与当前 rustc 的版本和 commit hash 完全匹配。

  ## 3. libstd 文件要求

  不能只复制一个名为 libstd 的文件，必须安装完整的 Rust rust-std target component。

  目标目录结构必须类似：

  <toolkit>\
    tools\
      rustup-home\
        toolchains\
          <toolchain-name>\
            bin\
              rustc.exe
              cargo.exe
            lib\
              rustlib\
                x86_64-pc-windows-msvc\
                  lib\
                    libstd-<hash>.rlib
                    libstd-<hash>.rmeta
                    ...
                armv7-unknown-linux-musleabihf\
                  lib\
                    libstd-<hash>.rlib
                    libstd-<hash>.rmeta
                    ...
                aarch64-unknown-linux-musl\
                  lib\
                    libstd-<hash>.rlib
                    libstd-<hash>.rmeta
                    ...
                thumbv7em-none-eabihf\
                  lib\
                    libcore-<hash>.rlib
                    libcompiler_builtins-<hash>.rlib
                    ...

  其中：

  - libstd-<hash>.rlib 是标准库编译产物；
  - libstd-<hash>.rmeta 是标准库元数据；
  - <hash> 必须来自同一版本 Rust 工具链；
  - 文件不能是空文件或占位文件；
  - 目标目录必须真实存在；
  - libstd 的依赖文件也必须完整，例如 liballoc、libcore、libcompiler_builtins 等；
  - 不允许只更新 rustup 的安装记录而不释放实际文件。

  HEC 当前会检查：

  <toolchain>/lib/rustlib/<target>/lib/

  并确认其中存在：

  libstd-*.rlib
  或
  libstd-*.rmeta

  ## 4. 版本一致性要求

  所有目标组件必须与受管 rustc 保持一致：

  rustc -Vv

  需要确认：

  - rustc release 一致；
  - rustc commit-hash 一致；
  - 三个 rust-std 组件来自同一 Rust release；
  - 不能混用不同 nightly、不同 stable 版本或不同 commit 的标准库文件；
  - 不能使用系统 Rust 覆盖 portable toolchain。

  建议在构建 portable 工具链时统一使用：

  host: x86_64-pc-windows-msvc
  targets:
    x86_64-pc-windows-msvc
    armv7-unknown-linux-musleabihf
    aarch64-unknown-linux-musl
    thumbv7em-none-eabihf

  ## 5. 目标三元组解析要求

  以下命令必须成功：

  . D:\rust-portable-cross\scripts\rust_env.ps1

  rustc --print target-libdir --target x86_64-pc-windows-msvc
  rustc --print target-libdir --target armv7-unknown-linux-musleabihf
  rustc --print target-libdir --target aarch64-unknown-linux-musl
  rustc --print target-libdir --target thumbv7em-none-eabihf

  前三个命令输出的目录必须存在，并且包含对应的标准库文件。

  不能出现：

  target triple cannot be resolved
  can't find crate for `std`
  E0463: can't find crate for `std`

  ## 6. thumbv7em-none-eabihf 的特殊要求

  thumbv7em-none-eabihf 是裸机固件目标，HEC 使用 #![no_std]，因此不需要 libstd。

  但仍需保证以下内容可用：

  - libcore
  - libcompiler_builtins
  - 若模板使用动态内存，再提供 liballoc
  - 目标规格文件和 rustc target resolver 正常
  - 固件所需 linker、运行时库和相关工具仍然存在

  不能因为该目标没有 libstd 就将整个工具链判定为损坏。

  ## 7. rust_env.ps1 和安装脚本要求

  rust_env.ps1 必须确保 HEC 使用 portable 工具链：

  $env:RUSTUP_HOME = "<toolkit>\tools\rustup-home"
  $env:CARGO_HOME = "<toolkit>\tools\cargo-home"
  $env:PATH = "<toolkit>\tools\...;" + $env:PATH

  要求：

  - rustc、cargo、rustup 均来自 portable 工具链；
  - 不依赖用户机器上的系统 Rust；
  - rust_setup.ps1 必须可重复执行；
  - 已存在但损坏的目标组件必须能够修复；
  - 不能因为 rustup 元数据显示“up to date”就跳过实际文件恢复。

  特别注意：

  rustup target list --installed

  只能证明 rustup 元数据中有记录，不能证明目标标准库文件真实存在。安装器必须额外检查目标目录和文件。

  ## 8. 离线安装包要求

  离线安装包必须包含上述目标组件的实际内容，而不是只包含：

  - rustc.exe
  - cargo.exe
  - rustup 元数据
  - target 安装列表
  - 空的 rustlib/<target>/lib 目录

  安装包发布前必须执行：

  1. 解压到临时目录；
  2. 激活 rust_env.ps1；
  3. 检查 rustc -Vv；
  4. 检查三个 std target 的 target-libdir；
  5. 检查每个目录中存在 libstd-*.rlib 或 .rmeta；
  6. 执行编译验证；
  7. 验证通过后再生成离线包和 SHA-256 manifest。

  如果使用分片下载包，需要同步更新：

  - 原始文件大小；
  - 原始文件 SHA-256；
  - 分片数量；
  - 分片大小；
  - 分片 SHA-256。

  ## 9. 最低验收命令

  建议在发布流水线中运行以下检查：

  . D:\rust-portable-cross\scripts\rust_env.ps1

  $targets = @(
    "x86_64-pc-windows-msvc",
    "armv7-unknown-linux-musleabihf",
    "aarch64-unknown-linux-musl"
  )

  foreach ($target in $targets) {
    $libdir = (rustc --print target-libdir --target $target | Select-Object -Last 1).Trim()

    if (-not (Test-Path -LiteralPath $libdir -PathType Container)) {
      throw "Missing target libdir: $target => $libdir"
    }

    $std = Get-ChildItem -LiteralPath $libdir -File |
      Where-Object { $_.Name -match '^(lib)?std-.*\.(rlib|rmeta)$' }

    if (-not $std) {
      throw "Missing libstd payload: $target => $libdir"
    }

    Write-Host "OK: $target => $libdir"
  }

  还需要使用临时 Rust 项目验证：

  cargo check --target x86_64-pc-windows-msvc
  cargo check --target armv7-unknown-linux-musleabihf
  cargo check --target aarch64-unknown-linux-musl

  如果交叉 linker 配置完整，再增加：

  cargo build --target armv7-unknown-linux-musleabihf
  cargo build --target aarch64-unknown-linux-musl

  ## 10. 发布判定

  以下任一条件不满足，都不能将 portable toolchain 标记为可用：

  - armv7-unknown-linux-musleabihf 缺少 libstd；
  - aarch64-unknown-linux-musl 缺少 libstd；
  - host target 缺少 libstd；
  - rustc --print target-libdir 输出目录不存在；
  - 标准库版本与 rustc 不一致；
  - 只存在 rustup 元数据，没有实际文件；
  - 离线安装后文件未被正确释放；
  - 安装脚本仍然激活系统 Rust。

  ## 11. 责任边界

  请明确区分：

  - rust-portable-cross：负责提供 Rust 编译器、rust-std、目标组件、linker 和工具链环境；
  - HEC Target 包：只负责 target.json、技能说明、项目模板和目标相关业务代码；
  - HEC 项目自身：只负责使用工具链编译业务代码，不生成 libstd。

  因此，hec1020 Target 包不应携带或生成 libstd。修复点应位于 rust-portable-cross 的构建、打包或安装流程中
  

