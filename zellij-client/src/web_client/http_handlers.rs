use crate::web_client::authentication::{IsReadOnly, SessionTokenHash};
use crate::web_client::types::{
    AppState, CreateClientIdResponse, ImageUploadListItem, ImageUploadListResponse,
    ImageUploadResponse, LoginRequest, LoginResponse, SessionActionResponse, SessionListItem,
    SessionListResponse, SessionStatus,
};
use crate::web_client::utils::{get_mime_type, parse_cookies};
use axum::{
    body::{to_bytes, Bytes},
    extract::{Path as AxumPath, Query, Request, State},
    http::{header, StatusCode},
    response::{Html, IntoResponse},
    Json,
};
use axum_extra::extract::cookie::{Cookie, SameSite};
use include_dir;
use serde::Deserialize;
use std::{
    io,
    path::{Path, PathBuf},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use uuid::Uuid;
use zellij_utils::{
    consts::{session_info_folder_for_session, VERSION, ZELLIJ_SOCK_DIR},
    ipc::async_send_kill_and_await,
    sessions::{get_resurrectable_sessions, get_sessions, session_exists, validate_session_name},
    web_authentication_tokens::create_session_token,
};

fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#x27;")
}

const WEB_CLIENT_PAGE: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/",
    "assets/index.html"
));

const ASSETS_DIR: include_dir::Dir<'_> = include_dir::include_dir!("$CARGO_MANIFEST_DIR/assets");
const MAX_IMAGE_UPLOAD_BYTES: usize = 20 * 1024 * 1024;
const MAX_FILE_UPLOAD_BYTES: usize = 100 * 1024 * 1024;
const MAX_FILE_DOWNLOAD_BYTES: u64 = 100 * 1024 * 1024;

#[derive(Deserialize)]
pub struct DownloadUploadQuery {
    path: String,
}

pub async fn serve_html(State(state): State<AppState>, request: Request) -> Html<String> {
    let cookies = parse_cookies(&request);
    let is_authenticated = cookies.get("session_token").is_some();
    let auth_value = if is_authenticated { "true" } else { "false" };
    let base_url = html_escape(
        &state
            .config
            .lock()
            .unwrap()
            .web_client
            .base_url
            .clone()
            .unwrap_or("/".to_string()),
    );

    let html = Html(
        WEB_CLIENT_PAGE
            .replace("IS_AUTHENTICATED", &format!("{}", auth_value))
            .replace("BASE_URL", &base_url),
    );
    html
}

pub async fn login_handler(
    State(state): State<AppState>,
    Json(login_request): Json<LoginRequest>,
) -> impl IntoResponse {
    match create_session_token(
        &login_request.auth_token,
        login_request.remember_me.unwrap_or(false),
    ) {
        Ok(session_token) => {
            let is_https = state.is_https;
            let cookie = if login_request.remember_me.unwrap_or(false) {
                // Persistent cookie for remember_me
                Cookie::build(("session_token", session_token))
                    .http_only(true)
                    .secure(is_https)
                    .same_site(SameSite::Strict)
                    .path("/")
                    .max_age(time::Duration::weeks(4))
                    .build()
            } else {
                // Session cookie - NO max_age means it expires when browser closes/refreshes
                Cookie::build(("session_token", session_token))
                    .http_only(true)
                    .secure(is_https)
                    .same_site(SameSite::Strict)
                    .path("/")
                    .build()
            };

            let mut response = Json(LoginResponse {
                success: true,
                message: "Login successful".to_string(),
            })
            .into_response();

            if let Ok(cookie_header) = axum::http::HeaderValue::from_str(&cookie.to_string()) {
                response.headers_mut().insert("set-cookie", cookie_header);
            }

            response
        },
        Err(_) => (
            StatusCode::UNAUTHORIZED,
            Json(LoginResponse {
                success: false,
                message: "Invalid authentication token".to_string(),
            }),
        )
            .into_response(),
    }
}

pub async fn create_new_client(
    State(state): State<AppState>,
    request: axum::extract::Request,
) -> Result<Json<CreateClientIdResponse>, (StatusCode, impl IntoResponse)> {
    // Extract is_read_only from request extensions (set by auth middleware)
    let is_read_only = request
        .extensions()
        .get::<IsReadOnly>()
        .copied()
        .unwrap_or(IsReadOnly(true))
        .0;
    let session_token_hash = request
        .extensions()
        .get::<SessionTokenHash>()
        .cloned()
        .ok_or((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json("Missing session info".to_string()),
        ))?;

    let web_client_id = String::from(Uuid::new_v4());
    let os_input = state
        .client_os_api_factory
        .create_client_os_api()
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, Json(e.to_string())))?;

    state.connection_table.lock().unwrap().add_new_client(
        web_client_id.to_owned(),
        os_input,
        is_read_only,
        session_token_hash.0,
    );

    Ok(Json(CreateClientIdResponse {
        web_client_id,
        is_read_only,
    }))
}

