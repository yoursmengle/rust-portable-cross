use proc_macro::TokenStream;

#[proc_macro]
pub fn marker(_: TokenStream) -> TokenStream {
    "fn macro_marker() -> &'static str { \"proc-macro\" }"
        .parse()
        .expect("valid release smoke macro")
}
