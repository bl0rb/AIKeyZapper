//! `apiKeyHelper` for Claude Code: prints the key of one profile. See `keyzapper_core::helper`.

use keyzapper_core::helper::HelperCommand;
use keyzapper_core::keys::KeyStore;
use keyzapper_core::managed::ManagedConfig;
use keyzapper_core::metadata::MetadataStore;
use std::io::{Read, Write};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let output = HelperCommand::new(MetadataStore::default(), KeyStore::default(), ManagedConfig::load()).run(&args, || {
        let mut input = String::new();
        let _ = std::io::stdin().read_to_string(&mut input);
        input
    });
    let _ = std::io::stdout().write_all(output.stdout.as_bytes());
    let _ = std::io::stderr().write_all(output.stderr.as_bytes());
    std::process::exit(output.exit_code as i32);
}