pub async fn list_sessions_handler() -> Result<Json<SessionListResponse>, (StatusCode, Json<String>)>
{
    match get_sessions() {
        Ok(sessions) => {
            let mut session_items: Vec<SessionListItem> = sessions
                .into_iter()
                .map(|(name, _)| SessionListItem {
                    name,
                    status: SessionStatus::Live,
                })
                .collect();
            for (name, _) in get_resurrectable_sessions() {
                if !session_items.iter().any(|session| session.name == name) {
                    session_items.push(SessionListItem {
                        name,
                        status: SessionStatus::Resurrectable,
                    });
                }
            }
            session_items.sort_by(|left, right| left.name.cmp(&right.name));
            Ok(Json(SessionListResponse {
                sessions: session_items,
            }))
        },
        Err(_) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json("Failed to list sessions".to_string()),
        )),
    }
}

#[derive(Deserialize)]
pub struct ConfirmSessionActionQuery {
    confirm: Option<bool>,
}

pub async fn restart_session_handler(
    AxumPath(session_name): AxumPath<String>,
    Query(query): Query<ConfirmSessionActionQuery>,
    request: Request,
) -> Result<Json<SessionActionResponse>, (StatusCode, Json<String>)> {
    require_write_token(&request, "restart sessions")?;
    require_confirm(query.confirm, "restart")?;
    validate_web_session_name(&session_name)?;

    let is_live = session_exists(&session_name).map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(format!("Failed to check session: {:?}", e)),
        )
    })?;
    if !is_live {
        if is_resurrectable_session(&session_name) {
            return Err((
                StatusCode::CONFLICT,
                Json("Session is not live; attach it to resurrect instead".to_string()),
            ));
        }
        return Err((
            StatusCode::NOT_FOUND,
            Json(format!("Session {:?} not found", session_name)),
        ));
    }

    let signal_sent = send_kill_session(&session_name).await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(format!("Failed to restart session: {}", e)),
        )
    })?;
    if !signal_sent {
        return Err((
            StatusCode::NOT_FOUND,
            Json(format!("Session {:?} not found", session_name)),
        ));
    }

    Ok(Json(SessionActionResponse {
        session: session_name,
        action: "restart".to_string(),
        live_session_signal_sent: signal_sent,
        resurrection_data_removed: false,
        message: "Restart requested. Reconnect to resurrect the session.".to_string(),
    }))
}

pub async fn delete_session_handler(
    AxumPath(session_name): AxumPath<String>,
    Query(query): Query<ConfirmSessionActionQuery>,
    request: Request,
) -> Result<Json<SessionActionResponse>, (StatusCode, Json<String>)> {
    require_write_token(&request, "delete sessions")?;
    require_confirm(query.confirm, "delete")?;
    validate_web_session_name(&session_name)?;

    let is_live = session_exists(&session_name).map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(format!("Failed to check session: {:?}", e)),
        )
    })?;
    let is_resurrectable = is_resurrectable_session(&session_name);
    if !is_live && !is_resurrectable {
        return Err((
            StatusCode::NOT_FOUND,
            Json(format!("Session {:?} not found", session_name)),
        ));
    }

    let removed_before_kill = remove_resurrection_cache(&session_name)
        .await
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(format!("Failed to delete session data: {}", e)),
            )
        })?;
    let signal_sent = if is_live {
        send_kill_session(&session_name).await.map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(format!("Failed to kill session: {}", e)),
            )
        })?
    } else {
        false
    };
    if signal_sent {
        tokio::time::sleep(Duration::from_millis(150)).await;
    }
    let removed_after_kill = remove_resurrection_cache(&session_name)
        .await
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(format!("Failed to delete session data: {}", e)),
            )
        })?;

    Ok(Json(SessionActionResponse {
        session: session_name,
        action: "delete".to_string(),
        live_session_signal_sent: signal_sent,
        resurrection_data_removed: removed_before_kill || removed_after_kill,
        message: "Session delete requested. Resurrection data was removed.".to_string(),
    }))
}

