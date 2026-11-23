use std::net::{IpAddr, Ipv4Addr, UdpSocket};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, RwLock};
use std::time::Duration;
use tokio::sync::watch;
use tracing::{info, warn};

/// Normalizes a `.local` mDNS hostname (strips trailing dots, lowercases).
pub fn normalize_mdns_hostname(raw: &str) -> String {
    let trimmed = raw.trim().trim_end_matches('.').to_ascii_lowercase();
    if trimmed.is_empty() {
        "acpm.local".to_string()
    } else if trimmed.contains('.') {
        trimmed
    } else {
        format!("{trimmed}.local")
    }
}

/// Returns `true` when `ip` is a usable LAN IPv4 address for mDNS advertisement,
/// filtering out loopback, unspecified, link-local, multicast, broadcast, and
/// RFC 2544 / proxy fake-IP TUN addresses (`198.18.0.0/15`).
pub fn is_usable_lan_ipv4(ip: Ipv4Addr) -> bool {
    let [a, b, _, _] = ip.octets();
    let is_benchmark_or_fake_ip_tun = a == 198 && (b == 18 || b == 19);
    !ip.is_loopback()
        && !ip.is_unspecified()
        && !ip.is_link_local()
        && !ip.is_multicast()
        && !ip.is_broadcast()
        && !is_benchmark_or_fake_ip_tun
}

/// Detects the host's primary non-loopback LAN IPv4 address.
pub fn detect_lan_ipv4() -> Option<Ipv4Addr> {
    #[cfg(target_os = "macos")]
    {
        for iface in ["en0", "en1", "en2", "en3", "en4", "en5", "en6", "bridge0"] {
            if let Ok(output) = Command::new("ipconfig").args(["getifaddr", iface]).output() {
                if output.status.success() {
                    if let Ok(ip) = String::from_utf8_lossy(&output.stdout)
                        .trim()
                        .parse::<Ipv4Addr>()
                    {
                        if is_usable_lan_ipv4(ip) {
                            return Some(ip);
                        }
                    }
                }
            }
        }
    }

    for probe in ["192.0.2.1:80", "8.8.8.8:80"] {
        if let Ok(socket) = UdpSocket::bind("0.0.0.0:0") {
            if socket.connect(probe).is_ok() {
                if let Ok(local) = socket.local_addr() {
                    if let IpAddr::V4(v4) = local.ip() {
                        if is_usable_lan_ipv4(v4) {
                            return Some(v4);
                        }
                    }
                }
            }
        }
    }

    None
}

#[derive(Debug, Clone)]
pub struct MdnsConfig {
    pub service_name: String,
    pub hostname: String,
    pub port: u16,
    pub capabilities: Vec<String>,
}

/// Manages mDNS proxy registration (`_acpm._tcp` + `<hostname>.local`) via macOS `dns-sd -P`
/// and tracks active LAN IPv4 changes so `Host` header validation stays current.
pub struct MdnsAdvertiser {
    active_ip: Arc<RwLock<Option<Ipv4Addr>>>,
    shutdown_tx: watch::Sender<bool>,
    task_handle: Option<tokio::task::JoinHandle<()>>,
    child: Arc<std::sync::Mutex<Option<Child>>>,
}

impl MdnsAdvertiser {
    pub fn start(config: MdnsConfig) -> Self {
        let initial_ip = detect_lan_ipv4();
        let active_ip = Arc::new(RwLock::new(initial_ip));
        let child = Arc::new(std::sync::Mutex::new(None));
        let (shutdown_tx, mut shutdown_rx) = watch::channel(false);

        if let Some(ip) = initial_ip {
            if let Some(proc) = spawn_dns_sd(&config, ip) {
                if let Ok(mut guard) = child.lock() {
                    *guard = Some(proc);
                }
            }
        } else {
            warn!(
                hostname = %config.hostname,
                "no active LAN IPv4 detected at startup; mDNS advertisement will retry in background"
            );
        }

        let ip_ref = Arc::clone(&active_ip);
        let child_ref = Arc::clone(&child);
        let task_handle = tokio::spawn(async move {
            let mut interval = tokio::time::interval(Duration::from_secs(10));
            interval.tick().await;
            loop {
                tokio::select! {
                    _ = shutdown_rx.changed() => {
                        if *shutdown_rx.borrow() {
                            break;
                        }
                    }
                    _ = interval.tick() => {
                        let next_ip = detect_lan_ipv4();
                        let prev_ip = ip_ref.read().ok().and_then(|g| *g);
                        let child_exited = child_ref
                            .lock()
                            .ok()
                            .and_then(|mut g| match g.as_mut() {
                                Some(c) => Some(c.try_wait().ok().flatten().is_some()),
                                None => Some(true),
                            })
                            .unwrap_or(true);

                        if next_ip != prev_ip || (next_ip.is_some() && child_exited) {
                            if let Ok(mut g) = child_ref.lock() {
                                if let Some(mut old) = g.take() {
                                    let _ = old.kill();
                                    let _ = old.wait();
                                }
                                if let Some(ip) = next_ip {
                                    *g = spawn_dns_sd(&config, ip);
                                }
                            }
                            if let Ok(mut g) = ip_ref.write() {
                                *g = next_ip;
                            }
                        }
                    }
                }
            }
        });

        Self {
            active_ip,
            shutdown_tx,
            task_handle: Some(task_handle),
            child,
        }
    }

