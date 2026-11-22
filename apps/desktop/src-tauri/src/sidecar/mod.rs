use crate::cloud::HearCloudClient;
use crate::platform::os::ChildProcessGuard;
use crate::state::{ServerSwitches, ServiceStatus};
use rand::RngCore;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};

/// 本机 `server/` 托管器（支持 Tauri Sidecar 附带程序 + 开发期本地 Python 回退）
/// 严格执行「仅本机 127.0.0.1」与「局域网共享给 iPhone (0.0.0.0 + 口令 + HTTPS)」双开关隔离。
pub struct LocalEngineManager {
    child: Option<Child>,
    guard: ChildProcessGuard,
    local_secret: String,
    port: u16,
    lan_shared: bool,
}

impl LocalEngineManager {
    pub fn new(port: u16) -> Self {
        Self {
            child: None,
            guard: ChildProcessGuard::new(),
            local_secret: generate_ephemeral_secret(),
            port,
            lan_shared: false,
        }
    }

    pub fn local_secret(&self) -> &str {
        &self.local_secret
    }

    pub fn local_base_url(&self) -> String {
        format!("http://127.0.0.1:{}", self.port)
    }

    pub fn is_running(&mut self) -> bool {
        if let Some(child) = self.child.as_mut() {
            matches!(child.try_wait(), Ok(None))
        } else {
            false
        }
    }

    /// 按双开关配置启动或重启本机托管服务
    pub fn start(&mut self, switches: &ServerSwitches) -> Result<ServiceStatus, String> {
        self.stop();
        if !switches.local_server_enabled {
            return Ok(ServiceStatus::default());
        }

        let bind_host = if switches.lan_share_enabled {
            "0.0.0.0"
        } else {
            "127.0.0.1"
        };
        self.lan_shared = switches.lan_share_enabled;

        let mut cmd = build_server_command()?;
        cmd.env("PYTHONUTF8", "1")
            .env("HEAR_BIND_HOST", bind_host)
            .env("HEAR_PORT", self.port.to_string())
            .env("HEAR_LOCAL_SECRET", &self.local_secret)
            .stdout(Stdio::null())
            .stderr(Stdio::null());

        if switches.lan_share_enabled {
            // 开关 2 打开：强制要求访问口令（局域网 iPhone 走 HTTPS + X-Hear-Token）
            cmd.env("HEAR_REQUIRE_TOKEN", "1")
                .env("HEAR_SHOW_VERIFIED_ADDRESS", "1");
        } else {
            // 开关 1 仅本机模式：仅绑定 127.0.0.1 + 仅接受本机会话密钥，不暴露局域网
            cmd.env_remove("HEAR_REQUIRE_TOKEN")
                .env("HEAR_AUTH_MODE", "off");
        }

        let child = cmd
            .spawn()
            .map_err(|e| format!("启动本机 Hear 服务失败: {}", e))?;
        self.guard.attach_pid(child.id());
        self.child = Some(child);

        Ok(ServiceStatus {
            running: true,
            bind_host: bind_host.to_string(),
            port: self.port,
            lan_shared: switches.lan_share_enabled,
            asr_detail: "启动中…".to_string(),
            mt_detail: "启动中…".to_string(),
            clone_detail: "启动中…".to_string(),
            ..ServiceStatus::default()
        })
    }

    pub fn stop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }

    pub async fn probe_status(&mut self, client: &HearCloudClient) -> ServiceStatus {
        let running = self.is_running();
        let mut status = ServiceStatus {
            running,
            bind_host: if self.lan_shared {
                "0.0.0.0".into()
            } else {
                "127.0.0.1".into()
            },
            port: self.port,
            lan_shared: self.lan_shared,
            ..ServiceStatus::default()
        };

        let base = self.local_base_url();
        match client.health(&base).await {
            Ok(h) => {
                status.running = true;
                status.asr_ready = h.asr_ready.unwrap_or(false);
                status.asr_detail = h.asr.unwrap_or_else(|| "未知".into());
                status.mt_ready = h.mt_ready.unwrap_or(false);
                status.mt_detail = h.mt.unwrap_or_else(|| "未知".into());
                status.clone_ready = h.clone_ready.unwrap_or(false);
                status.clone_detail = h.clone.unwrap_or_else(|| "未知".into());
                status.bind_host = h.bind_host.unwrap_or(status.bind_host);
                status.lan_shared = h.lan_shared.unwrap_or(status.lan_shared);
                status.streaming_mt = h
                    .capabilities
                    .and_then(|c| c.streaming_mt)
                    .unwrap_or(true);
                if status.lan_shared {
                    if let Ok(pair) = client.pair_info(&base).await {
                        if let Some(fp) = pair.root_fingerprint {
                            let digest = fp.replace(':', "").to_lowercase();
                            status.pairing_address =
                                format!("https://<本机局域网IP>:{}#hear-root={}", self.port, digest);
                        }
                    }
                }
            }
            Err(err) => {
                status.last_error = Some(err);
                if running {
                    status.asr_detail = "初始化中…".into();
                    status.mt_detail = "初始化中…".into();
                }
            }
        }
        status
    }
}

impl Drop for LocalEngineManager {
    fn drop(&mut self) {
        self.stop();
    }
}

fn generate_ephemeral_secret() -> String {
    let mut bytes = [0u8; 24];
    rand::thread_rng().fill_bytes(&mut bytes);
    bytes.iter().map(|b| format!("{:02x}", b)).collect()
}

/// 优先定位 Tauri 打包的附带程序 `hear-server`，开发期自动回退到仓库 `server/hear_cloud.py`
fn build_server_command() -> Result<Command, String> {
    if let Ok(exe_dir) = std::env::current_exe().and_then(|p| {
        p.parent()
            .map(PathBuf::from)
            .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::NotFound, "no exe dir"))
    }) {
        let sidecar_name = if cfg!(windows) {
            "hear-server.exe"
        } else {
            "hear-server"
        };
        let bundled = exe_dir.join(sidecar_name);
        if bundled.exists() {
            return Ok(Command::new(bundled));
        }
    }

    // 开发期回退：查找同仓库的 server/hear_cloud.py（兼容 apps/desktop/ 与仓库根目录启动）
    let candidates = [
        PathBuf::from("../../server/hear_cloud.py"),
        PathBuf::from("../../../server/hear_cloud.py"),
        PathBuf::from("../../../../server/hear_cloud.py"),
        PathBuf::from("../server/hear_cloud.py"),
        PathBuf::from("server/hear_cloud.py"),
    ];
    for script in candidates {
        if script.exists() {
            let mut cmd = Command::new("python");
            cmd.arg(script);
            return Ok(cmd);
        }
    }

    Err("未找到附带服务程序 hear-server 或 server/hear_cloud.py".into())
}