fn require_write_token(request: &Request, action: &str) -> Result<(), (StatusCode, Json<String>)> {
    let is_read_only = request
        .extensions()
        .get::<IsReadOnly>()
        .copied()
        .unwrap_or(IsReadOnly(true))
        .0;
    if is_read_only {
        return Err((
            StatusCode::FORBIDDEN,
            Json(format!("Read-only tokens cannot {}", action)),
        ));
    }
    Ok(())
}

fn require_confirm(confirm: Option<bool>, action: &str) -> Result<(), (StatusCode, Json<String>)> {
    if confirm == Some(true) {
        return Ok(());
    }
    Err((
        StatusCode::BAD_REQUEST,
        Json(format!(
            "Add ?confirm=true to confirm the session {} action",
            action
        )),
    ))
}

fn validate_web_session_name(session_name: &str) -> Result<(), (StatusCode, Json<String>)> {
    validate_session_name(session_name).map_err(|e| (StatusCode::BAD_REQUEST, Json(e)))
}

fn is_resurrectable_session(session_name: &str) -> bool {
    get_resurrectable_sessions()
        .iter()
        .any(|(name, _)| name == session_name)
}

async fn remove_resurrection_cache(session_name: &str) -> io::Result<bool> {
    match tokio::fs::remove_dir_all(session_info_folder_for_session(session_name)).await {
        Ok(()) => Ok(true),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(e),
    }
}

async fn send_kill_session(session_name: &str) -> Result<bool, String> {
    let path = &*ZELLIJ_SOCK_DIR.join(session_name);
    match tokio::time::timeout(Duration::from_secs(2), async_send_kill_and_await(path)).await {
        Ok(Ok(())) => Ok(true),
        Ok(Err(e)) if e.kind() == io::ErrorKind::NotFound => Ok(false),
        Ok(Err(e)) if e.kind() == io::ErrorKind::ConnectionRefused => Ok(false),
        Ok(Err(e)) => Err(e.to_string()),
        Err(_) => Err("session did not acknowledge kill request within 2s".to_string()),
    }
}

pub async fn upload_image_handler(
    request: axum::extract::Request,
) -> Result<Json<ImageUploadResponse>, (StatusCode, Json<String>)> {
    upload_file_request(request, true).await
}

pub async fn upload_file_handler(
    request: axum::extract::Request,
) -> Result<Json<ImageUploadResponse>, (StatusCode, Json<String>)> {
    upload_file_request(request, false).await
}

async fn upload_file_request(
    request: axum::extract::Request,
    require_image: bool,
) -> Result<Json<ImageUploadResponse>, (StatusCode, Json<String>)> {
    let is_read_only = request
        .extensions()
        .get::<IsReadOnly>()
        .copied()
        .unwrap_or(IsReadOnly(true))
        .0;
    if is_read_only {
        return Err((
            StatusCode::FORBIDDEN,
            Json("Read-only tokens cannot upload files".to_string()),
        ));
    }

    let content_type = request
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .unwrap_or("application/octet-stream")
        .to_string();
    if require_image && !content_type.starts_with("image/") {
        return Err((
            StatusCode::UNSUPPORTED_MEDIA_TYPE,
            Json("Only image uploads are supported".to_string()),
        ));
    }

    let original_filename = request
        .headers()
        .get("x-zellij-filename")
        .and_then(|value| value.to_str().ok())
        .unwrap_or(if require_image { "image" } else { "file" })
        .to_string();
    let max_bytes = if require_image {
        MAX_IMAGE_UPLOAD_BYTES
    } else {
        MAX_FILE_UPLOAD_BYTES
    };
    let body = to_bytes(request.into_body(), max_bytes)
        .await
        .map_err(|_| {
            (
                StatusCode::PAYLOAD_TOO_LARGE,
                Json("File upload is too large".to_string()),
            )
        })?;
    if body.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json("File upload is empty".to_string()),
        ));
    }

    let upload_dir = image_upload_dir();
    tokio::fs::create_dir_all(&upload_dir).await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(format!("Failed to create upload directory: {}", e)),
        )
    })?;
    prune_old_uploads(&upload_dir).await;

    let filename = upload_filename(&original_filename, &content_type);
    let path = upload_dir.join(filename);
    write_upload_atomically(&path, &body).await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(format!("Failed to save file upload: {}", e)),
        )
    })?;

    Ok(Json(ImageUploadResponse {
        path: path.to_string_lossy().to_string(),
        bytes: body.len(),
    }))
}

