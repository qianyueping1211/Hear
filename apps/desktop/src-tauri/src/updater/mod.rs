use crate::state::{UpdateCheckResult, UpdateConfig};
use futures_util::StreamExt;
use reqwest::Client;
use serde::Deserialize;
use std::io::Write;
use std::path::PathBuf;
use std::time::Duration;

pub const CURRENT_VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Debug, Deserialize)]
struct GhRelease {
    tag_name: String,
    name: Option<String>,
    body: Option<String>,
    draft: Option<bool>,
    published_at: Option<String>,
    html_url: String,
    assets: Option<Vec<GhAsset>>,
}

#[derive(Debug, Deserialize)]
struct GhAsset {
    name: String,
    size: u64,
    url: String,
    browser_download_url: String,
}

pub(crate) fn parse_semver(s: &str) -> Option<(u64, u64, u64)> {
    let clean = s
        .trim()
        .trim_start_matches("win-v")
        .trim_start_matches("v");
    let mut parts = clean.split('.');
    let major = parts.next()?.parse::<u64>().ok()?;
    let minor = parts.next()?.parse::<u64>().ok()?;
    let patch_raw = parts.next()?;
    let patch_digits: String = patch_raw.chars().take_while(|c| c.is_ascii_digit()).collect();
    let patch = patch_digits.parse::<u64>().ok()?;
    Some((major, minor, patch))
}

pub(crate) fn clean_repo(raw: &str) -> String {
    let trimmed = raw
        .trim()
        .trim_start_matches("https://github.com/")
        .trim_start_matches("http://github.com/")
        .trim_end_matches(".git")
        .trim_matches('/');
    if trimmed.contains('/') {
        trimmed.to_string()
    } else {
        "qianyueping1211/Hear".to_string()
    }
}

fn build_http_client() -> Result<Client, String> {
    Client::builder()
        .connect_timeout(Duration::from_secs(10))
        .user_agent(format!("Hear-Desktop/{}", CURRENT_VERSION))
        .build()
        .map_err(|e| format!("创建网络客户端失败：{}", e))
}

/// 检查 GitHub Releases 中的最新 Windows 版本（过滤 `win-v*` 标签，不与 iOS 混淆）
pub async fn check_for_updates(cfg: &UpdateConfig) -> UpdateCheckResult {
    let repo = clean_repo(&cfg.repo);
    let repo_url = format!("https://github.com/{}", repo);
    let mut base = UpdateCheckResult {
        current_version: CURRENT_VERSION.to_string(),
        repo_url: repo_url.clone(),
        ..UpdateCheckResult::default()
    };

    let client = match build_http_client() {
        Ok(c) => c,
        Err(e) => {
            base.error = Some(e);
            return base;
        }
    };

    let api_url = format!("https://api.github.com/repos/{}/releases?per_page=100", repo);
    let mut req = client
        .get(&api_url)
        .header("Accept", "application/vnd.github+json")
        .header("X-GitHub-Api-Version", "2022-11-28")
        .timeout(Duration::from_secs(15));

    let token = cfg.github_token.trim();
    if !token.is_empty() {
        req = req.header("Authorization", format!("Bearer {}", token));
    }

    let resp = match req.send().await {
        Ok(r) => r,
        Err(e) => {
            base.error = Some(format!("无法连接 GitHub 检查更新：{}", e));
            return base;
        }
    };

    let status = resp.status();
    if !status.is_success() {
        let code = status.as_u16();
        let hint = match code {
            401 => "GitHub Token 无效或已过期（HTTP 401）".to_string(),
            403 => "GitHub API 请求受限或权限不足（HTTP 403），建议配置 GitHub Token".to_string(),
            404 => "未找到仓库或无权访问私有仓库（HTTP 404），请检查仓库名与 GitHub Token".to_string(),
            _ => format!("GitHub API 返回 HTTP {}", code),
        };
        base.error = Some(hint);
        return base;
    }

    let releases: Vec<GhRelease> = match resp.json().await {
        Ok(list) => list,
        Err(e) => {
            base.error = Some(format!("解析 GitHub Release 列表失败：{}", e));
            return base;
        }
    };

    // 只选择非草稿的 Windows 版本（tag 以 win-v 开头），按语义化版本号取最大
    let latest = releases
        .into_iter()
        .filter(|r| !r.draft.unwrap_or(false) && r.tag_name.starts_with("win-v"))
        .filter_map(|r| parse_semver(&r.tag_name).map(|v| (v, r)))
        .max_by_key(|(v, _)| *v);

    let Some((latest_ver, rel)) = latest else {
        base.error = Some("仓库中暂未找到 win-v* 格式的 Windows 发布版本".to_string());
        return base;
    };

    let current_ver = parse_semver(CURRENT_VERSION).unwrap_or((0, 0, 0));
    let latest_str = format!("{}.{}.{}", latest_ver.0, latest_ver.1, latest_ver.2);
    let has_update = latest_ver > current_ver;

    let exe_asset = rel
        .assets
        .unwrap_or_default()
        .into_iter()
        .find(|a| a.name.to_lowercase().ends_with(".exe"));

    UpdateCheckResult {
        current_version: CURRENT_VERSION.to_string(),
        latest_version: Some(latest_str),
        has_update,
        tag_name: Some(rel.tag_name),
        release_title: rel.name,
        release_notes: rel.body.unwrap_or_default(),
        published_at: rel.published_at,
        release_url: Some(rel.html_url),
        repo_url,
        asset_name: exe_asset.as_ref().map(|a| a.name.clone()),
        asset_api_url: exe_asset.as_ref().map(|a| a.url.clone()),
        asset_browser_url: exe_asset.as_ref().map(|a| a.browser_download_url.clone()),
        asset_size: exe_asset.as_ref().map(|a| a.size),
        error: None,
    }
}

