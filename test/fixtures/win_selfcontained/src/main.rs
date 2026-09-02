// Exercises the parts of the runtime that the generated link inputs are
// responsible for. Every check prints a line and the process exits non-zero on
// the first failure, so check_tool_x64_win.ps1 can assert on the output.

use std::panic;

extern "C" {
    fn rpc_probe_add(a: i32, b: i32) -> i32;
    fn rpc_probe_crt() -> i32;
}

fn recurse_then_panic(depth: u32) {
    if depth == 0 {
        panic!("deliberate panic from the self-containment fixture");
    }
    recurse_then_panic(depth - 1);
    // Keeps the frame alive so the unwinder has real cleanup to walk through.
    println!("unreachable {depth}");
}

fn main() {
    // The bundled C compiler produced an object that links and runs.
    let sum = unsafe { rpc_probe_add(19, 23) };
    assert_eq!(sum, 42, "C interop returned {sum}");
    println!("c-interop: ok");

    // The C side reached the same CRT the Rust side uses.
    let length = unsafe { rpc_probe_crt() };
    assert_eq!(length, 8, "C runtime probe returned {length}");
    println!("c-runtime: ok");

    // Unwinding across several frames, driven by ucrtbase's __CxxFrameHandler3.
    let previous = panic::take_hook();
    panic::set_hook(Box::new(|_| {}));
    let caught = panic::catch_unwind(|| recurse_then_panic(8)).is_err();
    panic::set_hook(previous);
    assert!(caught, "catch_unwind did not observe the panic");
    println!("catch-unwind: ok");

    // A panic that unwinds out of a thread, joined back on the main thread.
    let handle = std::thread::spawn(|| -> u32 {
        panic::set_hook(Box::new(|_| {}));
        panic::catch_unwind(|| recurse_then_panic(4)).ok();
        7
    });
    assert_eq!(handle.join().expect("thread joined"), 7);
    println!("thread-unwind: ok");

    // Thread locals need the TLS directory the shim supplies.
    thread_local! {
        static COUNTER: std::cell::Cell<u32> = const { std::cell::Cell::new(0) };
    }
    COUNTER.with(|c| c.set(c.get() + 5));
    let local = std::thread::spawn(|| COUNTER.with(|c| c.get()))
        .join()
        .expect("thread joined");
    assert_eq!(COUNTER.with(|c| c.get()), 5, "main thread local");
    assert_eq!(local, 0, "spawned thread must see its own thread local");
    println!("thread-local: ok");

    // Allocation, formatting and sorting, which pull in the CRT's memory and
    // string routines from the Rust side.
    let mut values: Vec<String> = (0..500).map(|i| format!("value-{i:04}")).collect();
    values.sort();
    assert_eq!(values.len(), 500);
    assert_eq!(values[0], "value-0000");
    println!("alloc-and-fmt: ok");

    println!("SELFCONTAINED OK");
}
