use anyhow::{Context, Result};
use base64::{engine::general_purpose, Engine as _};
use chrono::Utc;
use clap::Parser;
use itertools::Itertools;
use log::{info, warn};
use rand::{rngs::StdRng, Rng, SeedableRng};
use rayon::prelude::*;
use regex::Regex;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::time::Duration;
use thiserror::Error;
use tokio::runtime::Builder;
use toml::Value;
use url::Url;
use uuid::Uuid;
use walkdir::WalkDir;

#[derive(Parser, Debug)]
#[command(name = "sample")]
#[command(about = "A richer sample that touches common Rust ecosystem crates")]
struct Cli {
    #[arg(long, default_value = "https://example.com/api")]
    endpoint: String,

    #[arg(long, default_value_t = 42)]
    seed: u64,
}

#[derive(Debug, Error)]
enum AppError {
    #[error("invalid endpoint: {0}")]
    InvalidEndpoint(String),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct AppPayload {
    id: Uuid,
    created_at: chrono::DateTime<chrono::Utc>,
    endpoint: String,
    token: String,
    keywords: Vec<String>,
    checksum_hex: String,
}

fn parse_endpoint(raw: &str) -> std::result::Result<Url, AppError> {
    Url::parse(raw).map_err(|_| AppError::InvalidEndpoint(raw.to_string()))
}

fn collect_rs_files() -> Vec<String> {
    WalkDir::new(".")
        .into_iter()
        .filter_map(std::result::Result::ok)
        .filter(|entry| entry.file_type().is_file())
        .map(|entry| entry.path().display().to_string())
        .filter(|path| path.ends_with(".rs"))
        .collect()
}

fn main() -> Result<()> {
    env_logger::init();
    let cli = Cli::parse();

    let endpoint = parse_endpoint(&cli.endpoint).context("failed to parse --endpoint")?;
    info!("endpoint = {}", endpoint);

    let runtime = Builder::new_multi_thread()
        .enable_time()
        .build()
        .context("failed to build tokio runtime")?;

    runtime
        .block_on(async {
            tokio::time::sleep(Duration::from_millis(10)).await;
            let _client = Client::new();
            Ok::<(), anyhow::Error>(())
        })
        .context("async runtime warmup failed")?;

    let source_text = "portable rust cross toolkit sample 2026";
    let word_re = Regex::new(r"[a-zA-Z]+")?;
    let keywords = word_re
        .find_iter(source_text)
        .map(|m| m.as_str().to_lowercase())
        .unique()
        .collect::<Vec<_>>();

    let mut rng = StdRng::seed_from_u64(cli.seed);
    let salt: u64 = rng.gen_range(1000..9999);

    let payload_text = format!("{}:{}:{}", endpoint, Uuid::new_v4(), salt);
    let token = general_purpose::STANDARD.encode(payload_text.as_bytes());

    let files = collect_rs_files();
    if files.is_empty() {
        warn!("no .rs files found from current directory walk");
    }

    let mut digests = files
        .par_iter()
        .map(|path| {
            let mut hasher = Sha256::new();
            hasher.update(path.as_bytes());
            format!("{:x}", hasher.finalize())
        })
        .collect::<Vec<_>>();
    digests.sort();
    let file_digest = digests.into_iter().join("");

    let mut digest = Sha256::new();
    digest.update(file_digest.as_bytes());
    let checksum_hex = format!("{:x}", digest.finalize());

    let toml_text = r#"
[sample]
enabled = true
name = "portable"
"#;
    let parsed_toml: Value = toml::from_str(toml_text)?;
    let enabled = parsed_toml
        .get("sample")
        .and_then(|s| s.get("enabled"))
        .and_then(Value::as_bool)
        .unwrap_or(false);

    let payload = AppPayload {
        id: Uuid::new_v4(),
        created_at: Utc::now(),
        endpoint: endpoint.to_string(),
        token,
        keywords,
        checksum_hex,
    };

    let json = serde_json::to_string_pretty(&payload)?;
    println!("enabled_from_toml = {}", enabled);
    println!("{}", json);

    Ok(())
}
