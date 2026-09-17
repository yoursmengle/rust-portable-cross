# 对 `docs/toolkit-handoff.md` 的答复（工具链侧）

**日期：** 2026-09-03
**答复对象：** `docs/toolkit-handoff.md`（HEC 侧来件，已按原样纳入版本控制，未作任何修改）
**答复方：** rust-portable-cross，产品版本 1.4.5，宿主工具链 `1.98.0-x86_64-pc-windows-msvc`

---

## 一句话

来件描述的缺口已经关闭，走的既不是 A 也不是 B，而是第三条路：**链接输入由工具链自带的
mingw-w64 模块定义文件现场生成**。ABI 不变、无需下载、不再发行任何微软文件。当前仍未解决的
只剩一件事——**双方对目录路径的约定不一致**，本文给出工具链侧的正式承诺值。

---

## 一、逐条核对来件的断言

| # | 来件断言 | 当前状态 | 依据 |
|---|---|---|---|
| 1 | 链接器本身够用，`rust-lld` 能链出可运行 exe，全程无 `link.exe` | **仍然成立**，且这正是现在的常态路径 | `scripts/rust_build_x64_win_native.ps1` |
| 2 | 缺的是导入库（`kernel32.lib` 等 + `/defaultlib:msvcrt`） | **已不成立** | 见下第二节 |
| 3 | 全树搜索 `kernel32.lib` 无结果，无 `self-contained\` | **已不成立** | `tools/sysroot/x86_64-pc-windows-msvc/lib/kernel32.lib` |
| 4 | `install-layout.json` 里 `x64_win` 不是组件，搭宿主便车 | **前半句仍然成立，但已不构成问题** | 见下第三节 |
| 5 | 装了 VS 的机器上能过，是因为 rustc/lld 探测到了宿主 VS/SDK | **已不成立**，宿主探测被主动切断 | 见下第四节 |
| 6 | `README-offline.md` 的"仅用本安装包工具链"一句不成立 | **已不成立**，该句现在准确 | 见下第五节 |

关闭这一缺口的提交区间：`53c03d2`（2026-09-02，*add linker libs*）至
`cd6ab2f`（2026-09-03，*fix linker lib error*）。

---

## 二、链接输入现在是什么、在哪里

`tools/sysroot/x86_64-pc-windows-msvc/lib/` 下有 **13 个 `.lib`**：

- **11 个导入库**，由 `tools/zig/lib/libc/mingw` 里自带的 mingw-w64 模块定义文件经
  `zig dlltool` 生成：`kernel32` `ntdll` `userenv` `ws2_32` `dbghelp`（rustc 为任何默认 std
  二进制点名的五个），加上 `advapi32` `user32` `ole32` `oleaut32` `shell32` `bcrypt`
  （windows-sys 一类依赖常见拉入的）。
- **`msvcrt.lib`** —— 满足 rustc 发出的 `/defaultlib:msvcrt`。它不是微软的 `msvcrt.lib`，
  而是 **`ucrtbase.dll` 的导入库**。`ucrtbase.dll` 是 Windows 10 及以后的操作系统组件，
  不是 Visual C++ 可再发行包，所以产物落地不需要装 redist。
- **`rpc_winshim.lib`** —— 补齐没有任何 DLL 导出、因而无法由导入库提供的符号：栈探测
  （`__chkstk` 与 `___chkstk_ms` 两种拼写同一份实现）、TLS 目录与 `.CRT$XLB` 回调括号、
  `mainCRTStartup`、`_fltused`、`atexit`，以及微软头文件里以内联形式存在、从不导出的
  printf/scanf 两族。

同级还有 **`PROVENANCE.json`**，逐文件记录来源资产、生成命令、许可与 SHA256，可用于许可审计。

生成命令：`scripts/build_win_link_inputs.ps1`。它只读取工具链自身 `tools/zig` 下的资产，
**不联网、不读宿主 VS/SDK、不复制任何微软文件**。

---

## 三、打包与安装（对应来件第 4 条）

`x64_win` 确实仍然不是一个独立组件，但它不再"搭便车"：链接输入的全部 **14 个文件**
（13 个 `.lib` + `PROVENANCE.json`）都列在 `dist/staging/core/install-layout.json` 的
**`core`** 组件里，而 `core` 是恒装组件。也就是说：

> 任何一次安装，无论用户勾选了哪些交叉目标，都必然带有完整的 x64 链接输入。

`scripts/prepare_offline_release.ps1` 在每次发布时重新生成该 sysroot，因此交付的内容
始终与生成脚本一致。

---

## 四、宿主 VS/SDK 被主动切断（对应来件第 5 条）

`scripts/rust_build_isolation.ps1` 在调用 cargo 前清空 **11 个宿主 MSVC/SDK 发现变量**：
`LIB` `INCLUDE` `LIBPATH` `VCINSTALLDIR` `VSINSTALLDIR` `VCToolsInstallDir` `WindowsSdkDir`
`WindowsSdkVerBinPath` `WindowsSDKLibVersion` `UniversalCRTSdkDir` `UCRTVersion`，并把随包
sysroot 放在链接器搜索路径最前。

因此在**装了 VS 的机器上**，构建同样不会用到宿主的任何一个库——这一点由
`check_tool_x64_win.ps1` 验证：它在擦除宿主 VS 环境的前提下构建，一旦有任何库解析到安装
目录之外就失败。开发机与客户机的构建结果因此是一致的，来件第 5 条描述的"缺口没暴露"的
成因已被消除。

---

## 五、A / B 两条路的裁决

**结论：两条都不采纳，保持现行方案（下称 C）。** 理由如下。

### A（xwin 式：在用户机下载并接受微软许可，取 MSVC CRT + Windows SDK 的 lib）— 不采纳

- **它要求客户机联网并当场接受微软许可。** 本产品的存在前提就是离线安装，目标机器通常
  没有外网，也不适合让现场人员代替公司接受第三方许可条款。这是决定性的。
- 许可限制使它无法预先烤进离线包，只能保留"下载 + 接受"这一步，等于把产品的核心承诺
  换成了一个安装时才知道成不成的动作。
- 在 C 已经落地的前提下，A 对**链接路径**是纯冗余——C 已经把链接需要的全部输入准备好了。

A 唯一的实质优势是**顺带拿到头文件**，这与下面第七节的遗留限制直接相关；但为一个编译期
的边缘场景引入一个安装期的硬依赖，不成比例。

### B（新增 / 切换到 `x86_64-pc-windows-gnu`）— 不采纳

- **它改变交付产物的 ABI。** 来件自己也指出这需要与 HEC 侧的 PE 校验和项目模板一起决定。
- 本仓库是**刻意从 gnu 迁到 msvc 的**：`ebded45`（2026-05-28，*gnu to msvc*）、
  `e1c55fc`（*remove gnu, for test*）、`3b7f00c`（*Statically link CRT for x64_win builds*）。
  采纳 B 等于推翻这条既有决策，需要重新论证当初迁移的理由为何不再成立——目前没有这样的理由。
- 连带成本：宿主 toolchain 三元组变更会波及 `install-layout.json`、rustup toolchain 名称、
  全部 wrapper 脚本，以及 `README-offline.md` 中关于 msvc / `ucrtbase.dll` / 不需 redist 的
  全部表述。

B 的实质优势（Rust 自带 self-contained mingw 导入库，不必维护白名单和 shim）是真实的，但
C 已经把这部分成本压到很低：加一个导入库是 `$script:ImportLibraries` 里的一行；shim 的符号
集由 `$script:RequiredShimSymbols` 声明，生成时逐一校验，缺符号会硬失败并点名。

---

## 六、目录契约（本文的操作性结论）

来件最后一节预留的 `TOOLKIT_LINK_INPUT_DIR` 暂定值是 `tools/msvc-sysroot`，其下
`sdk/x64` 与 `lib/x64`。**这是 xwin 的布局，即按方案 A 预设的形状。** 由于 A 未被采纳，
该布局不会出现。

工具链侧现在正式承诺以下契约：

```
<安装根>/tools/sysroot/<target-triple>/lib/*.lib      ← 扁平，无子目录
<安装根>/tools/sysroot/<target-triple>/PROVENANCE.json ← 清单，与 lib/ 同级
```

对 x64 目标，请把 `crates/hec-core/src/health.rs` 的 `TOOLKIT_LINK_INPUT_DIR` 置为：

```
tools/sysroot/x86_64-pc-windows-msvc/lib
```

就绪判定建议：该目录存在且其中含 `kernel32.lib` 与 `msvcrt.lib`，即可判定该安装具备
x64 链接能力，**无需再检查宿主是否装有 Visual Studio 或 Windows SDK**。若要更严格，
可读同级 `PROVENANCE.json` 的 `files` 数组逐项核对。

该路径已被 `rust_env.ps1`、`rust_build_isolation.ps1`、`prepare_offline_release.ps1`、
`install-layout.json` 与客户文档共同引用，并已写入
`openspec/specs/x64-windows-link-inputs/spec.md` 作为对外契约；工具链侧不会在未通知的情况下
移动它、加深嵌套或拆分到子目录。

**不会提供 `tools/msvc-sysroot` 兼容别名。** 原因有二：在 Windows 上做别名要么把每个 `.lib`
在安装载荷里复制两份，要么建目录符号链接——后者需要管理员权限或开发者模式，恰恰会在本产品
面向的受限客户机上失败；其次，别名会让两个路径永久并列为正式路径，并把一条已被否决的路线的
形状固化成长期契约。这一个常量的修改，请由 HEC 侧承担。

---

## 七、仍然存在的限制（请一并纳入 HEC 侧的归因）

**一个 crate 的 C 代码若确实需要微软自家的头文件**（而非随包的 mingw-w64 头文件），仍然
需要宿主 MSVC 安装。

这一点很重要的是它的**表现形式**：它是 **C build script 的编译错误，报某个微软头文件找不到**，
**不是链接错误**。因此：

- 它不会被"缺链接输入"的判定捕获，也**不可能被就绪探测提前发现**——探测能确认的是链接能力，
  而这是编译期、按 crate、按依赖树而定的。
- HEC 侧若要给出指引，触发条件应当是 C 编译阶段报缺失微软头文件，而不是就绪判定阶段。

除此之外，随包工具链自足：链接不需要 Visual Studio、`link.exe` 或 Windows SDK；产物在
**Windows 10 / Windows Server 2016 及以后**运行，使用系统自带的 `ucrtbase.dll`，不需要
安装 Visual C++ 可再发行包。

---

## 八、来件中一处文档指向的更正

来件"一个文档问题"一节指向 `docs\README-offline.md` 第 62 行。更正两点：

1. 该文件的实际路径是 **`docs/customer/README-offline.md`**。
2. 它被指出的那句话**现在是准确的**——因为 x64 构建确实只用本安装包内的工具链和链接输入。

不过同一份文档另有两处**真实缺陷**，已在本次一并修复：两个路径曾被反斜杠转义解码破坏，
`tools\sysroot\x86_64-...` 中的 `\x86` 被解成了 `U+0086`，`scripts\build_win_link_inputs.ps1`
中的 `\b` 被解成了退格符。客户照着这两行找路径会认为文件不存在。已加入提交门禁检查，
防止同类破坏再次流到客户手里。

---

## 九、需要 HEC 侧做的事

1. 把 `crates/hec-core/src/health.rs` 的 `TOOLKIT_LINK_INPUT_DIR` 改为
   `tools/sysroot/x86_64-pc-windows-msvc/lib`，并按第六节调整就绪判定。
2. 把"需要微软头文件"的归因从就绪判定移到 C 编译失败的归因路径上（第七节）。
3. 现有的"缺链接器 / 缺链接输入"二分保留即可；在装有本工具链 1.4.5 及以后版本的机器上，
   两者都不应再触发。
