# 给 rust-portable-cross 的问题说明（待发出）

**状态：本文档已备好，尚未提交到 rust-portable-cross 仓库/责任人**——本变更没有该仓库的
写入权限，实际提出这一步需要人工完成。

## 一句话

工具链**有链接器、没有链接输入**：`x86_64-pc-windows-msvc` 的链接依赖 Windows SDK 的系统
导入库与 MSVC 的 CRT 导入库，而这两者都不在安装包内，于是一台没有装 Visual Studio 的客户
机器用工具链构建 x64 目标必然失败。

## 实测证据

完整记录见本变更目录的 `evidence/link-failure-output.md`。要点：

1. **链接器本身够用。** 只用 `tools\rustup-home\...\x86_64-pc-windows-msvc\bin\rust-lld.exe`
   （即 `scripts\rust_build_x64_win_native.ps1` 已经在设的那个）就能链出可运行的 exe，
   全程没有 `link.exe`。
2. **缺的是导入库。** `rustc --print link-args` 显示链接消耗
   `kernel32.lib ntdll.lib userenv.lib ws2_32.lib dbghelp.lib` 与 `/defaultlib:msvcrt`。
   把 SDK 从 lld 的搜索范围里拿掉后（`/winsysroot:` 指向空目录），逐字输出是：

   ```
   rust-lld: error: could not open 'kernel32.lib': no such file or directory
   rust-lld: error: could not open 'ntdll.lib': no such file or directory
   ...
   ```

3. **安装包里没有这些文件。** 全树搜索 `kernel32.lib` 无结果；
   `tools\rustup-home\...\x86_64-pc-windows-msvc\lib\` 下除 rlib/rmeta 外只有
   `std-*.dll` / `std-*.dll.lib` / `std-*.pdb`，没有 `self-contained\`。
4. **`install-layout.json` 里 `x64_win` 不是组件**：它搭的是宿主工具链的便车，
   隐含假设宿主已装 VS。
5. **在装了 VS 的机器上它之所以能过**，是因为 rustc 会把探测到的 VS/SDK 目录注入 `LIB`，
   而且 lld 自己也带一套 MSVC/SDK 探测（`-verbose` 可见它直接读
   `C:\Program Files (x86)\Windows Kits\10\Lib\...\um\x64\kernel32.lib`）。
   这正是这个缺口一直没暴露的原因——开发机都装了 VS。

## 一个文档问题

`docs\README-offline.md` 第 62 行称 x64 构建「uses only this installer's
`tools/cargo-home` and `tools/rustup-home` toolchain」。在缺 MSVC/SDK 的机器上这句不成立，
建议同步修正。

## 两条可选修法（由工具链侧决定）

- **A. 随包获取 MSVC CRT + Windows SDK 的 lib（xwin 式）**：在用户机上下载并接受微软许可，
  ABI 与现状完全一致，交付产物不变。
- **B. 新增 `x86_64-pc-windows-gnu` 目标组件**：Rust 自带 self-contained mingw 导入库，
  配合已随包的 zig 即可完全自足；代价是交付产物 ABI 改变，需与 HEC 侧的 PE 校验和项目模板
  一起决定。

## HEC 侧已做的配合

- 就绪判定与运行中归因已改为区分「缺链接器」和「缺链接输入」，两者各自给出指引，并且都
  同时给出「装 VS Build Tools」与「装/更新 rust-portable-cross」两条路。
- 探测已预留工具链来源：`crates/hec-core/src/health.rs` 的 `TOOLKIT_LINK_INPUT_DIR`
  （暂定 `tools/msvc-sysroot`，其下 `sdk/x64` 与 `lib/x64`）。**该目录名待双方确认**；
  确认后 HEC 侧只需改这一个常量，工具链发布带链接输入的版本即可让判定自动转为就绪，
  无需 HEC 再发一版。