/// 下载 Windows .exe 安装包并启动安装程序（支持带 GitHub Token 下载私有仓库附件）
pub async fn download_and_launch_installer<F>(
    asset_api_url: &str,
    asset_name: &str,
    github_token: &str,
    mut on_progress: F,
) -> Result<PathBuf, String>
where
    F: FnMut(u64, u64),
{
    if !asset_api_url.starts_with("https://") {
        return Err("更新下载地址必须是 HTTPS".to_string());
    }
    let safe_name: String = asset_name
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_'))
        .collect();
    if safe_name.is_empty() || !safe_name.to_lowercase().ends_with(".exe") {
        return Err("无效的安装包文件名".to_string());
    }

    let client = build_http_client()?;
    let mut req = client
        .get(asset_api_url)
        .header("Accept", "application/octet-stream")
        .timeout(Duration::from_secs(600));
    let token = github_token.trim();
    if !token.is_empty() {
        req = req.header("Authorization", format!("Bearer {}", token));
    }

    let resp = req
        .send()
        .await
        .map_err(|e| format!("下载安装包失败：{}", e))?;
    if !resp.status().is_success() {
        return Err(format!("下载安装包返回 HTTP {}", resp.status().as_u16()));
    }

    let total = resp.content_length().unwrap_or(0);
    let update_dir = std::env::temp_dir().join("Hear-Update");
    std::fs::create_dir_all(&update_dir).map_err(|e| format!("创建临时更新目录失败：{}", e))?;
    let dest = update_dir.join(&safe_name);
    let tmp = dest.with_extension("exe.part");

    let mut file =
        std::fs::File::create(&tmp).map_err(|e| format!("创建下载文件失败：{}", e))?;
    let mut stream = resp.bytes_stream();
    let mut downloaded: u64 = 0;
    let mut first_bytes = Vec::new();

    while let Some(chunk_res) = stream.next().await {
        let chunk = chunk_res.map_err(|e| format!("下载中断：{}", e))?;
        if first_bytes.len() < 2 {
            first_bytes.extend_from_slice(&chunk[..chunk.len().min(2 - first_bytes.len())]);
        }
        file.write_all(&chunk)
            .map_err(|e| format!("写入安装包失败：{}", e))?;
        downloaded += chunk.len() as u64;
        on_progress(downloaded, total);
    }
    file.flush().map_err(|e| format!("刷盘失败：{}", e))?;
    drop(file);

    // 校验 Windows PE 可执行文件头 "MZ"
    if first_bytes.len() < 2 || &first_bytes[..2] != b"MZ" {
        let _ = std::fs::remove_file(&tmp);
        return Err("下载的文件不是有效的 Windows 安装程序（MZ 头校验失败）".to_string());
    }

    let _ = std::fs::remove_file(&dest);
    std::fs::rename(&tmp, &dest).map_err(|e| format!("保存安装包失败：{}", e))?;

    #[cfg(target_os = "windows")]
    {
        std::process::Command::new(&dest)
            .spawn()
            .map_err(|e| format!("启动安装程序失败：{}", e))?;
    }

    Ok(dest)
}

/// 在系统默认浏览器中安全打开 HTTPS 链接（仅允许 https://github.com/）
pub fn open_github_url(url: &str) -> Result<(), String> {
    let trimmed = url.trim();
    if !trimmed.starts_with("https://github.com/") {
        return Err("仅允许打开 https://github.com/ 链接".to_string());
    }
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        std::process::Command::new("cmd")
            .args(["/C", "start", "", trimmed])
            .creation_flags(CREATE_NO_WINDOW)
            .spawn()
            .map_err(|e| format!("打开浏览器失败：{}", e))?;
    }
    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("open")
            .arg(trimmed)
            .spawn()
            .map_err(|e| format!("打开浏览器失败：{}", e))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_windows_tags_and_compares_semver() {
        assert_eq!(parse_semver("win-v0.1.3"), Some((0, 1, 3)));
        assert_eq!(parse_semver("v0.4.86"), Some((0, 4, 86)));
        assert!(parse_semver("win-v0.1.10").unwrap() > parse_semver("win-v0.1.2").unwrap());
        assert_eq!(
            clean_repo("https://github.com/qianyueping1211/Hear.git"),
            "qianyueping1211/Hear"
        );
    }
}
