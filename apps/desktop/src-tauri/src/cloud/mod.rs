use crate::state::ServiceProbeResult;
use futures_util::StreamExt;
use reqwest::{Client, RequestBuilder};
use serde::Deserialize;
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Deserialize)]
pub struct HealthResponse {
    pub asr: Option<String>,
    pub mt: Option<String>,
    pub clone: Option<String>,
    pub asr_ready: Option<bool>,
    pub mt_ready: Option<bool>,
    pub clone_ready: Option<bool>,
    pub mt_model: Option<String>,
    pub asr_model: Option<String>,
    pub auth_mode: Option<String>,
    pub auth_ready: Option<bool>,
    pub transport_ready: Option<bool>,
    pub capabilities: Option<ServerCapabilities>,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct ServerCapabilities {
    pub streaming_mt: Option<bool>,
    pub per_device_preview: Option<bool>,
}

/// 规范化用户输入的服务地址（去除前后空格与 #hear-root=... 片段，缺少协议默认补 https://）
pub fn normalize_service_url(raw: &str) -> Result<String, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err("请先填写服务地址".to_string());
    }
    let without_fragment = trimmed.split('#').next().unwrap_or(trimmed).trim();
    if without_fragment.is_empty() {
        return Err("服务地址格式不正确".to_string());
    }
    let with_scheme = if without_fragment.starts_with("http://")
        || without_fragment.starts_with("https://")
    {
        without_fragment.to_string()
    } else {
        format!("https://{}", without_fragment)
    };
    Ok(with_scheme.trim_end_matches('/').to_string())
}

/// 判断目标 URL 是否为本机、局域网（RFC1918 / Link-Local / .local）或 CGNAT（100.64.0.0/10，如 Tailscale）：
/// - 仅对本机/内网自签证书放宽 TLS 校验；
/// - 所有公网域名（如 Cloudflare 代理域名）强制执行严格系统证书校验，防止中间人窃取访问口令。
pub fn is_local_or_lan_url(raw_url: &str) -> bool {
    let trimmed = raw_url.trim();
    let after_scheme = trimmed
        .split_once("://")
        .map(|(_, rest)| rest)
        .unwrap_or(trimmed);
    let authority = after_scheme.split('/').next().unwrap_or("");
    let host_port = authority.rsplit('@').next().unwrap_or(authority);
    let host = if let Some(rest) = host_port.strip_prefix('[') {
        rest.split(']').next().unwrap_or("")
    } else {
        host_port.split(':').next().unwrap_or("")
    }
    .trim()
    .to_ascii_lowercase();

    if host.is_empty() {
        return false;
    }
    if host == "localhost" || host.ends_with(".local") || host.ends_with(".localhost") {
        return true;
    }
    if let Ok(ip) = host.parse::<std::net::IpAddr>() {
        return match ip {
            std::net::IpAddr::V4(v4) => {
                let [a, b, _, _] = v4.octets();
                v4.is_loopback()
                    || v4.is_private()
                    || v4.is_link_local()
                    || (a == 100 && (64..=127).contains(&b))
            }
            std::net::IpAddr::V6(v6) => {
                let seg0 = v6.segments()[0];
                v6.is_loopback()
                    || (seg0 & 0xfe00) == 0xfc00
                    || (seg0 & 0xffc0) == 0xfe80
            }
        };
    }
    false
}

/// 跨平台 Hear 模型服务客户端（只做 HTTP/HTTPS 调用与只读探测，绝不管理任何服务端进程）
pub struct HearCloudClient {
    http_strict: Client,
    http_local: Client,
    device_id: String,
    /// 参考声纹上传 ID 缓存：(base_url, wav_fnv64) -> (ref_id, uploaded_at)
    /// 复用固定声纹时跳过每次 200KB 重复上传与往返握手，并让服务端命中 speaker reference 缓存
    ref_id_cache: std::sync::Mutex<std::collections::HashMap<(String, u64), (String, Instant)>>,
}

