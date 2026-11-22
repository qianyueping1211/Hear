use futures_util::StreamExt;
use reqwest::{Client, RequestBuilder};
use serde::Deserialize;
use std::time::Duration;

#[derive(Debug, Clone, Deserialize)]
pub struct HealthResponse {
    pub asr: Option<String>,
    pub mt: Option<String>,
    pub clone: Option<String>,
    pub asr_ready: Option<bool>,
    pub mt_ready: Option<bool>,
    pub clone_ready: Option<bool>,
    pub bind_host: Option<String>,
    pub lan_shared: Option<bool>,
    pub capabilities: Option<ServerCapabilities>,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct ServerCapabilities {
    pub streaming_mt: Option<bool>,
    pub per_device_preview: Option<bool>,
    pub local_secret: Option<bool>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PairResponse {
    pub root_fingerprint: Option<String>,
}

/// 跨平台 Hear 云端/本机统一协议客户端（支持 X-Hear-Device-Id 隔离、本机密钥、Token 与 SSE 流式翻译）
pub struct HearCloudClient {
    http: Client,
    device_id: String,
}

impl HearCloudClient {
    pub fn new() -> Self {
        let http = Client::builder()
            .no_proxy()
            .connect_timeout(Duration::from_secs(5))
            // Phase 1 兼容自签局域网证书；Phase 2 接入 #hear-root=... 精确根证书固定校验
            .danger_accept_invalid_certs(true)
            .build()
            .expect("failed to build reqwest client");
        Self {
            http,
            device_id: format!("desktop-{}", &uuid::Uuid::new_v4().to_string()[..8]),
        }
    }

    fn apply_headers(
        &self,
        mut req: RequestBuilder,
        token: Option<&str>,
        local_secret: Option<&str>,
    ) -> RequestBuilder {
        req = req
            .header("X-Hear-Client", concat!("hear-desktop/", env!("CARGO_PKG_VERSION")))
            .header("X-Hear-Device-Id", &self.device_id);
        if let Some(sec) = local_secret.filter(|s| !s.is_empty()) {
            req = req.header("X-Hear-Local-Secret", sec);
        }
        if let Some(tok) = token.filter(|s| !s.is_empty()) {
            req = req.header("X-Hear-Token", tok);
        }
        req
    }

    pub async fn health(&self, base_url: &str) -> Result<HealthResponse, String> {
        let url = format!("{}/health", base_url.trim_end_matches('/'));
        let resp = self
            .http
            .get(&url)
            .timeout(Duration::from_secs(5))
            .send()
            .await
            .map_err(|e| format!("无法连接服务: {}", e))?;
        if !resp.status().is_success() {
            return Err(format!("服务返回 HTTP {}", resp.status().as_u16()));
        }
        resp.json::<HealthResponse>()
            .await
            .map_err(|e| format!("解析 /health 失败: {}", e))
    }

    pub async fn pair_info(&self, base_url: &str) -> Result<PairResponse, String> {
        let url = format!("{}/v1/pair", base_url.trim_end_matches('/'));
        let resp = self
            .http
            .get(&url)
            .timeout(Duration::from_secs(5))
            .send()
            .await
            .map_err(|e| format!("无法读取配对指纹: {}", e))?;
        resp.json::<PairResponse>()
            .await
            .map_err(|e| format!("解析 /v1/pair 失败: {}", e))
    }

    /// 流式 SSE 文本翻译（逐字回调，大幅降低桌面悬浮字幕首字延迟）
    pub async fn translate_stream<F>(
        &self,
        base_url: &str,
        prompt: &str,
        preview: bool,
        token: Option<&str>,
        local_secret: Option<&str>,
        mut on_delta: F,
    ) -> Result<String, String>
    where
        F: FnMut(&str),
    {
        let url = format!("{}/v1/translate", base_url.trim_end_matches('/'));
        let body = serde_json::json!({
            "prompt": prompt,
            "stream": true,
            "max_tokens": if preview { 256 } else { 512 },
        });
        let mut req = self.http.post(&url).json(&body);
        if preview {
            req = req.header("X-MT-Preview", "1");
        }
        req = self.apply_headers(req, token, local_secret);
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
