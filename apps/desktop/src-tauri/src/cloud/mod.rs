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

/// 跨平台 Hear 模型服务客户端（只做 HTTP/HTTPS 调用与只读探测，绝不管理任何服务端进程）
pub struct HearCloudClient {
    http: Client,
    device_id: String,
}

impl HearCloudClient {
    pub fn new() -> Self {
        let http = Client::builder()
            .no_proxy()
            .connect_timeout(Duration::from_secs(5))
            // 兼容局域网/本机自签证书；后续可叠加 #hear-root=... 严格指纹固定校验
            .danger_accept_invalid_certs(true)
            .build()
            .expect("failed to build reqwest client");
        Self {
            http,
            device_id: format!("desktop-{}", &uuid::Uuid::new_v4().to_string()[..8]),
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
            .apply_headers(self.http.get(&health_url), Some(token))
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
                    .apply_headers(self.http.get(&check_url), Some(token))
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
        let mut req = self.http.post(&url).json(&body);
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

        let mut stream = resp.bytes_stream();
        let mut buf = String::new();
        let mut full = String::new();

        while let Some(chunk) = stream.next().await {
            let bytes = chunk.map_err(|e| format!("读取流式翻译中断: {}", e))?;
            buf.push_str(&String::from_utf8_lossy(&bytes));
            while let Some(idx) = buf.find('\n') {
                let line = buf[..idx].trim().to_string();
                buf.drain(..=idx);
                if let Some(payload) = line.strip_prefix("data:") {
                    if let Ok(val) = serde_json::from_str::<serde_json::Value>(payload.trim()) {
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
}
