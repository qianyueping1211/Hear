use crate::state::{LocalServerInstallStatus, UpdateConfig};
use crate::updater::{clean_repo, parse_semver, CURRENT_VERSION};
use futures_util::StreamExt;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::Write;
use std::path::{Component, Path, PathBuf};
use std::time::Duration;
use tauri::{AppHandle, Manager};

const META_FILENAME: &str = ".hear-server-meta.json";

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct InstalledMeta {
    version: String,
    tag_name: String,
    asset_name: String,
}

#[derive(Debug, Deserialize)]
struct GhRelease {
    tag_name: String,
    draft: Option<bool>,
    assets: Option<Vec<GhAsset>>,
}

#[derive(Debug, Deserialize)]
struct GhAsset {
    name: String,
    url: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalServerProgress {
    pub action: String,
    pub stage: String,
    pub downloaded: u64,
    pub total: u64,
    pub message: String,
}

/// 本机模型服务安装目录：Windows 默认 %LOCALAPPDATA%\Hear\Server，免管理员权限
pub fn default_install_dir(app: &AppHandle) -> PathBuf {
    #[cfg(target_os = "windows")]
    {
        if let Some(local_app_data) = std::env::var_os("LOCALAPPDATA") {
            return PathBuf::from(local_app_data).join("Hear").join("Server");
        }
    }
    app.path()
        .app_local_data_dir()
        .unwrap_or_else(|_| std::env::temp_dir().join("Hear"))
        .join("Server")
}

/// 检查指定目录中本机模型服务的安装状态（纯只读检查，绝不启动任何进程）
pub fn inspect_install_dir(dir: &Path) -> LocalServerInstallStatus {
    let launcher = dir.join("start-hear-cloud.bat");
    let server_script = dir.join("server").join("hear_cloud.py");
    let runtime_py = dir.join("server").join("runtime").join("python.exe");
    let models_dir = dir.join("server").join("models");

    let installed = launcher.is_file() && server_script.is_file();
    let has_bundled_runtime = runtime_py.is_file();
    let has_models = fs::read_dir(&models_dir)
        .map(|mut rd| rd.next().is_some())
        .unwrap_or(false);

    let meta_version = fs::read_to_string(dir.join(META_FILENAME))
        .ok()
        .and_then(|raw| serde_json::from_str::<InstalledMeta>(&raw).ok())
        .map(|m| m.version);

    LocalServerInstallStatus {
        installed,
        install_dir: dir.to_string_lossy().to_string(),
        installed_version: if installed { meta_version } else { None },
        has_bundled_runtime,
        has_models,
        launcher_path: if installed {
            Some(launcher.to_string_lossy().to_string())
        } else {
            None
        },
    }
}

fn build_http_client() -> Result<Client, String> {
    Client::builder()
        .connect_timeout(Duration::from_secs(10))
        .user_agent(format!("Hear-Desktop/{}", CURRENT_VERSION))
        .build()
        .map_err(|e| format!("创建网络客户端失败：{}", e))
}

async fn find_latest_server_asset(
    client: &Client,
    cfg: &UpdateConfig,
) -> Result<(String, String, String, String), String> {
    let repo = clean_repo(&cfg.repo);
    let api_url = format!("https://api.github.com/repos/{}/releases?per_page=30", repo);
    let mut req = client
        .get(&api_url)
        .header("Accept", "application/vnd.github+json")
        .header("X-GitHub-Api-Version", "2022-11-28")
        .timeout(Duration::from_secs(15));

    let token = cfg.github_token.trim();
    if !token.is_empty() {
        req = req.header("Authorization", format!("Bearer {}", token));
    }

    let resp = req
        .send()
        .await
        .map_err(|e| format!("无法连接 GitHub 获取服务端安装包：{}", e))?;

    if !resp.status().is_success() {
        let code = resp.status().as_u16();
        let hint = match code {
            401 => "GitHub Token 无效或已过期（HTTP 401），请在「系统与更新」中检查".to_string(),
            403 => "GitHub API 访问受限（HTTP 403），建议在「系统与更新」中配置 GitHub Token".to_string(),
            404 => "未找到仓库或无权访问私有仓库（HTTP 404），请先在「系统与更新」配置 GitHub Token".to_string(),
            _ => format!("查询 GitHub Release 失败（HTTP {}）", code),
        };
        return Err(hint);
    }

    let releases: Vec<GhRelease> = resp
        .json()
        .await
        .map_err(|e| format!("解析 Release 列表失败：{}", e))?;

    let found = releases
        .into_iter()
        .filter(|r| !r.draft.unwrap_or(false) && r.tag_name.starts_with("win-v"))
        .filter_map(|r| {
            let ver = parse_semver(&r.tag_name)?;
            let asset = r.assets.unwrap_or_default().into_iter().find(|a| {
                let lower = a.name.to_lowercase();
                lower.starts_with("hear-server-win-") && lower.ends_with(".zip")
            })?;
            Some((ver, r.tag_name, asset.name, asset.url))
        })
        .max_by_key(|(v, _, _, _)| *v);

    let Some((ver, tag_name, asset_name, asset_url)) = found else {
        return Err("仓库发布页中尚未找到 Hear-Server-Win-*.zip 服务端整合包".to_string());
    };
    let ver_str = format!("{}.{}.{}", ver.0, ver.1, ver.2);
    Ok((ver_str, tag_name, asset_name, asset_url))
}

fn strip_single_top_dir(rel: &Path) -> Option<PathBuf> {
    let mut comps = rel.components();
    let first = comps.next()?;
    if !matches!(first, Component::Normal(_)) {
        return None;
    }
    let rest: PathBuf = comps.collect();
    if rest.as_os_str().is_empty() {
        None
    } else {
        Some(rest)
    }
}

fn should_preserve_on_reinstall(rel: &Path) -> bool {
    let norm = rel.to_string_lossy().replace('\\', "/").to_lowercase();
    norm.starts_with("server/models/")
        || norm == "server/models"
        || norm.starts_with("server/certs/")
        || norm == "server/certs"
        || norm == "server/hear_models.json"
}

fn map_fs_lock_err(action: &str, err: std::io::Error) -> String {
    let code = err.raw_os_error().unwrap_or(0);
    if code == 5 || code == 32 || err.kind() == std::io::ErrorKind::PermissionDenied {
        format!(
            "{}失败：检测到服务端文件被占用（可能本机模型服务正在运行），请先关闭服务端窗口后再试",
            action
        )
    } else {
        format!("{}失败：{}", action, err)
    }
}

/// 将服务端 zip 解压到目标目录（重装时自动保留已下载的 models/ 与 certs/，避免重复下载数 GB 模型）
pub fn extract_server_zip(zip_path: &Path, install_dir: &Path, preserve_user_data: bool) -> Result<(), String> {
    fs::create_dir_all(install_dir).map_err(|e| map_fs_lock_err("创建安装目录", e))?;

    // 清理旧的内置 Python 运行时目录，避免残留旧版本二进制与依赖
    let runtime_dir = install_dir.join("server").join("runtime");
    if runtime_dir.exists() {
        fs::remove_dir_all(&runtime_dir).map_err(|e| map_fs_lock_err("清理旧运行时", e))?;
    }

    let file = fs::File::open(zip_path).map_err(|e| format!("打开安装包失败：{}", e))?;
    let mut archive = zip::ZipArchive::new(file).map_err(|e| format!("安装包压缩格式损坏：{}", e))?;

    // 检查是否所有条目都包在同一个顶层文件夹内（如 Hear-Server-Win-0.1.5/）
    let mut common_top: Option<String> = None;
    let mut has_single_top = archive.len() > 0;
    for i in 0..archive.len() {
        let entry = archive
            .by_index(i)
            .map_err(|e| format!("读取安装包目录失败：{}", e))?;
        let Some(enclosed) = entry.enclosed_name() else {
            return Err("安装包包含非法路径".to_string());
        };
        let first = enclosed.components().next().and_then(|c| match c {
            Component::Normal(s) => Some(s.to_string_lossy().to_string()),
            _ => None,
        });
        match (&common_top, first) {
            (None, Some(name)) => common_top = Some(name),
            (Some(prev), Some(name)) if *prev == name => {}
            _ => {
                has_single_top = false;
                break;
            }
        }
    }

    for i in 0..archive.len() {
        let mut entry = archive
            .by_index(i)
            .map_err(|e| format!("读取压缩条目失败：{}", e))?;
        let Some(enclosed) = entry.enclosed_name() else {
            return Err("安装包包含非法路径".to_string());
        };
        let rel = if has_single_top {
            match strip_single_top_dir(&enclosed) {
                Some(r) => r,
                None => continue,
            }
        } else {
            enclosed.to_path_buf()
        };

        let dest = install_dir.join(&rel);
        if preserve_user_data && should_preserve_on_reinstall(&rel) && dest.exists() {
            continue;
        }

        if entry.is_dir() {
            fs::create_dir_all(&dest).map_err(|e| map_fs_lock_err("创建目录", e))?;
        } else {
            if let Some(parent) = dest.parent() {
                fs::create_dir_all(parent).map_err(|e| map_fs_lock_err("创建目录", e))?;
            }
            let mut out = fs::File::create(&dest).map_err(|e| map_fs_lock_err("写入文件", e))?;
            std::io::copy(&mut entry, &mut out).map_err(|e| map_fs_lock_err("解压文件", e))?;
        }
    }

    Ok(())
}

/// 下载并安装（或重装）本机模型服务端整合包
pub async fn install_or_reinstall<F>(
    install_dir: &Path,
    update_cfg: &UpdateConfig,
    is_reinstall: bool,
    mut on_progress: F,
) -> Result<LocalServerInstallStatus, String>
where
    F: FnMut(LocalServerProgress),
{
    let action = if is_reinstall { "reinstall" } else { "install" };
    on_progress(LocalServerProgress {
        action: action.to_string(),
        stage: "checking".to_string(),
        downloaded: 0,
        total: 0,
        message: "正在查询最新 Windows 服务端整合包…".to_string(),
    });

    let client = build_http_client()?;
    let (ver_str, tag_name, asset_name, asset_url) =
        find_latest_server_asset(&client, update_cfg).await?;

    on_progress(LocalServerProgress {
        action: action.to_string(),
        stage: "downloading".to_string(),
        downloaded: 0,
        total: 0,
        message: format!("正在下载 {}（v{}）…", asset_name, ver_str),
    });

    let mut req = client
        .get(&asset_url)
        .header("Accept", "application/octet-stream")
        .timeout(Duration::from_secs(900));
    let token = update_cfg.github_token.trim();
    if !token.is_empty() {
        req = req.header("Authorization", format!("Bearer {}", token));
    }

    let resp = req
        .send()
        .await
        .map_err(|e| format!("下载服务端整合包失败：{}", e))?;
    if !resp.status().is_success() {
        return Err(format!("下载服务端整合包返回 HTTP {}", resp.status().as_u16()));
    }

    let total = resp.content_length().unwrap_or(0);
    let tmp_dir = std::env::temp_dir().join("Hear-Server-Install");
    fs::create_dir_all(&tmp_dir).map_err(|e| format!("创建临时目录失败：{}", e))?;
    let zip_tmp = tmp_dir.join(format!("{}.part", asset_name));

    let mut file = fs::File::create(&zip_tmp).map_err(|e| format!("创建临时下载文件失败：{}", e))?;
    let mut stream = resp.bytes_stream();
    let mut downloaded: u64 = 0;
    let mut header = Vec::new();
    let mut last_emit = std::time::Instant::now();

    while let Some(chunk_res) = stream.next().await {
        let chunk = chunk_res.map_err(|e| format!("下载中断：{}", e))?;
        if header.len() < 4 {
            header.extend_from_slice(&chunk[..chunk.len().min(4 - header.len())]);
        }
        file.write_all(&chunk)
            .map_err(|e| format!("写入下载缓存失败：{}", e))?;
        downloaded += chunk.len() as u64;
        if last_emit.elapsed().as_millis() >= 150 || (total > 0 && downloaded >= total) {
            last_emit = std::time::Instant::now();
            on_progress(LocalServerProgress {
                action: action.to_string(),
                stage: "downloading".to_string(),
                downloaded,
                total,
                message: format!("正在下载 {}…", asset_name),
            });
        }
    }
    file.flush().map_err(|e| format!("写入刷新失败：{}", e))?;
    drop(file);

    if header.len() < 4 || &header[..4] != b"PK\x03\x04" {
        let _ = fs::remove_file(&zip_tmp);
        return Err("下载的文件不是有效的 ZIP 服务端整合包".to_string());
    }

    on_progress(LocalServerProgress {
        action: action.to_string(),
        stage: "extracting".to_string(),
        downloaded,
        total,
        message: "正在解压内置 Python 运行时与 faster-whisper / sherpa-onnx 依赖…".to_string(),
    });

    let zip_clone = zip_tmp.clone();
    let dir_clone = install_dir.to_path_buf();
    let extract_res = tokio::task::spawn_blocking(move || {
        extract_server_zip(&zip_clone, &dir_clone, is_reinstall)
    })
    .await
    .map_err(|e| format!("解压任务异常：{}", e))?;

    let _ = fs::remove_file(&zip_tmp);
    extract_res?;

    let meta = InstalledMeta {
        version: ver_str.clone(),
        tag_name,
        asset_name,
    };
    if let Ok(json) = serde_json::to_string_pretty(&meta) {
        let _ = fs::write(install_dir.join(META_FILENAME), json);
    }

    let status = inspect_install_dir(install_dir);
    on_progress(LocalServerProgress {
        action: action.to_string(),
        stage: "done".to_string(),
        downloaded,
        total,
        message: format!("本机模型服务 v{} 已安装就绪", ver_str),
    });
    Ok(status)
}

/// 卸载本机模型服务（可选是否一并删除已下载的数 GB 模型权重）
pub fn uninstall(install_dir: &Path, remove_models: bool) -> Result<LocalServerInstallStatus, String> {
    if !install_dir.exists() {
        return Ok(inspect_install_dir(install_dir));
    }

    if remove_models {
        fs::remove_dir_all(install_dir).map_err(|e| map_fs_lock_err("卸载本机模型服务", e))?;
        return Ok(inspect_install_dir(install_dir));
    }

    // 保留 server/models 目录，删除运行时、脚本与启动器
    for name in [
        "start-hear-cloud.bat",
        "start-hear-token-admin.bat",
        "使用说明.md",
        META_FILENAME,
    ] {
        let p = install_dir.join(name);
        if p.exists() {
            fs::remove_file(&p).map_err(|e| map_fs_lock_err("卸载服务端文件", e))?;
        }
    }

    let server_sub = install_dir.join("server");
    if server_sub.exists() {
        for entry in fs::read_dir(&server_sub).map_err(|e| map_fs_lock_err("扫描服务端目录", e))? {
            let entry = entry.map_err(|e| map_fs_lock_err("读取目录项", e))?;
            let fname = entry.file_name().to_string_lossy().to_lowercase();
            if fname == "models" {
                continue;
            }
            let p = entry.path();
            if p.is_dir() {
                fs::remove_dir_all(&p).map_err(|e| map_fs_lock_err("卸载服务端目录", e))?;
            } else {
                fs::remove_file(&p).map_err(|e| map_fs_lock_err("卸载服务端文件", e))?;
            }
        }
    }

    // 如果没有留下任何模型文件，连空目录一并清理干净
    let has_models = fs::read_dir(install_dir.join("server").join("models"))
        .map(|mut rd| rd.next().is_some())
        .unwrap_or(false);
    if !has_models {
        let _ = fs::remove_dir_all(install_dir);
    }

    Ok(inspect_install_dir(install_dir))
}

/// 在文件资源管理器中打开本机模型服务安装目录
pub fn open_install_dir(install_dir: &Path) -> Result<(), String> {
    let target = if install_dir.exists() {
        install_dir.to_path_buf()
    } else if let Some(parent) = install_dir.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("创建目录失败：{}", e))?;
        parent.to_path_buf()
    } else {
        return Err("未找到有效目录".to_string());
    };

    #[cfg(target_os = "windows")]
    {
        std::process::Command::new("explorer.exe")
            .arg(&target)
            .spawn()
            .map_err(|e| format!("打开资源管理器失败：{}", e))?;
    }
    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("open")
            .arg(&target)
            .spawn()
            .map_err(|e| format!("打开访达失败：{}", e))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use zip::write::SimpleFileOptions;

    #[test]
    fn extract_reinstall_preserves_models_and_uninstall_works() {
        let base = std::env::temp_dir().join(format!("hear-srv-test-{}", uuid::Uuid::new_v4()));
        let zip_path = base.join("Hear-Server-Win-0.1.5.zip");
        let install_dir = base.join("install");
        fs::create_dir_all(&base).unwrap();

        {
            let f = fs::File::create(&zip_path).unwrap();
            let mut zw = zip::ZipWriter::new(f);
            let opts = SimpleFileOptions::default();
            zw.start_file("Hear-Server-Win-0.1.5/start-hear-cloud.bat", opts)
                .unwrap();
            zw.write_all(b"@echo off").unwrap();
            zw.start_file("Hear-Server-Win-0.1.5/server/hear_cloud.py", opts)
                .unwrap();
            zw.write_all(b"print('ok')").unwrap();
            zw.start_file("Hear-Server-Win-0.1.5/server/runtime/python.exe", opts)
                .unwrap();
            zw.write_all(b"MZ").unwrap();
            zw.finish().unwrap();
        }

        // 初次安装
        extract_server_zip(&zip_path, &install_dir, false).unwrap();
        let st = inspect_install_dir(&install_dir);
        assert!(st.installed);
        assert!(st.has_bundled_runtime);
        assert!(!st.has_models);

        // 模拟已下载的模型文件
        let model_file = install_dir.join("server").join("models").join("demo.gguf");
        fs::create_dir_all(model_file.parent().unwrap()).unwrap();
        fs::write(&model_file, b"weights").unwrap();

        // 重装应保留模型文件
        extract_server_zip(&zip_path, &install_dir, true).unwrap();
        assert!(model_file.is_file());
        assert!(inspect_install_dir(&install_dir).has_models);

        // 保留模型的卸载
        let after_keep = uninstall(&install_dir, false).unwrap();
        assert!(!after_keep.installed);
        assert!(after_keep.has_models);
        assert!(model_file.is_file());

        // 彻底卸载（含模型）
        let after_full = uninstall(&install_dir, true).unwrap();
        assert!(!after_full.installed);
        assert!(!after_full.has_models);
        assert!(!install_dir.exists());

        let _ = fs::remove_dir_all(&base);
    }
}
