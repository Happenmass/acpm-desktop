use std::collections::HashMap;
use std::io;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::pin::Pin;
use std::task::{Context, Poll};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader, ReadBuf};
use tokio::net::TcpStream;
#[cfg(unix)]
use tokio::net::UnixStream;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WorkerEndpoint {
    #[cfg(unix)]
    Unix(PathBuf),
    #[allow(dead_code)]
    Tcp(SocketAddr),
}

enum WorkerStream {
    #[cfg(unix)]
    Unix(UnixStream),
    Tcp(TcpStream),
}

impl AsyncRead for WorkerStream {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        match self.get_mut() {
            #[cfg(unix)]
            WorkerStream::Unix(s) => Pin::new(s).poll_read(cx, buf),
            WorkerStream::Tcp(s) => Pin::new(s).poll_read(cx, buf),
        }
    }
}

impl AsyncWrite for WorkerStream {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        data: &[u8],
    ) -> Poll<io::Result<usize>> {
        match self.get_mut() {
            #[cfg(unix)]
            WorkerStream::Unix(s) => Pin::new(s).poll_write(cx, data),
            WorkerStream::Tcp(s) => Pin::new(s).poll_write(cx, data),
        }
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        match self.get_mut() {
            #[cfg(unix)]
            WorkerStream::Unix(s) => Pin::new(s).poll_flush(cx),
            WorkerStream::Tcp(s) => Pin::new(s).poll_flush(cx),
        }
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        match self.get_mut() {
            #[cfg(unix)]
            WorkerStream::Unix(s) => Pin::new(s).poll_shutdown(cx),
            WorkerStream::Tcp(s) => Pin::new(s).poll_shutdown(cx),
        }
    }
}

#[derive(Debug, Clone)]
pub struct WorkerHttpResponse {
    pub status: u16,
    pub headers: HashMap<String, String>,
    pub body: Vec<u8>,
}

pub struct WorkerNdjsonStream {
    reader: BufReader<WorkerStream>,
}

impl WorkerNdjsonStream {
    pub async fn next_line(&mut self) -> Result<Option<String>, String> {
        let mut line = String::new();
        loop {
            line.clear();
            let n = self
                .reader
                .read_line(&mut line)
                .await
                .map_err(|e| format!("worker stream read error: {e}"))?;
            if n == 0 {
                return Ok(None);
            }
            let trimmed = line.trim();
            if !trimmed.is_empty() {
                return Ok(Some(trimmed.to_string()));
            }
        }
    }
}

async fn connect_endpoint(endpoint: &WorkerEndpoint) -> Result<WorkerStream, String> {
    match endpoint {
        #[cfg(unix)]
        WorkerEndpoint::Unix(path) => UnixStream::connect(path)
            .await
            .map(WorkerStream::Unix)
            .map_err(|e| format!("failed to connect to worker socket {}: {e}", path.display())),
        WorkerEndpoint::Tcp(addr) => TcpStream::connect(addr)
            .await
            .map(WorkerStream::Tcp)
            .map_err(|e| format!("failed to connect to worker tcp {addr}: {e}")),
    }
}

async fn write_post_request(
    stream: &mut WorkerStream,
    path: &str,
    token: &str,
    request_id: &str,
    body: &[u8],
) -> Result<(), String> {
    let head = format!(
        "POST {path} HTTP/1.1\r\n\
         Host: localhost\r\n\
         Content-Type: application/json\r\n\
         Content-Length: {}\r\n\
         X-Worker-Token: {token}\r\n\
         X-AI-Request-Id: {request_id}\r\n\
         Connection: close\r\n\r\n",
        body.len()
    );
    stream
        .write_all(head.as_bytes())
        .await
        .map_err(|e| format!("failed to send request headers to worker: {e}"))?;
    if !body.is_empty() {
        stream
            .write_all(body)
            .await
            .map_err(|e| format!("failed to send request body to worker: {e}"))?;
    }
    stream
        .flush()
        .await
        .map_err(|e| format!("failed to flush worker request: {e}"))?;
    Ok(())
}

async fn read_http_head(
    reader: &mut BufReader<WorkerStream>,
) -> Result<(u16, HashMap<String, String>), String> {
    let mut status_line = String::new();
    let n = reader
        .read_line(&mut status_line)
        .await
        .map_err(|e| format!("failed to read worker status line: {e}"))?;
    if n == 0 {
        return Err("worker closed connection before sending HTTP status".to_string());
    }
    let status = status_line
        .split_whitespace()
        .nth(1)
        .and_then(|code| code.parse::<u16>().ok())
        .ok_or_else(|| format!("invalid worker HTTP status line: {}", status_line.trim()))?;

    let mut headers = HashMap::new();
    loop {
        let mut line = String::new();
        let bytes = reader
            .read_line(&mut line)
            .await
            .map_err(|e| format!("failed to read worker header: {e}"))?;
        if bytes == 0 || line == "\r\n" || line == "\n" {
            break;
        }
        if let Some((k, v)) = line.split_once(':') {
            headers.insert(k.trim().to_ascii_lowercase(), v.trim().to_string());
        }
    }

    Ok((status, headers))
}

