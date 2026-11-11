//! Stabilizes transcript snapshots produced from overlapping live-audio windows.
//!
//! The filter deliberately does not alter words, casing, or diacritics. It only
//! normalizes whitespace, joins a verified suffix/prefix overlap, and waits for
//! compatible observations before appending uncertain words to the caption shown to users.

const MINIMUM_OVERLAP_WORDS: usize = 2;
const MAXIMUM_DISPLAY_WORDS: usize = 16;

/// Stateful filter for live-caption transcript snapshots.
///
/// [`Self::push`] returns `Some` only when the caller should replace the
/// displayed caption. The first observation of a new phrase is displayed
/// immediately so short utterances remain visible. Subsequent words are added
/// only after a compatible observation confirms their shared prefix. Call
/// [`Self::flush`] when speech has ended to retain a short final utterance.
#[derive(Debug, Default)]
pub struct LiveCaptionFilter {
    stable_history: String,
    displayed: String,
    pending: Option<String>,
}

impl LiveCaptionFilter {
    /// Submits a raw transcript and returns a stable caption when it changes.
    pub fn push(&mut self, transcript: &str) -> Option<String> {
        let incoming = normalize_caption_text(transcript);
        if incoming.is_empty() {
            self.pending = None;
            return None;
        }

        let base = self.pending.as_deref().unwrap_or(&self.stable_history);
        let candidate = merge_overlapping_caption(base, &incoming);

        if same_caption(&candidate, &self.stable_history) {
            return None;
        }

        let Some(pending) = self.pending.as_deref() else {
            self.pending = Some(candidate.clone());
            self.stable_history = candidate.clone();
            let caption = display_words(&candidate.split_whitespace().collect::<Vec<_>>());
            if same_caption(&caption, &self.displayed) {
                return None;
            }
            self.displayed = caption.clone();
            return Some(caption);
        };

        if !compatible_caption(&pending, &candidate) {
            self.pending = Some(candidate);
            return None;
        }

        let stable = common_caption_prefix(pending, &candidate);
        self.pending = Some(candidate);
        if same_caption(&stable, &self.stable_history) {
            return None;
        }

        let caption = next_display_line(&self.displayed, &self.stable_history, &stable);
        self.stable_history = stable;
        if same_caption(&caption, &self.displayed) {
            return None;
        }

        self.displayed = caption.clone();
        Some(caption)
    }

    /// Returns the last unconfirmed candidate when speech ends, then resets the session.
    pub fn flush(&mut self) -> Option<String> {
        let pending = self.pending.take()?;
        let caption = next_display_line(&self.displayed, &self.stable_history, &pending);
        let changed = !same_caption(&caption, &self.displayed);
        self.reset();
        changed.then_some(caption)
    }

    /// Clears retained transcript state after a pause or a new capture session.
    pub fn reset(&mut self) {
        self.stable_history.clear();
        self.displayed.clear();
        self.pending = None;
    }
}

/// Collapses Unicode whitespace and removes spaces before common punctuation.
pub fn normalize_caption_text(value: &str) -> String {
    let compact = value.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut normalized = String::with_capacity(compact.len());
    for character in compact.chars() {
        if matches!(character, ',' | '.' | '!' | '?' | ':' | ';') && normalized.ends_with(' ') {
            normalized.pop();
        }
        normalized.push(character);
    }
    normalized
}

fn merge_overlapping_caption(base: &str, incoming: &str) -> String {
    if base.is_empty() {
        return incoming.to_owned();
    }

    let base_key = comparison_key(base);
    let incoming_key = comparison_key(incoming);
    if base_key == incoming_key || base_key.starts_with(&incoming_key) {
        return base.to_owned();
    }
    if incoming_key.starts_with(&base_key) {
        return incoming.to_owned();
    }

    let base_words = base.split(' ').collect::<Vec<_>>();
    let incoming_words = incoming.split(' ').collect::<Vec<_>>();
    let base_keys = base_words
        .iter()
        .map(|word| comparison_key(word))
        .collect::<Vec<_>>();
    let incoming_keys = incoming_words
        .iter()
        .map(|word| comparison_key(word))
        .collect::<Vec<_>>();
    let maximum_overlap = base_words.len().min(incoming_words.len());

    for overlap in (MINIMUM_OVERLAP_WORDS..=maximum_overlap).rev() {
        if base_keys[base_keys.len() - overlap..] == incoming_keys[..overlap] {
            let mut merged = base.to_owned();
            for word in &incoming_words[overlap..] {
                merged.push(' ');
                merged.push_str(word);
            }
            return merged;
        }
    }

    incoming.to_owned()
}

fn compatible_caption(left: &str, right: &str) -> bool {
    let left_key = comparison_key(left);
    let right_key = comparison_key(right);
    left_key == right_key || left_key.starts_with(&right_key) || right_key.starts_with(&left_key)
}

fn common_caption_prefix(left: &str, right: &str) -> String {
    left.split_whitespace()
        .zip(right.split_whitespace())
        .take_while(|(left_word, right_word)| {
            comparison_key(left_word) == comparison_key(right_word)
        })
        .map(|(word, _)| word)
        .collect::<Vec<_>>()
        .join(" ")
}

fn same_caption(left: &str, right: &str) -> bool {
    comparison_key(left) == comparison_key(right)
}

