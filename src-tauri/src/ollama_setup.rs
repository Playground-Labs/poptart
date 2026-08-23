//! One-step local AI setup: download a standalone Ollama binary, run
//! `ollama serve` as a managed child process, and pull the default model —
//! no Terminal, no Homebrew, no admin prompt.
//!
//! The binary lives in `<app_data>/ollama/`; models go to Ollama's own
//! default (`~/.ollama`), so an existing Ollama install shares its models.
//! If a server is already reachable on the default port (Homebrew service,
//! Ollama.app), setup skips straight to the model pull.

use futures_util::StreamExt;
use log::{debug, info, warn};
use serde::{Deserialize, Serialize};
use specta::Type;
use tauri::AppHandle;
use tauri_specta::Event;

const OLLAMA_BASE: &str = "http://localhost:11434";
/// Redirects to the latest ollama-darwin.tgz GitHub release asset.
const OLLAMA_DOWNLOAD_URL: &str = "https://ollama.com/download/ollama-darwin.tgz";
/// Must match the default post-process model in settings.rs.
pub const DEFAULT_MODEL: &str = "qwen3:8b";
const KEEP_ALIVE: &str = "10m";

#[derive(Debug, Deserialize)]
struct OllamaMessage {
    content: String,
}

#[derive(Debug, Deserialize)]
struct OllamaChatResponse {
    message: OllamaMessage,
    #[serde(default)]
    total_duration: u64,
    #[serde(default)]
    load_duration: u64,
    #[serde(default)]
    prompt_eval_duration: u64,
    #[serde(default)]
    eval_duration: u64,
}

fn duration_ms(nanoseconds: u64) -> u64 {
    nanoseconds / 1_000_000
}

fn cleanup_request_body(
    model: &str,
    system_prompt: String,
    user_content: String,
    schema: serde_json::Value,
) -> serde_json::Value {
    serde_json::json!({
        "model": model,
        "messages": [
            { "role": "system", "content": system_prompt },
            { "role": "user", "content": user_content }
        ],
        "stream": false,
        "think": false,
        "format": schema,
        "keep_alive": KEEP_ALIVE,
        "options": {
            "temperature": 0,
            "num_predict": 512
        }
    })
}

/// Ask Ollama to load the cleanup model while the user is still speaking.
/// Failure is intentionally non-fatal; finalization retains its raw fallback.
pub(crate) async fn warm_model(model: &str) -> Result<(), String> {
    reqwest::Client::new()
        .post(format!("{}/api/generate", OLLAMA_BASE))
        .timeout(std::time::Duration::from_secs(30))
        .json(&serde_json::json!({
            "model": model,
            "prompt": "",
            "stream": false,
            "keep_alive": KEEP_ALIVE,
            "options": { "num_predict": 1 }
        }))
        .send()
        .await
        .map_err(|error| format!("warm-up request failed: {error}"))?
        .error_for_status()
        .map_err(|error| format!("warm-up failed: {error}"))?;
    debug!(
        "Managed Ollama model warm-up completed for model '{}'",
        model
    );
    Ok(())
}

/// Native Ollama cleanup path. It avoids compatibility-layer reasoning fields,
/// requests deterministic bounded generation, and exposes native timing data.
pub(crate) async fn chat_cleanup(
    model: &str,
    system_prompt: String,
    user_content: String,
    schema: serde_json::Value,
) -> Result<String, String> {
    let response = reqwest::Client::new()
        .post(format!("{}/api/chat", OLLAMA_BASE))
        .json(&cleanup_request_body(
            model,
            system_prompt,
            user_content,
            schema,
        ))
        .send()
        .await
        .map_err(|error| format!("native request failed: {error}"))?;
    let status = response.status();
    if !status.is_success() {
        return Err(format!("native request failed with status {status}"));
    }
    let response: OllamaChatResponse = response
        .json()
        .await
        .map_err(|_| "native response was malformed".to_string())?;
    debug!(
        "Managed Ollama timings: model='{}', load_ms={}, prompt_eval_ms={}, generation_ms={}, total_ms={}, output_len={}",
        model,
        duration_ms(response.load_duration),
        duration_ms(response.prompt_eval_duration),
        duration_ms(response.eval_duration),
        duration_ms(response.total_duration),
        response.message.content.len(),
    );
    Ok(response.message.content)
}

#[derive(Serialize, Type)]
pub struct AiStatus {
    pub server_running: bool,
    pub model_ready: bool,
    pub managed_installed: bool,
}

