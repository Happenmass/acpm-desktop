const OPEN_TAG: &str = "<think>";
const CLOSE_TAG: &str = "</think>";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CotChunk {
    Reasoning(String),
    Content(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SplitPhase {
    DetectingStart,
    InThink,
    TrimAfterThink,
    InContent,
}

/// Streaming parser that splits `<think>...</think>` blocks emitted by local CoT models
/// into `Reasoning` and `Content` deltas across arbitrary chunk boundaries.
#[derive(Debug, Clone)]
pub struct CotStreamSplitter {
    enabled: bool,
    phase: SplitPhase,
    buffer: String,
}

impl CotStreamSplitter {
    pub fn new(enabled: bool) -> Self {
        Self::new_with_initial_think(enabled, false)
    }

    /// Creates a splitter where `starts_in_think = true` handles chat templates
    /// (such as Qwen3.5) that prefill `<think>\n` inside the prompt before generation.
    pub fn new_with_initial_think(enabled: bool, starts_in_think: bool) -> Self {
        let phase = if !enabled {
            SplitPhase::InContent
        } else if starts_in_think {
            SplitPhase::InThink
        } else {
            SplitPhase::DetectingStart
        };
        Self {
            enabled,
            phase,
            buffer: String::new(),
        }
    }

    pub fn push(&mut self, delta: &str) -> Vec<CotChunk> {
        if delta.is_empty() {
            return Vec::new();
        }
        if !self.enabled {
            return vec![CotChunk::Content(delta.to_string())];
        }

        let mut out = Vec::new();
        self.buffer.push_str(delta);

        loop {
            match self.phase {
                SplitPhase::DetectingStart => {
                    let trimmed = self.buffer.trim_start();
                    if trimmed.is_empty() {
                        break;
                    }
                    if trimmed.starts_with(OPEN_TAG) {
                        let start_idx = self.buffer.len() - trimmed.len() + OPEN_TAG.len();
                        let rest = self.buffer[start_idx..].to_string();
                        self.buffer = rest;
                        self.phase = SplitPhase::InThink;
                        continue;
                    }
                    if OPEN_TAG.starts_with(trimmed) {
                        // Still could become `<think>` on the next token chunk.
                        break;
                    }
                    // Definitely no leading `<think>` block; flush everything as regular content.
                    self.phase = SplitPhase::InContent;
                    let text = std::mem::take(&mut self.buffer);
                    Self::push_chunk(&mut out, CotChunk::Content(text));
                    break;
                }
                SplitPhase::InThink => {
                    if let Some(close_pos) = self.buffer.find(CLOSE_TAG) {
                        let reasoning = self.buffer[..close_pos].to_string();
                        Self::push_chunk(&mut out, CotChunk::Reasoning(reasoning));
                        self.buffer = self.buffer[close_pos + CLOSE_TAG.len()..].to_string();
                        self.phase = SplitPhase::TrimAfterThink;
                        continue;
                    }
                    let keep_tail = longest_tag_prefix_suffix(&self.buffer, CLOSE_TAG);
                    let emit_len = self.buffer.len() - keep_tail;
                    if emit_len > 0 {
                        let reasoning = self.buffer[..emit_len].to_string();
                        self.buffer = self.buffer[emit_len..].to_string();
                        Self::push_chunk(&mut out, CotChunk::Reasoning(reasoning));
                    }
                    break;
                }
                SplitPhase::TrimAfterThink => {
                    let trimmed = self.buffer.trim_start();
                    if trimmed.is_empty() {
                        self.buffer.clear();
                        break;
                    }
                    let rest = trimmed.to_string();
                    self.buffer.clear();
                    self.phase = SplitPhase::InContent;
                    Self::push_chunk(&mut out, CotChunk::Content(rest));
                    break;
                }
                SplitPhase::InContent => {
                    if !self.buffer.is_empty() {
                        let text = std::mem::take(&mut self.buffer);
                        Self::push_chunk(&mut out, CotChunk::Content(text));
                    }
                    break;
                }
            }
        }

        out
    }

    pub fn finish(&mut self) -> Vec<CotChunk> {
        if self.buffer.is_empty() {
            return Vec::new();
        }
        let leftover = std::mem::take(&mut self.buffer);
        match self.phase {
            SplitPhase::InThink => vec![CotChunk::Reasoning(leftover)],
            SplitPhase::TrimAfterThink => {
                let trimmed = leftover.trim_start();
                if trimmed.is_empty() {
                    Vec::new()
                } else {
                    vec![CotChunk::Content(trimmed.to_string())]
                }
            }
            SplitPhase::DetectingStart | SplitPhase::InContent => vec![CotChunk::Content(leftover)],
        }
    }

    fn push_chunk(out: &mut Vec<CotChunk>, chunk: CotChunk) {
        let is_empty = match &chunk {
            CotChunk::Reasoning(s) | CotChunk::Content(s) => s.is_empty(),
        };
        if is_empty {
            return;
        }
        match (out.last_mut(), &chunk) {
            (Some(CotChunk::Reasoning(prev)), CotChunk::Reasoning(next)) => prev.push_str(next),
            (Some(CotChunk::Content(prev)), CotChunk::Content(next)) => prev.push_str(next),
            _ => out.push(chunk),
        }
    }
}

fn longest_tag_prefix_suffix(haystack: &str, tag: &str) -> usize {
    let max_check = haystack.len().min(tag.len().saturating_sub(1));
    for len in (1..=max_check).rev() {
        let start = haystack.len() - len;
        if haystack.is_char_boundary(start) && tag.starts_with(&haystack[start..]) {
            return len;
        }
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn collect_all(chunks: Vec<&str>, enabled: bool) -> (String, String) {
        let mut splitter = CotStreamSplitter::new(enabled);
        let mut reasoning = String::new();
        let mut content = String::new();
        for piece in chunks {
            for item in splitter.push(piece) {
                match item {
                    CotChunk::Reasoning(r) => reasoning.push_str(&r),
                    CotChunk::Content(c) => content.push_str(&c),
                }
            }
        }
        for item in splitter.finish() {
            match item {
                CotChunk::Reasoning(r) => reasoning.push_str(&r),
                CotChunk::Content(c) => content.push_str(&c),
            }
        }
        (reasoning, content)
    }

    #[test]
    fn splits_single_shot_think_block() {
        let (r, c) = collect_all(vec!["<think>北静应为北京</think>\n明天去北京出差。"], true);
        assert_eq!(r, "北静应为北京");
        assert_eq!(c, "明天去北京出差。");
    }

    #[test]
    fn splits_tags_across_arbitrary_token_boundaries() {
        let full = "  \n<thi" ;
        let tokens = vec![full, "nk>分析", "3 < 5 且", "北静</th", "ink>\n\n", "明天去北京。"];
        let (r, c) = collect_all(tokens, true);
        assert_eq!(r, "分析3 < 5 且北静");
        assert_eq!(c, "明天去北京。");
    }

    #[test]
    fn passes_through_plain_content_without_think_tag() {
        let tokens = vec!["明", "天去北京。"];
        let (r, c) = collect_all(tokens, true);
        assert!(r.is_empty());
        assert_eq!(c, "明天去北京。");
    }

    #[test]
    fn respects_disabled_cot_splitting() {
        let (r, c) = collect_all(vec!["<think>abc</think>xyz"], false);
        assert!(r.is_empty());
        assert_eq!(c, "<think>abc</think>xyz");
    }

    #[test]
    fn flushes_unclosed_think_block_on_stream_end() {
        let (r, c) = collect_all(vec!["<think>partial reasoning</thi"], true);
        assert_eq!(r, "partial reasoning</thi");
        assert!(c.is_empty());
    }

    #[test]
    fn splits_prefilled_think_block_without_opening_tag() {
        let mut splitter = CotStreamSplitter::new_with_initial_think(true, true);
        let mut reasoning = String::new();
        let mut content = String::new();
        for piece in ["北静应为北京\n", "</th", "ink>\n\n", "明天去北京出差。"] {
            for item in splitter.push(piece) {
                match item {
                    CotChunk::Reasoning(r) => reasoning.push_str(&r),
                    CotChunk::Content(c) => content.push_str(&c),
                }
            }
        }
        for item in splitter.finish() {
            match item {
                CotChunk::Reasoning(r) => reasoning.push_str(&r),
                CotChunk::Content(c) => content.push_str(&c),
            }
        }
        assert_eq!(reasoning, "北静应为北京\n");
        assert_eq!(content, "明天去北京出差。");
    }
}