fn comparison_key(value: &str) -> String {
    normalize_caption_text(value).to_lowercase()
}

fn next_display_line(current_line: &str, previous_history: &str, stable_history: &str) -> String {
    let stable_words = stable_history.split_whitespace().collect::<Vec<_>>();
    let added_words = words_after_prefix(previous_history, stable_history).unwrap_or(stable_words);

    if added_words.is_empty() {
        return current_line.to_owned();
    }

    let current_words = current_line.split_whitespace().collect::<Vec<_>>();
    if current_words.is_empty() || current_words.len() + added_words.len() > MAXIMUM_DISPLAY_WORDS {
        return display_words(&added_words);
    }

    let mut line = current_words;
    line.extend(added_words);
    display_words(&line)
}

fn words_after_prefix<'a>(prefix: &str, caption: &'a str) -> Option<Vec<&'a str>> {
    let prefix_words = prefix.split_whitespace().collect::<Vec<_>>();
    let caption_words = caption.split_whitespace().collect::<Vec<_>>();
    if prefix_words.len() > caption_words.len()
        || prefix_words
            .iter()
            .zip(&caption_words)
            .any(|(left, right)| comparison_key(left) != comparison_key(right))
    {
        return None;
    }

    Some(caption_words[prefix_words.len()..].to_vec())
}

fn display_words(words: &[&str]) -> String {
    let start = words.len().saturating_sub(MAXIMUM_DISPLAY_WORDS);
    words[start..].join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_whitespace_without_changing_vietnamese_text() {
        assert_eq!(
            normalize_caption_text("  Tôi\n thích\t tiếng Việt ,  bạn  "),
            "Tôi thích tiếng Việt, bạn"
        );
    }

    #[test]
    fn displays_the_first_recognized_phrase_immediately() {
        let mut filter = LiveCaptionFilter::default();

        assert_eq!(
            filter.push("  Xin chào Việt Nam  "),
            Some("Xin chào Việt Nam".to_owned())
        );
        assert_eq!(filter.push("xin chào việt nam"), None);
    }

    #[test]
    fn holds_an_extension_until_the_next_compatible_result() {
        let mut filter = LiveCaptionFilter::default();

        assert_eq!(
            filter.push("Xin chào mọi người"),
            Some("Xin chào mọi người".to_owned())
        );
        assert_eq!(filter.push("Xin chào mọi người hôm nay"), None);
        assert_eq!(
            filter.push("Xin chào mọi người hôm nay"),
            Some("Xin chào mọi người hôm nay".to_owned())
        );
    }

    #[test]
    fn joins_rolling_window_overlap_without_repeating_words() {
        let mut filter = LiveCaptionFilter::default();

        assert_eq!(
            filter.push("Xin chào mọi người"),
            Some("Xin chào mọi người".to_owned())
        );
        assert_eq!(filter.push("Xin chào mọi người"), None);

        assert_eq!(filter.push("mọi người hôm nay"), None);
        assert_eq!(
            filter.push("người hôm nay chúng ta"),
            Some("Xin chào mọi người hôm nay".to_owned())
        );
        assert_eq!(
            filter.push("người hôm nay chúng ta"),
            Some("Xin chào mọi người hôm nay chúng ta".to_owned())
        );
    }

    #[test]
    fn reset_prevents_a_later_utterance_from_being_merged() {
        let mut filter = LiveCaptionFilter::default();
        assert!(filter.push("Câu đầu tiên").is_some());
        assert!(filter.push("Câu đầu tiên").is_none());

        filter.reset();

        assert_eq!(
            filter.push("Câu tiếp theo"),
            Some("Câu tiếp theo".to_owned())
        );
        assert!(filter.push("Câu tiếp theo").is_none());
    }

    #[test]
    fn flushes_a_short_final_utterance() {
        let mut filter = LiveCaptionFilter::default();

        assert_eq!(filter.push("Dạ vâng"), Some("Dạ vâng".to_owned()));
        assert_eq!(filter.flush(), None);
        assert!(filter.displayed.is_empty());
    }

    #[test]
    fn starts_a_new_overlay_line_after_sixteen_words() {
        let transcript = (1..=34)
            .map(|index| format!("từ{index}"))
            .collect::<Vec<_>>()
            .join(" ");
        let expected = (19..=34)
            .map(|index| format!("từ{index}"))
            .collect::<Vec<_>>()
            .join(" ");
        let mut filter = LiveCaptionFilter::default();

        assert_eq!(filter.push(&transcript), Some(expected));
        assert_eq!(filter.push(&transcript), None);
    }

    #[test]
    fn replaces_a_full_line_with_only_the_new_words() {
        let first = (1..=14)
            .map(|index| format!("từ{index}"))
            .collect::<Vec<_>>()
            .join(" ");
        let expanded = (1..=17)
            .map(|index| format!("từ{index}"))
            .collect::<Vec<_>>()
            .join(" ");
        let mut filter = LiveCaptionFilter::default();

        assert_eq!(filter.push(&first), Some(first.clone()));
        assert_eq!(filter.push(&first), None);
        assert!(filter.push(&expanded).is_none());
        assert_eq!(filter.push(&expanded), Some("từ15 từ16 từ17".to_owned()));
    }
}