/// Progress for the onboarding UI. `stage` is one of "binary", "server",
/// "model", "done"; `progress` is 0..1 within the stage (-1 = indeterminate).
#[derive(Clone, Serialize, Deserialize, Type, tauri_specta::Event)]
pub struct AiSetupProgress {
    pub stage: String,
    pub progress: f32,
}

fn ollama_dir(app: &AppHandle) -> Result<std::path::PathBuf, String> {
    Ok(crate::portable::app_data_dir(app)
        .map_err(|e| e.to_string())?
        .join("ollama"))
}

fn managed_binary(app: &AppHandle) -> Result<std::path::PathBuf, String> {
    Ok(ollama_dir(app)?.join("ollama"))
}

async fn server_running() -> bool {
    let client = reqwest::Client::new();
    client
        .get(format!("{}/api/version", OLLAMA_BASE))
        .timeout(std::time::Duration::from_secs(2))
        .send()
        .await
        .is_ok()
}

async fn model_ready() -> bool {
    #[derive(Deserialize)]
    struct Tags {
        models: Vec<TagModel>,
    }
    #[derive(Deserialize)]
    struct TagModel {
        name: String,
    }
    let client = reqwest::Client::new();
    let Ok(resp) = client
        .get(format!("{}/api/tags", OLLAMA_BASE))
        .timeout(std::time::Duration::from_secs(2))
        .send()
        .await
    else {
        return false;
    };
    match resp.json::<Tags>().await {
        Ok(tags) => tags.models.iter().any(|m| m.name == DEFAULT_MODEL),
        Err(_) => false,
    }
}

#[tauri::command]
#[specta::specta]
pub async fn check_ai_status(app: AppHandle) -> AiStatus {
    let server = server_running().await;
    AiStatus {
        server_running: server,
        model_ready: server && model_ready().await,
        managed_installed: managed_binary(&app).map(|p| p.exists()).unwrap_or(false),
    }
}

/// Spawn the managed `ollama serve` if nothing is listening. Detached: the
/// server keeps running after Poptart quits, like a service.
/// ponytail: no child lifecycle management; kill/restart UI if ever needed.
pub fn spawn_managed_server(app: &AppHandle) -> Result<(), String> {
    let bin = managed_binary(app)?;
    if !bin.exists() {
        return Err("managed ollama binary not installed".into());
    }
    std::process::Command::new(&bin)
        .arg("serve")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map_err(|e| format!("failed to spawn ollama serve: {e}"))?;
    info!("spawned managed ollama serve from {}", bin.display());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{cleanup_request_body, duration_ms};

    #[test]
    fn native_cleanup_is_deterministic_bounded_and_kept_warm() {
        let body = cleanup_request_body(
            "qwen3:8b",
            "system".to_string(),
            "user".to_string(),
            serde_json::json!({ "type": "object" }),
        );
        assert_eq!(body["think"], false);
        assert_eq!(body["stream"], false);
        assert_eq!(body["options"]["temperature"], 0);
        assert_eq!(body["options"]["num_predict"], 512);
        assert_eq!(body["keep_alive"], "10m");
        assert!(body["format"].is_object());
    }

    #[test]
    fn native_nanosecond_timings_are_reported_in_milliseconds() {
        assert_eq!(duration_ms(725_000_000), 725);
    }
}

/// At app launch: if we manage the install and no server is up, start it.
pub fn ensure_managed_server_on_launch(app: &AppHandle) {
    let settings = crate::settings::get_settings(app);
    if !settings.managed_ollama {
        return;
    }
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        if !server_running().await {
            if let Err(e) = spawn_managed_server(&app) {
                warn!("managed ollama launch failed: {e}");
            }
        }
    });
}