async fn read_http_body(
    reader: &mut BufReader<WorkerStream>,
    headers: &HashMap<String, String>,
) -> Result<Vec<u8>, String> {
    if let Some(len) = headers
        .get("content-length")
        .and_then(|v| v.parse::<usize>().ok())
    {
        let mut body = vec![0u8; len];
        reader
            .read_exact(&mut body)
            .await
            .map_err(|e| format!("failed to read {len} byte worker body: {e}"))?;
        return Ok(body);
    }
    let mut body = Vec::new();
    reader
        .read_to_end(&mut body)
        .await
        .map_err(|e| format!("failed to read worker body: {e}"))?;
    Ok(body)
}

pub async fn post_json(
    endpoint: &WorkerEndpoint,
    path: &str,
    token: &str,
    request_id: &str,
    body: &[u8],
) -> Result<WorkerHttpResponse, String> {
    let mut stream = connect_endpoint(endpoint).await?;
    write_post_request(&mut stream, path, token, request_id, body).await?;
    let mut reader = BufReader::new(stream);
    let (status, headers) = read_http_head(&mut reader).await?;
    let body = read_http_body(&mut reader, &headers).await?;
    Ok(WorkerHttpResponse {
        status,
        headers,
        body,
    })
}

pub async fn open_chat_stream(
    endpoint: &WorkerEndpoint,
    path: &str,
    token: &str,
    request_id: &str,
    body: &[u8],
) -> Result<WorkerNdjsonStream, (Option<u16>, String)> {
    let mut stream = connect_endpoint(endpoint)
        .await
        .map_err(|e| (None, e))?;
    write_post_request(&mut stream, path, token, request_id, body)
        .await
        .map_err(|e| (None, e))?;

    let mut reader = BufReader::new(stream);
    let (status, headers) = read_http_head(&mut reader).await.map_err(|e| (None, e))?;
    if !(200..300).contains(&status) {
        let err_body = read_http_body(&mut reader, &headers)
            .await
            .unwrap_or_default();
        let text = String::from_utf8_lossy(&err_body).to_string();
        return Err((Some(status), text));
    }

    Ok(WorkerNdjsonStream { reader })
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::UnixListener;
    use uuid::Uuid;

    #[tokio::test]
    async fn posts_json_and_reads_ndjson_stream_over_uds() {
        let sock_path = std::env::temp_dir().join(format!("acpm-wc-test-{}.sock", Uuid::new_v4()));
        let listener = UnixListener::bind(&sock_path).unwrap();
        let endpoint = WorkerEndpoint::Unix(sock_path.clone());

        let server = tokio::spawn(async move {
            for _ in 0..2 {
                let (mut conn, _) = listener.accept().await.unwrap();
                let mut buf = [0u8; 4096];
                let n = conn.read(&mut buf).await.unwrap();
                let req_str = String::from_utf8_lossy(&buf[..n]);
                if req_str.contains("/infer/asr") {
                    let body = br#"{"text":"ok","duration_ms":100,"segments":[]}"#;
                    let resp = format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        body.len()
                    );
                    conn.write_all(resp.as_bytes()).await.unwrap();
                    conn.write_all(body).await.unwrap();
                } else {
                    conn.write_all(
                        b"HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nConnection: close\r\n\r\n",
                    )
                    .await
                    .unwrap();
                    conn.write_all(b"{\"type\":\"start\",\"prompt_tokens\":10,\"kv_cache_hit\":false,\"prompt_starts_think\":true}\n")
                        .await
                        .unwrap();
                    conn.write_all(b"{\"type\":\"delta\",\"text\":\"hi\"}\n")
                        .await
                        .unwrap();
                }
            }
        });

        let res = post_json(&endpoint, "/infer/asr", "tok", "r1", br#"{"file_path":"x"}"#)
            .await
            .unwrap();
        assert_eq!(res.status, 200);
        assert!(String::from_utf8_lossy(&res.body).contains(r#""text":"ok""#));

        let mut stream = open_chat_stream(&endpoint, "/infer/chat", "tok", "r2", br#"{"stream":true}"#)
            .await
            .unwrap();
        assert!(stream.next_line().await.unwrap().unwrap().contains("\"start\""));
        assert!(stream.next_line().await.unwrap().unwrap().contains("\"delta\""));
        assert!(stream.next_line().await.unwrap().is_none());

        server.await.unwrap();
        let _ = std::fs::remove_file(&sock_path);
    }
}
