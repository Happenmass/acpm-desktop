#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MultipartField {
    pub name: String,
    pub filename: Option<String>,
    pub content_type: Option<String>,
    pub data: Vec<u8>,
}

pub fn extract_boundary(content_type: &str) -> Option<String> {
    for part in content_type.split(';') {
        let trimmed = part.trim();
        if let Some(rest) = trimmed.strip_prefix("boundary=").or_else(|| {
            if trimmed.len() >= 9 && trimmed[..9].eq_ignore_ascii_case("boundary=") {
                Some(&trimmed[9..])
            } else {
                None
            }
        }) {
            let cleaned = rest.trim().trim_matches('"');
            if !cleaned.is_empty() {
                return Some(cleaned.to_string());
            }
        }
    }
    None
}

pub fn parse_multipart(body: &[u8], boundary: &str) -> Result<Vec<MultipartField>, String> {
    if boundary.is_empty() {
        return Err("empty multipart boundary".to_string());
    }
    let delimiter = format!("--{boundary}").into_bytes();
    let mut fields = Vec::new();
    let mut search_pos = 0usize;

    let Some(first_rel) = find_bytes(&body[search_pos..], &delimiter) else {
        return Err("missing opening multipart boundary".to_string());
    };
    search_pos += first_rel + delimiter.len();

    loop {
        if body[search_pos..].starts_with(b"--") {
            break;
        }
        if body[search_pos..].starts_with(b"\r\n") {
            search_pos += 2;
        } else if body[search_pos..].starts_with(b"\n") {
            search_pos += 1;
        } else {
            return Err("malformed multipart delimiter line ending".to_string());
        }

        let Some(next_rel) = find_bytes(&body[search_pos..], &delimiter) else {
            break;
        };
        let mut part_end = search_pos + next_rel;
        if part_end >= search_pos + 2 && &body[part_end - 2..part_end] == b"\r\n" {
            part_end -= 2;
        } else if part_end >= search_pos + 1 && &body[part_end - 1..part_end] == b"\n" {
            part_end -= 1;
        }

        let part = &body[search_pos..part_end];
        if let Some((header_bytes, data_bytes)) = split_headers(part) {
            let header_str = String::from_utf8_lossy(header_bytes);
            let mut name = String::new();
            let mut filename = None;
            let mut content_type = None;

            for line in header_str.lines() {
                let line = line.trim_end_matches('\r');
                let lower = line.to_ascii_lowercase();
                if lower.starts_with("content-disposition:") {
                    name = extract_header_param(line, "name").unwrap_or_default();
                    filename = extract_header_param(line, "filename");
                } else if lower.starts_with("content-type:") {
                    content_type = line.split_once(':').map(|(_, v)| v.trim().to_string());
                }
            }

            if !name.is_empty() {
                fields.push(MultipartField {
                    name,
                    filename,
                    content_type,
                    data: data_bytes.to_vec(),
                });
            }
        }

        search_pos = search_pos + next_rel + delimiter.len();
    }

    Ok(fields)
}

fn find_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || needle.len() > haystack.len() {
        return None;
    }
    haystack.windows(needle.len()).position(|w| w == needle)
}

fn split_headers(part: &[u8]) -> Option<(&[u8], &[u8])> {
    if let Some(pos) = find_bytes(part, b"\r\n\r\n") {
        Some((&part[..pos], &part[pos + 4..]))
    } else if let Some(pos) = find_bytes(part, b"\n\n") {
        Some((&part[..pos], &part[pos + 2..]))
    } else {
        None
    }
}

fn extract_header_param(line: &str, key: &str) -> Option<String> {
    let needle = format!("{key}=\"");
    let idx = line.find(&needle)?;
    let rest = &line[idx + needle.len()..];
    let end = rest.find('"')?;
    Some(rest[..end].to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_text_and_binary_multipart_fields() {
        let ct = r#"multipart/form-data; boundary="----AcpmBoundary123""#;
        let boundary = extract_boundary(ct).unwrap();
        assert_eq!(boundary, "----AcpmBoundary123");

        let mut payload = Vec::new();
        payload.extend_from_slice(
            b"------AcpmBoundary123\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nqwen3-asr-1.7b\r\n",
        );
        payload.extend_from_slice(
            b"------AcpmBoundary123\r\nContent-Disposition: form-data; name=\"file\"; filename=\"clip.wav\"\r\nContent-Type: audio/wav\r\n\r\nRIFF\x00\x01\x02WAVE\r\n------AcpmBoundary123--\r\n",
        );

        let fields = parse_multipart(&payload, &boundary).unwrap();
        assert_eq!(fields.len(), 2);
        assert_eq!(fields[0].name, "model");
        assert_eq!(fields[0].data, b"qwen3-asr-1.7b");
        assert_eq!(fields[1].name, "file");
        assert_eq!(fields[1].filename.as_deref(), Some("clip.wav"));
        assert_eq!(fields[1].data, b"RIFF\x00\x01\x02WAVE");
    }
}