pub async fn download_uploaded_image_handler(
    Query(query): Query<DownloadUploadQuery>,
) -> Result<impl IntoResponse, (StatusCode, Json<String>)> {
    download_uploaded_file_response(query).await
}

pub async fn download_uploaded_file_handler(
    Query(query): Query<DownloadUploadQuery>,
) -> Result<impl IntoResponse, (StatusCode, Json<String>)> {
    download_uploaded_file_response(query).await
}

async fn download_uploaded_file_response(
    query: DownloadUploadQuery,
) -> Result<impl IntoResponse, (StatusCode, Json<String>)> {
    let upload_dir = canonical_upload_dir().await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(format!("Failed to open upload directory: {}", e)),
        )
    })?;
    let requested_path = PathBuf::from(query.path);
    let canonical_path = tokio::fs::canonicalize(&requested_path)
        .await
        .map_err(|_| {
            (
                StatusCode::NOT_FOUND,
                Json("Uploaded file not found".to_string()),
            )
        })?;
    if !canonical_path.starts_with(&upload_dir) {
        return Err((
            StatusCode::FORBIDDEN,
            Json("Can only download files from the Zellij upload directory".to_string()),
        ));
    }

    let metadata = tokio::fs::metadata(&canonical_path).await.map_err(|_| {
        (
            StatusCode::NOT_FOUND,
            Json("Uploaded file not found".to_string()),
        )
    })?;
    if !metadata.is_file() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json("Requested path is not a file".to_string()),
        ));
    }
    if metadata.len() > MAX_FILE_DOWNLOAD_BYTES {
        return Err((
            StatusCode::PAYLOAD_TOO_LARGE,
            Json("Uploaded file is too large".to_string()),
        ));
    }

    let extension = canonical_path
        .extension()
        .and_then(|extension| extension.to_str());
    let extension = extension.map(|extension| extension.to_ascii_lowercase());
    let mime_type = get_mime_type(extension.as_deref());

    let body = tokio::fs::read(&canonical_path).await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(format!("Failed to read uploaded file: {}", e)),
        )
    })?;
    Ok(([(header::CONTENT_TYPE, mime_type)], body))
}

pub async fn delete_uploaded_file_handler(
    Query(query): Query<DownloadUploadQuery>,
) -> Result<StatusCode, (StatusCode, Json<String>)> {
    let upload_dir = canonical_upload_dir().await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(format!("Failed to open upload directory: {}", e)),
        )
    })?;
    let requested_path = PathBuf::from(query.path);
    let canonical_path = tokio::fs::canonicalize(&requested_path)
        .await
        .map_err(|_| {
            (
                StatusCode::NOT_FOUND,
                Json("Uploaded file not found".to_string()),
            )
        })?;
    if !canonical_path.starts_with(&upload_dir) {
        return Err((
            StatusCode::FORBIDDEN,
            Json("Can only delete files from the Zellij upload directory".to_string()),
        ));
    }

    let metadata = tokio::fs::metadata(&canonical_path).await.map_err(|_| {
        (
            StatusCode::NOT_FOUND,
            Json("Uploaded file not found".to_string()),
        )
    })?;
    if !metadata.is_file() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json("Requested path is not a file".to_string()),
        ));
    }

    tokio::fs::remove_file(&canonical_path).await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(format!("Failed to delete uploaded file: {}", e)),
        )
    })?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn list_uploaded_images_handler(
) -> Result<Json<ImageUploadListResponse>, (StatusCode, Json<String>)> {
    let upload_dir = canonical_upload_dir().await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(format!("Failed to open upload directory: {}", e)),
        )
    })?;
    let mut entries = tokio::fs::read_dir(&upload_dir).await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(format!("Failed to list upload directory: {}", e)),
        )
    })?;
    let mut files = vec![];
    while let Ok(Some(entry)) = entries.next_entry().await {
        let path = entry.path();
        let Ok(metadata) = entry.metadata().await else {
            continue;
        };
        if !metadata.is_file() || metadata.len() > MAX_FILE_DOWNLOAD_BYTES {
            continue;
        }
        let extension = path
            .extension()
            .and_then(|extension| extension.to_str())
            .map(|extension| extension.to_ascii_lowercase());
        let mime_type = get_mime_type(extension.as_deref());
        let modified_ms = metadata
            .modified()
            .ok()
            .and_then(|modified| modified.duration_since(UNIX_EPOCH).ok())
            .map(|duration| duration.as_millis())
            .unwrap_or(0);
        files.push(ImageUploadListItem {
            path: path.to_string_lossy().to_string(),
            filename: entry.file_name().to_string_lossy().to_string(),
            bytes: metadata.len(),
            modified_ms,
            content_type: mime_type.to_owned(),
        });
    }
    files.sort_by(|left, right| right.modified_ms.cmp(&left.modified_ms));
    Ok(Json(ImageUploadListResponse { files }))
}