    pub fn active_ip_handle(&self) -> Arc<RwLock<Option<Ipv4Addr>>> {
        Arc::clone(&self.active_ip)
    }

    pub fn stop(&mut self) {
        let _ = self.shutdown_tx.send(true);
        if let Some(handle) = self.task_handle.take() {
            handle.abort();
        }
        if let Ok(mut guard) = self.child.lock() {
            if let Some(mut proc) = guard.take() {
                let _ = proc.kill();
                let _ = proc.wait();
            }
        }
    }
}

impl Drop for MdnsAdvertiser {
    fn drop(&mut self) {
        self.stop();
    }
}

#[cfg(target_os = "macos")]
fn spawn_dns_sd(config: &MdnsConfig, lan_ip: Ipv4Addr) -> Option<Child> {
    let fqdn = format!("{}.", config.hostname.trim_end_matches('.'));
    let port_str = config.port.to_string();
    let ip_str = lan_ip.to_string();
    let caps = config.capabilities.join(",");
    let args = vec![
        "-P".to_string(),
        config.service_name.clone(),
        "_acpm._tcp".to_string(),
        "local.".to_string(),
        port_str.clone(),
        fqdn,
        ip_str.clone(),
        "version=1".to_string(),
        format!("host={}", config.hostname),
        format!("port={port_str}"),
        format!("capabilities={caps}"),
    ];

    match Command::new("/usr/bin/dns-sd")
        .args(&args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(child) => {
            info!(
                pid = child.id(),
                hostname = %config.hostname,
                lan_ip = %ip_str,
                port = config.port,
                "mDNS fixed-domain advertisement started (_acpm._tcp.local.)"
            );
            Some(child)
        }
        Err(err) => {
            warn!(error = %err, "failed to launch /usr/bin/dns-sd for mDNS advertisement");
            None
        }
    }
}

#[cfg(not(target_os = "macos"))]
fn spawn_dns_sd(_config: &MdnsConfig, _lan_ip: Ipv4Addr) -> Option<Child> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_mdns_hostname() {
        assert_eq!(normalize_mdns_hostname("acpm.local"), "acpm.local");
        assert_eq!(normalize_mdns_hostname("ACPM.LOCAL."), "acpm.local");
        assert_eq!(normalize_mdns_hostname("yanmo"), "yanmo.local");
        assert_eq!(normalize_mdns_hostname("  "), "acpm.local");
    }

    #[test]
    fn filters_fake_ip_tun_and_non_lan_addresses() {
        assert!(is_usable_lan_ipv4(Ipv4Addr::new(192, 168, 31, 127)));
        assert!(is_usable_lan_ipv4(Ipv4Addr::new(10, 0, 0, 5)));
        assert!(!is_usable_lan_ipv4(Ipv4Addr::new(127, 0, 0, 1)));
        assert!(!is_usable_lan_ipv4(Ipv4Addr::new(0, 0, 0, 0)));
        assert!(!is_usable_lan_ipv4(Ipv4Addr::new(169, 254, 1, 2)));
        assert!(!is_usable_lan_ipv4(Ipv4Addr::new(198, 18, 0, 1)));
        assert!(!is_usable_lan_ipv4(Ipv4Addr::new(198, 19, 255, 254)));
    }
}