fn fnv1a_64(bytes: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for &b in bytes {
        h ^= b as u64;
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    h
}

impl HearCloudClient {
    pub fn new() -> Self {
        let ua = concat!(
            "HearDesktop/",
            env!("CARGO_PKG_VERSION"),
            " (Windows NT 10.0; Win64; x64)"
        );
        let http_strict = Client::builder()
            .no_proxy()
            .user_agent(ua)
            .connect_timeout(Duration::from_secs(5))
            .build()
            .expect("failed to build strict reqwest client");
        let http_local = Client::builder()
            .no_proxy()
            .user_agent(ua)
            .connect_timeout(Duration::from_secs(5))
            // 仅限局域网/本机自签证书使用
            .danger_accept_invalid_certs(true)
            .build()
            .expect("failed to build local reqwest client");
        Self {
            http_strict,
            http_local,
            device_id: format!("desktop-{}", &uuid::Uuid::new_v4().to_string()[..8]),
            ref_id_cache: std::sync::Mutex::new(std::collections::HashMap::new()),
        }
    }

    fn client_for_url(&self, url: &str) -> &Client {
        if is_local_or_lan_url(url) {
            &self.http_local
        } else {
            &self.http_strict
        }
    }

    fn apply_headers(&self, mut req: RequestBuilder, token: Option<&str>) -> RequestBuilder {
        req = req
            .header("X-Hear-Client", concat!("hear-desktop/", env!("CARGO_PKG_VERSION")))
            .header("X-Hear-Device-Id", &self.device_id);
        if let Some(tok) = token.map(str::trim).filter(|s| !s.is_empty()) {
            req = req.header("X-Hear-Token", tok);
        }
        req
    }

    /// 测试服务连接：探测 /health（及托管模式下的 /v1/auth/check），返回详细连通与模型状态
    pub async fn test_connection(&self, raw_address: &str, token: &str) -> ServiceProbeResult {
        let base_url = match normalize_service_url(raw_address) {
            Ok(u) => u,
            Err(msg) => {
                return ServiceProbeResult {
                    ok: false,
                    address: raw_address.trim().to_string(),
                    summary: msg.clone(),
                    error: Some(msg),
                    ..ServiceProbeResult::default()
                };
            }
        };

        let started = Instant::now();
        let health_url = format!("{}/health", base_url);
        let resp = match self
            .apply_headers(self.client_for_url(&health_url).get(&health_url), Some(token))
            .timeout(Duration::from_secs(6))
            .send()
            .await
        {
            Ok(r) => r,
            Err(e) => {
                let err_msg = format!("无法连接到服务：{}", e);
                return ServiceProbeResult {
                    ok: false,
                    address: base_url,
                    latency_ms: started.elapsed().as_millis() as u64,
                    summary: "连接失败，请确认服务端已启动且地址可达".to_string(),
                    error: Some(err_msg),
                    ..ServiceProbeResult::default()
                };
            }
        };

        let latency_ms = started.elapsed().as_millis() as u64;
        if !resp.status().is_success() {
            let status_code = resp.status().as_u16();
            return ServiceProbeResult {
                ok: false,
                address: base_url,
                latency_ms,
                summary: format!("服务返回异常状态码 HTTP {}", status_code),
                error: Some(format!("GET /health 返回 HTTP {}", status_code)),
                ..ServiceProbeResult::default()
            };
        }

        let health: HealthResponse = match resp.json().await {
            Ok(h) => h,
            Err(e) => {
                return ServiceProbeResult {
                    ok: false,
                    address: base_url,
                    latency_ms,
                    summary: "服务端响应格式不匹配（非 Hear 模型服务）".to_string(),
                    error: Some(format!("解析 /health 失败：{}", e)),
                    ..ServiceProbeResult::default()
                };
            }
        };

        let auth_mode = health.auth_mode.unwrap_or_else(|| "off".to_string());
        let transport_ready = health.transport_ready.unwrap_or(true);
        let mut auth_ok = Some(true);
        let mut auth_detail: Option<String> = None;

        if auth_mode == "managed" {
            if !transport_ready {
                auth_ok = Some(false);
                auth_detail = Some("当前使用明文 HTTP，托管鉴权要求 HTTPS 地址".to_string());
            } else if health.auth_ready == Some(false) {
                auth_ok = Some(false);
                auth_detail = Some("服务端鉴权清单尚未就绪（503）".to_string());
            } else {
                let check_url = format!("{}/v1/auth/check", base_url);
                match self
                    .apply_headers(self.client_for_url(&check_url).get(&check_url), Some(token))
                    .timeout(Duration::from_secs(5))
                    .send()
                    .await
                {
                    Ok(r) if r.status().is_success() => {
                        auth_ok = Some(true);
                        auth_detail = Some("访问口令校验通过".to_string());
                    }
                    Ok(r) => {
                        let code = r.status().as_u16();
                        let body_text = r.text().await.unwrap_or_default();
                        let msg = serde_json::from_str::<serde_json::Value>(&body_text)
                            .ok()
                            .and_then(|v| {
                                v.get("message")
                                    .or_else(|| v.get("error"))
                                    .and_then(|s| s.as_str())
                                    .map(str::to_string)
                            })
                            .unwrap_or_else(|| format!("口令校验未通过（HTTP {}）", code));
                        auth_ok = Some(false);
                        auth_detail = Some(msg);
                    }
                    Err(e) => {
                        auth_ok = Some(false);
                        auth_detail = Some(format!("校验访问口令失败：{}", e));
                    }
                }
            }
        } else if auth_mode == "legacy" {
            if !transport_ready {
                auth_ok = Some(false);
                auth_detail = Some("该服务已开启口令校验，请使用 https:// 地址连接".to_string());
            } else if token.trim().is_empty() {
                auth_ok = Some(false);
                auth_detail = Some("服务端要求填写访问口令".to_string());
            } else {
                auth_ok = Some(true);
                auth_detail = Some("已配置访问口令（HTTPS 线路正常）".to_string());
            }
        }

        let asr_detail = match (health.asr, health.asr_model) {
            (Some(s), Some(m)) if !m.is_empty() && !s.contains(&m) => format!("{}（{}）", s, m),
            (Some(s), _) => s,
            _ => "未知".to_string(),
        };
        let mt_detail = match (health.mt, health.mt_model) {
            (Some(s), Some(m)) if !m.is_empty() && !s.contains(&m) => format!("{}（{}）", s, m),
            (Some(s), _) => s,
            _ => "未知".to_string(),
        };
        let clone_detail = health.clone.unwrap_or_else(|| "未知".to_string());

        let overall_ok = auth_ok.unwrap_or(true);
        let summary = if overall_ok {
            format!("连接成功（{} ms）", latency_ms)
        } else {
            auth_detail
                .clone()
                .unwrap_or_else(|| format!("服务可达（{} ms），但鉴权未通过", latency_ms))
        };

        ServiceProbeResult {
            ok: overall_ok,
            address: base_url,
            latency_ms,
            summary,
            asr_ready: health.asr_ready.unwrap_or(false),
            asr_detail,
            mt_ready: health.mt_ready.unwrap_or(false),
            mt_detail,
            clone_ready: health.clone_ready.unwrap_or(false),
            clone_detail,
            auth_mode,
            auth_ok,
            auth_detail,
            streaming_mt: health
                .capabilities
                .and_then(|c| c.streaming_mt)
                .unwrap_or(false),
            error: None,
        }
    }

    /// 语音识别（POST /v1/asr）：上传 16 kHz 单声道 16-bit PCM WAV，返回 (识别文本, 识别语种)
    pub async fn transcribe_wav(
        &self,
        raw_address: &str,
        wav_bytes: Vec<u8>,
        languages: &str,
        fallback_lang: &str,
        preview: bool,
        token: Option<&str>,
    ) -> Result<(String, String), String> {
        let (text, lang, _) = self
            .transcribe_wav_staged(
                raw_address,
                wav_bytes,
                languages,
                fallback_lang,
                preview,
                None,
                token,
            )
            .await?;
        Ok((text, lang))
    }

    /// 双阶段语音识别（支持 X-ASR-Stage: first / correct，返回 (识别文本, 识别语种, 是否支持后台 Whisper 二次精修)）
    pub async fn transcribe_wav_staged(
        &self,
        raw_address: &str,
        wav_bytes: Vec<u8>,
        languages: &str,
        fallback_lang: &str,
        preview: bool,
        stage: Option<&str>,
        token: Option<&str>,
    ) -> Result<(String, String, bool), String> {
        let base_url = normalize_service_url(raw_address)?;
        let url = format!("{}/v1/asr", base_url);
        let mut req = self
            .client_for_url(&url)
            .post(&url)
            .header("Content-Type", "audio/wav")
            .header("X-Languages", languages)
            .header("X-Fallback-Language", fallback_lang)
            .body(wav_bytes);
        if preview {
            req = req.header("X-ASR-Preview", "1");
        }
        if let Some(st) = stage {
            req = req.header("X-ASR-Stage", st);
        }
        req = self.apply_headers(req, token);

        let resp = req
            .timeout(Duration::from_secs(if preview { 8 } else { 45 }))
            .send()
            .await
            .map_err(|e| format!("语音识别请求失败：{}", e))?;

        if !resp.status().is_success() {
            let status = resp.status().as_u16();
            let body = resp.text().await.unwrap_or_default();
            let msg = serde_json::from_str::<serde_json::Value>(&body)
                .ok()
                .and_then(|v| {
                    v.get("message")
                        .or_else(|| v.get("error"))
                        .and_then(|s| s.as_str())
                        .map(str::to_string)
                })
                .unwrap_or(body);
            return Err(format!("语音识别返回 HTTP {}：{}", status, msg));
        }

        let val: serde_json::Value = resp
            .json()
            .await
            .map_err(|e| format!("解析语音识别响应失败：{}", e))?;
        let text = val
            .get("text")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .trim()
            .to_string();
        let lang = val
            .get("lang")
            .and_then(|v| v.as_str())
            .unwrap_or(fallback_lang)
            .trim()
            .to_lowercase();
        let can_correct = val
            .get("can_correct")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        Ok((
            text,
            if lang.is_empty() {
                fallback_lang.to_string()
            } else {
                lang
            },
            can_correct,
        ))
    }

    /// 声音克隆语音合成（先上传参考音频到 /v1/clone/reference 获取 id，再调用 /v1/clone 返回 WAV 音频字节）
    pub async fn clone_voice(
        &self,
        raw_address: &str,
        text: &str,
        lang: &str,
        reference_wav: Option<Vec<u8>>,
        reference_text: &str,
        token: Option<&str>,
    ) -> Result<Vec<u8>, String> {
        let base_url = normalize_service_url(raw_address)?;
        let lower_lang = lang.trim().to_ascii_lowercase();
        let cloud_lang = match lower_lang.as_str() {
            "zh" | "zh-cn" | "zh-tw" => "chinese",
            "en" | "en-us" | "en-gb" => "english",
            "ja" | "ja-jp" => "japanese",
            "ko" | "ko-kr" => "korean",
            "de" | "de-de" => "german",
            "fr" | "fr-fr" => "french",
            "es" | "es-es" => "spanish",
            "ru" | "ru-ru" => "russian",
            "pt" | "pt-br" => "portuguese",
            "it" | "it-it" => "italian",
            other => other,
        };

        let mut ref_id: Option<String> = None;
        let mut ref_from_cache = false;
        let ref_len = reference_wav.as_ref().map(|w| w.len()).unwrap_or(0);
        let ref_cache_key = reference_wav
            .as_ref()
            .filter(|w| !w.is_empty())
            .map(|w| (base_url.clone(), fnv1a_64(w)));

        if let Some(ref key) = ref_cache_key {
            if let Ok(cache) = self.ref_id_cache.lock() {
                if let Some((cached_id, ts)) = cache.get(key) {
                    if ts.elapsed() < Duration::from_secs(20 * 60) {
                        ref_id = Some(cached_id.clone());
                        ref_from_cache = true;
                    }
                }
            }
        }

        if ref_id.is_none() {
            if let Some(ref wav) = reference_wav {
                if !wav.is_empty() {
                    let ref_url = format!("{}/v1/clone/reference", base_url);
                    let req = self.apply_headers(
                        self.client_for_url(&ref_url)
                            .post(&ref_url)
                            .header("Content-Type", "audio/wav")
                            .body(wav.clone()),
                        token,
                    );
                    match req.timeout(Duration::from_secs(12)).send().await {
                        Ok(resp) if resp.status().is_success() => {
                            if let Ok(val) = resp.json::<serde_json::Value>().await {
                                ref_id = val.get("id").and_then(|v| v.as_str()).map(str::to_string);
                                if let (Some(rid), Some(key)) = (ref_id.as_ref(), ref_cache_key.as_ref()) {
                                    if let Ok(mut cache) = self.ref_id_cache.lock() {
                                        if cache.len() >= 16 {
                                            cache.clear();
                                        }
                                        cache.insert(key.clone(), (rid.clone(), Instant::now()));
                                    }
                                }
                            }
                        }
                        Ok(resp) => {
                            crate::logger::warn(format!(
                                "[clone:reference] HTTP {} from {}",
                                resp.status().as_u16(),
                                ref_url
                            ));
                        }
                        Err(e) => {
                            crate::logger::warn(format!(
                                "[clone:reference] request failed {}: {}",
                                ref_url, e
                            ));
                        }
                    }
                }
            }
        }

        let clone_url = format!("{}/v1/clone", base_url);
        crate::logger::info(format!(
            "[clone] POST {} lang={} text_chars={} ref_bytes={} ref_id={:?} cached_ref={}",
            clone_url,
            cloud_lang,
            text.chars().count(),
            ref_len,
            ref_id,
            ref_from_cache
        ));
        let mut payload = serde_json::json!({
            "text": text,
            "lang": cloud_lang,
        });
        if let Some(rid) = ref_id {
            payload["reference_id"] = serde_json::Value::String(rid);
            if !reference_text.trim().is_empty() {
                payload["reference_text"] =
                    serde_json::Value::String(reference_text.trim().to_string());
            }
        }

        let backoff_ms = [1000u64, 1800, 2800];
        let max_attempts = backoff_ms.len() + 1;
        let mut reuploaded_ref = false;
        for attempt in 1..=max_attempts {
            let req = self.apply_headers(
                self.client_for_url(&clone_url)
                    .post(&clone_url)
                    .header("X-Hear-Audio", "wav")
                    .json(&payload),
                token,
            );
            let resp = req
                .timeout(Duration::from_secs(60))
                .send()
                .await
                .map_err(|e| {
                    let msg = format!("声音克隆请求失败：{}", e);
                    crate::logger::error(&msg);
                    msg
                })?;

            if resp.status().is_success() {
                let bytes = resp
                    .bytes()
                    .await
                    .map_err(|e| format!("读取声音克隆音频失败：{}", e))?;
                if bytes.len() < 44 {
                    return Err("声音克隆返回的音频数据为空".to_string());
                }
                crate::logger::info(format!("[clone] 合成完成: wav_bytes={}", bytes.len()));
                return Ok(bytes.to_vec());
            }

            let code = resp.status().as_u16();
            let body = resp.text().await.unwrap_or_default();
            // 若服务端重启导致缓存的 reference_id 失效（400/404），立即剔除缓存并重新上传一次参考音后重试
            if ref_from_cache && !reuploaded_ref && (code == 400 || code == 404) {
                reuploaded_ref = true;
                if let Some(ref key) = ref_cache_key {
                    if let Ok(mut cache) = self.ref_id_cache.lock() {
                        cache.remove(key);
                    }
                }
                if let Some(ref wav) = reference_wav {
                    if !wav.is_empty() {
                        let ref_url = format!("{}/v1/clone/reference", base_url);
                        let req = self.apply_headers(
                            self.client_for_url(&ref_url)
                                .post(&ref_url)
                                .header("Content-Type", "audio/wav")
                                .body(wav.clone()),
                            token,
                        );
                        if let Ok(r) = req.timeout(Duration::from_secs(12)).send().await {
                            if r.status().is_success() {
                                if let Ok(val) = r.json::<serde_json::Value>().await {
                                    if let Some(new_id) = val.get("id").and_then(|v| v.as_str()) {
                                        payload["reference_id"] =
                                            serde_json::Value::String(new_id.to_string());
                                        if let Some(ref key) = ref_cache_key {
                                            if let Ok(mut cache) = self.ref_id_cache.lock() {
                                                cache.insert(
                                                    key.clone(),
                                                    (new_id.to_string(), Instant::now()),
                                                );
                                            }
                                        }
                                        continue;
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if code == 503 && attempt < max_attempts {
                let wait = backoff_ms[attempt - 1];
                crate::logger::warn(format!(
                    "[clone] 服务端繁忙 (HTTP 503)，{}ms 后重试 ({}/{})",
                    wait, attempt, max_attempts
                ));
                tokio::time::sleep(Duration::from_millis(wait)).await;
                continue;
            }
            let msg = format!("声音克隆返回 HTTP {}：{}", code, body);
            crate::logger::error(&msg);
            return Err(msg);
        }
        Err("声音克隆重试次数已用尽".to_string())
    }

    /// 流式 SSE 文本翻译（逐字回调，降低桌面悬浮字幕首字延迟）
    pub async fn translate_stream<F>(
        &self,
        raw_address: &str,
        prompt: &str,
        preview: bool,
        token: Option<&str>,
        mut on_delta: F,
    ) -> Result<String, String>
    where
        F: FnMut(&str),
    {
        let base_url = normalize_service_url(raw_address)?;
        let url = format!("{}/v1/translate", base_url);
        let body = serde_json::json!({
            "prompt": prompt,
            "stream": true,
            "max_tokens": if preview { 256 } else { 512 },
        });
        let mut req = self
            .client_for_url(&url)
            .post(&url)
            .header("Accept", "text/event-stream, application/json")
            .json(&body);
        if preview {
            req = req.header("X-MT-Preview", "1");
        }
        req = self.apply_headers(req, token);
        let resp = req
            .timeout(Duration::from_secs(if preview { 8 } else { 120 }))
            .send()
            .await
            .map_err(|e| format!("翻译请求失败: {}", e))?;

        if !resp.status().is_success() {
            let status = resp.status().as_u16();
            let msg = resp.text().await.unwrap_or_default();
            return Err(format!("翻译返回 HTTP {}: {}", status, msg));
        }

        let content_type = resp
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
            .to_lowercase();

        // 兼容旧版或非流式服务端：当返回普通 application/json {"text": "..."} 时直接解析
        if !content_type.contains("text/event-stream") {
            let val: serde_json::Value = resp
                .json()
                .await
                .map_err(|e| format!("解析翻译响应失败: {}", e))?;
            if let Some(err) = val
                .get("message")
                .or_else(|| val.get("error"))
                .and_then(|v| v.as_str())
            {
                return Err(format!("翻译失败: {}", err));
            }
            let text = val
                .get("text")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            if !text.is_empty() {
                on_delta(&text);
            }
            return Ok(text);
        }

        let mut stream = resp.bytes_stream();
        let mut raw_buf: Vec<u8> = Vec::new();
        let mut full = String::new();

        while let Some(chunk) = stream.next().await {
            let bytes = chunk.map_err(|e| format!("读取流式翻译中断: {}", e))?;
            raw_buf.extend_from_slice(&bytes);
            while let Some(pos) = raw_buf.iter().position(|&b| b == b'\n') {
                let line_bytes: Vec<u8> = raw_buf.drain(..=pos).collect();
                let line = String::from_utf8_lossy(&line_bytes).trim().to_string();
                if let Some(payload) = line.strip_prefix("data:") {
                    if let Ok(val) = serde_json::from_str::<serde_json::Value>(payload.trim()) {
                        if let Some(err) = val.get("error").and_then(|v| v.as_str()) {
                            return Err(format!("流式翻译异常: {}", err));
                        }
                        if let Some(delta) = val.get("delta").and_then(|v| v.as_str()) {
                            full.push_str(delta);
                            on_delta(&full);
                        }
                        if val.get("done").and_then(|v| v.as_bool()) == Some(true) {
                            if let Some(final_text) = val.get("text").and_then(|v| v.as_str()) {
                                return Ok(final_text.to_string());
                            }
                        }
                    }
                }
            }
        }
        Ok(full)
    }

    /// 调用外部大模型 API（OpenAI 兼容或 Anthropic）流式生成会议纪要 / 自动标题
    pub async fn llm_chat_stream<F>(
        &self,
        provider: &str,
        raw_base_url: &str,
        api_key: &str,
        model: &str,
        system_prompt: &str,
        user_prompt: &str,
        mut on_delta: F,
    ) -> Result<String, String>
    where
        F: FnMut(&str),
    {
        let base = normalize_service_url(raw_base_url)?;
        let model_name = model.trim();
        if model_name.is_empty() {
            return Err("请先在设置中填写大模型名称（例如 deepseek-chat / gpt-4o-mini）".to_string());
        }
        let key = api_key.trim();

        if provider.eq_ignore_ascii_case("anthropic") {
            let url = if base.ends_with("/v1/messages") {
                base
            } else if base.ends_with("/v1") {
                format!("{}/messages", base)
            } else {
                format!("{}/v1/messages", base)
            };
            let body = serde_json::json!({
                "model": model_name,
                "max_tokens": 4096,
                "temperature": 0.3,
                "system": system_prompt,
                "messages": [{ "role": "user", "content": user_prompt }],
            });
            let mut req = self
                .client_for_url(&url)
                .post(&url)
                .header("anthropic-version", "2023-06-01")
                .header("Content-Type", "application/json")
                .json(&body);
            if !key.is_empty() {
                req = req.header("x-api-key", key);
            }
            let resp = req
                .timeout(Duration::from_secs(120))
                .send()
                .await
                .map_err(|e| format!("大模型请求失败：{}", e))?;
            if !resp.status().is_success() {
                let code = resp.status().as_u16();
                let txt = resp.text().await.unwrap_or_default();
                return Err(format!("Anthropic API 返回 HTTP {}：{}", code, txt));
            }
            let val: serde_json::Value = resp
                .json()
                .await
                .map_err(|e| format!("解析 Anthropic 响应失败：{}", e))?;
            let text = val
                .get("content")
                .and_then(|c| c.as_array())
                .map(|arr| {
                    arr.iter()
                        .filter_map(|item| item.get("text").and_then(|t| t.as_str()))
                        .collect::<Vec<_>>()
                        .join("")
                })
                .unwrap_or_default();
            if !text.is_empty() {
                on_delta(&text);
            }
            return Ok(text);
        }

        // 默认 OpenAI 兼容接口（支持 OpenAI / DeepSeek / 通义千问 / Kimi / OpenRouter / Ollama）
        let url = if base.ends_with("/chat/completions") {
            base
        } else {
            format!("{}/chat/completions", base)
        };
        let body = serde_json::json!({
            "model": model_name,
            "temperature": 0.3,
            "stream": true,
            "messages": [
                { "role": "system", "content": system_prompt },
                { "role": "user", "content": user_prompt }
            ],
        });
        let mut req = self
            .client_for_url(&url)
            .post(&url)
            .header("Content-Type", "application/json")
            .header("Accept", "text/event-stream, application/json")
            .json(&body);
        if !key.is_empty() {
            req = req.header("Authorization", format!("Bearer {}", key));
        }
        let resp = req
            .timeout(Duration::from_secs(120))
            .send()
            .await
            .map_err(|e| format!("大模型请求失败：{}", e))?;
        if !resp.status().is_success() {
            let code = resp.status().as_u16();
            let txt = resp.text().await.unwrap_or_default();
            return Err(format!("大模型 API 返回 HTTP {}：{}", code, txt));
        }

        let content_type = resp
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
            .to_ascii_lowercase();
        if !content_type.contains("text/event-stream") {
            let val: serde_json::Value = resp
                .json()
                .await
                .map_err(|e| format!("解析大模型响应失败：{}", e))?;
            let text = val
                .pointer("/choices/0/message/content")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            if !text.is_empty() {
                on_delta(&text);
            }
            return Ok(text);
        }

        let mut stream = resp.bytes_stream();
        let mut raw_buf: Vec<u8> = Vec::new();
        let mut full = String::new();
        while let Some(chunk) = stream.next().await {
            let bytes = chunk.map_err(|e| format!("读取大模型流式响应中断：{}", e))?;
            raw_buf.extend_from_slice(&bytes);
            while let Some(pos) = raw_buf.iter().position(|&b| b == b'\n') {
                let line_bytes: Vec<u8> = raw_buf.drain(..=pos).collect();
                let line = String::from_utf8_lossy(&line_bytes).trim().to_string();
                if let Some(payload) = line.strip_prefix("data:") {
                    let trimmed = payload.trim();
                    if trimmed == "[DONE]" {
                        return Ok(full);
                    }
                    if let Ok(val) = serde_json::from_str::<serde_json::Value>(trimmed) {
                        if let Some(delta) = val
                            .pointer("/choices/0/delta/content")
                            .and_then(|v| v.as_str())
                        {
                            full.push_str(delta);
                            on_delta(&full);
                        }
                    }
                }
            }
        }
        Ok(full)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn is_local_or_lan_url_distinguishes_public_and_lan() {
        assert!(is_local_or_lan_url("https://127.0.0.1:8000/health"));
        assert!(is_local_or_lan_url("https://localhost:8000/v1/asr"));
        assert!(is_local_or_lan_url("https://192.168.1.88:8000/v1/mt"));
        assert!(is_local_or_lan_url("https://10.0.0.12:8000/v1/clone"));
        assert!(is_local_or_lan_url("https://100.88.12.34:8000/health"));
        assert!(is_local_or_lan_url("https://mac-studio.local:8000/health"));
        assert!(!is_local_or_lan_url("https://hear.yueping1211.asia/v1/asr"));
        assert!(!is_local_or_lan_url("https://api.example.com:8443/health"));
    }
}