fn image_upload_dir() -> PathBuf {
    if let Ok(path) = std::env::var("ZELLIJ_UPLOAD_DIR") {
        return PathBuf::from(path);
    }
    if let Ok(path) = std::env::var("XDG_CACHE_HOME") {
        return PathBuf::from(path).join("zellij").join("uploads");
    }
    if let Ok(home) = std::env::var("HOME") {
        return PathBuf::from(home)
            .join(".cache")
            .join("zellij")
            .join("uploads");
    }
    std::env::temp_dir().join("zellij").join("uploads")
}

async fn canonical_upload_dir() -> std::io::Result<PathBuf> {
    let upload_dir = image_upload_dir();
    tokio::fs::create_dir_all(&upload_dir).await?;
    tokio::fs::canonicalize(upload_dir).await
}

fn upload_filename(original_filename: &str, content_type: &str) -> String {
    let extension = Path::new(original_filename)
        .extension()
        .and_then(|extension| extension.to_str())
        .map(sanitize_extension)
        .filter(|extension| !extension.is_empty())
        .unwrap_or_else(|| extension_for_content_type(content_type).to_string());
    let created_at_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis())
        .unwrap_or(0);
    format!(
        "zellij-upload-{}-{}.{}",
        created_at_ms,
        Uuid::new_v4().simple(),
        extension
    )
}

fn sanitize_extension(extension: &str) -> String {
    extension
        .chars()
        .filter(|character| character.is_ascii_alphanumeric())
        .take(8)
        .collect::<String>()
        .to_ascii_lowercase()
}

fn extension_for_content_type(content_type: &str) -> &'static str {
    let content_type = content_type
        .split(';')
        .next()
        .unwrap_or(content_type)
        .trim();
    match content_type {
        "image/jpeg" => "jpg",
        "image/png" => "png",
        "image/gif" => "gif",
        "image/heic" | "image/heif" => "heic",
        "image/webp" => "webp",
        "text/plain" => "txt",
        "application/json" => "json",
        "application/pdf" => "pdf",
        "application/zip" => "zip",
        "application/gzip" => "gz",
        _ if content_type.starts_with("image/") => "png",
        _ => "bin",
    }
}

async fn write_upload_atomically(path: &Path, body: &Bytes) -> std::io::Result<()> {
    let tmp_path = path.with_extension("uploading");
    tokio::fs::write(&tmp_path, body).await?;
    tokio::fs::rename(tmp_path, path).await
}

async fn prune_old_uploads(upload_dir: &Path) {
    const UPLOAD_RETENTION: Duration = Duration::from_secs(7 * 24 * 60 * 60);

    let Ok(mut entries) = tokio::fs::read_dir(upload_dir).await else {
        return;
    };
    let Ok(now) = SystemTime::now().duration_since(UNIX_EPOCH) else {
        return;
    };
    while let Ok(Some(entry)) = entries.next_entry().await {
        let filename = entry.file_name();
        let filename = filename.to_string_lossy();
        if !filename.starts_with("zellij-upload-") {
            continue;
        }
        let Ok(metadata) = entry.metadata().await else {
            continue;
        };
        if !metadata.is_file() {
            continue;
        }
        let Ok(modified) = metadata.modified() else {
            continue;
        };
        let Ok(modified) = modified.duration_since(UNIX_EPOCH) else {
            continue;
        };
        if now.saturating_sub(modified) > UPLOAD_RETENTION {
            let _ = tokio::fs::remove_file(entry.path()).await;
        }
    }
}

pub async fn get_static_asset(AxumPath(path): AxumPath<String>) -> impl IntoResponse {
    let path = path.trim_start_matches('/');

    match ASSETS_DIR.get_file(path) {
        None => (
            [(header::CONTENT_TYPE, "text/html")],
            "Not Found".as_bytes(),
        ),
        Some(file) => {
            let ext = file.path().extension().and_then(|ext| ext.to_str());
            let mime_type = get_mime_type(ext);
            ([(header::CONTENT_TYPE, mime_type)], file.contents())
        },
    }
}

pub async fn version_handler() -> &'static str {
    VERSION
}
