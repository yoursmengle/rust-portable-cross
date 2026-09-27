release_smoke_macro::marker!();

fn main() {
    println!("{}:{}", env!("RELEASE_SMOKE_BUILD"), macro_marker());
}