async fn download_binary(app: &AppHandle) -> Result<(), String> {
    let dir = ollama_dir(app)?;
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;

    let client = reqwest::Client::new();
    let resp = client
        .get(OLLAMA_DOWNLOAD_URL)
        .send()
        .await
        .map_err(|e| format!("download failed: {e}"))?
        .error_for_status()
        .map_err(|e| format!("download failed: {e}"))?;
    let total = resp.content_length().unwrap_or(0);

    let tgz_path = dir.join("ollama-darwin.tgz");
    let mut file = std::fs::File::create(&tgz_path).map_err(|e| e.to_string())?;
    let mut stream = resp.bytes_stream();
    let mut done: u64 = 0;
    let mut last_emit = std::time::Instant::now();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| format!("download failed: {e}"))?;
        std::io::Write::write_all(&mut file, &chunk).map_err(|e| e.to_string())?;
        done += chunk.len() as u64;
        if last_emit.elapsed().as_millis() > 100 {
            last_emit = std::time::Instant::now();
            let progress = if total > 0 {
                done as f32 / total as f32
            } else {
                -1.0
            };
            let _ = AiSetupProgress {
                stage: "binary".into(),
                progress,
            }
            .emit(app);
        }
    }
    drop(file);

    // Unpack (tar.gz containing the `ollama` binary) and mark executable.
    let tgz = std::fs::File::open(&tgz_path).map_err(|e| e.to_string())?;
    let mut archive = tar::Archive::new(flate2::read::GzDecoder::new(tgz));
    archive
        .unpack(&dir)
        .map_err(|e| format!("unpack failed: {e}"))?;
    let _ = std::fs::remove_file(&tgz_path);

    let bin = managed_binary(app)?;
    if !bin.exists() {
        return Err("archive did not contain the ollama binary".into());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755))
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}

async fn pull_model(app: &AppHandle) -> Result<(), String> {
    #[derive(Deserialize)]
    struct PullLine {
        #[serde(default)]
        status: String,
        #[serde(default)]
        total: Option<u64>,
        #[serde(default)]
        completed: Option<u64>,
        #[serde(default)]
        error: Option<String>,
    }

    let client = reqwest::Client::new();
    let resp = client
        .post(format!("{}/api/pull", OLLAMA_BASE))
        .json(&serde_json::json!({ "model": DEFAULT_MODEL }))
        .send()
        .await
        .map_err(|e| format!("model pull failed: {e}"))?
        .error_for_status()
        .map_err(|e| format!("model pull failed: {e}"))?;

    // Streaming NDJSON: one status object per line, possibly split across chunks.
    let mut stream = resp.bytes_stream();
    let mut buf = Vec::new();
    let mut last_emit = std::time::Instant::now();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| format!("model pull failed: {e}"))?;
        buf.extend_from_slice(&chunk);
        while let Some(nl) = buf.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = buf.drain(..=nl).collect();
            let Ok(parsed) = serde_json::from_slice::<PullLine>(&line) else {
                continue;
            };
            if let Some(err) = parsed.error {
                return Err(format!("model pull failed: {err}"));
            }
            if parsed.status == "success" {
                return Ok(());
            }
            if let (Some(total), Some(completed)) = (parsed.total, parsed.completed) {
                if total > 0 && last_emit.elapsed().as_millis() > 100 {
                    last_emit = std::time::Instant::now();
                    let _ = AiSetupProgress {
                        stage: "model".into(),
                        progress: completed as f32 / total as f32,
                    }
                    .emit(app);
                }
            }
        }
    }
    // Stream ended without an explicit success line; trust the tags check.
    if model_ready().await {
        Ok(())
    } else {
        Err("model pull ended unexpectedly".into())
    }
}

/// One-click setup: ensure a server is reachable (downloading and spawning the
/// managed binary if needed), then pull the default model. Emits
/// `AiSetupProgress` events throughout.
#[tauri::command]
#[specta::specta]
pub async fn setup_local_ai(app: AppHandle) -> Result<(), String> {
    if !cfg!(target_os = "macos") {
        return Err("managed AI setup is only supported on macOS".into());
    }

    if !server_running().await {
        if !managed_binary(&app)?.exists() {
            debug!("downloading ollama binary");
            download_binary(&app).await?;
        }
        let _ = AiSetupProgress {
            stage: "server".into(),
            progress: -1.0,
        }
        .emit(&app);
        spawn_managed_server(&app)?;
        // Wait for the server to come up.
        let mut up = false;
        for _ in 0..30 {
            tokio::time::sleep(std::time::Duration::from_millis(500)).await;
            if server_running().await {
                up = true;
                break;
            }
        }
        if !up {
            return Err("ollama server did not start".into());
        }
        // Remember that we own this install so app launch restarts it.
        let mut settings = crate::settings::get_settings(&app);
        settings.managed_ollama = true;
        crate::settings::write_settings(&app, settings);
    }

    if !model_ready().await {
        let _ = AiSetupProgress {
            stage: "model".into(),
            progress: 0.0,
        }
        .emit(&app);
        pull_model(&app).await?;
    }

    let _ = AiSetupProgress {
        stage: "done".into(),
        progress: 1.0,
    }
    .emit(&app);
    info!("local AI setup complete ({DEFAULT_MODEL})");
    Ok(())
}
