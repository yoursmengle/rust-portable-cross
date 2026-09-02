use std::env;
use std::path::PathBuf;
use std::process::Command;

// Compiles csrc/probe.c with whatever $CC the toolkit wired up, then links the
// object straight into the binary. Passing the object with rustc-link-arg avoids
// needing an archiver, which keeps the fixture buildable inside a bare offline
// installation.
fn main() {
    println!("cargo:rerun-if-changed=csrc/probe.c");
    println!("cargo:rerun-if-env-changed=CC");

    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR is set by cargo"));
    let object = out_dir.join("probe.obj");

    let cc = env::var("CC_x86_64_pc_windows_msvc")
        .or_else(|_| env::var("CC"))
        .expect("the toolkit build script must set CC for the Windows host target");

    let status = Command::new(&cc)
        .args(["-c", "-O2", "csrc/probe.c", "-o"])
        .arg(&object)
        .status()
        .unwrap_or_else(|e| panic!("failed to run C compiler '{cc}': {e}"));

    assert!(status.success(), "'{cc}' failed to compile csrc/probe.c: {status}");

    println!("cargo:rustc-link-arg-bins={}", object.display());
}
