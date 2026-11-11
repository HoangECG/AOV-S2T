//! Rejects high-confidence channel-promotion boilerplate that Whisper can emit
//! when an audio window contains little or no intelligible speech.
//!
//! This deliberately uses combinations of phrases instead of a blacklist of
//! individual words. A real conversation can mention a `kênh` or a `video`, so
//! either word on its own must remain eligible for display.

const CHANNEL_CALL_TO_ACTIONS: &[&str] = &[
    "subscribe",
    "dang ky kenh",
    "nhan nut dang ky",
    "theo doi kenh",
    "bat chuong",
    "bat thong bao",
    "like va share",
];

const PROMOTION_CONTEXTS: &[&str] = &[
    "khong bo lo",
    "dung bo lo",
    "video hap dan",
    "video moi",
    "noi dung moi",
    "ung ho kenh",
    "ung ho minh",
    "nhan thong bao",
];

const DEFINITIVE_PROMOTION_PHRASES: &[&str] = &[
    "hay subscribe",
    "subscribe cho kenh",
    "hay dang ky kenh",
    "nhan nut dang ky",
    "hay theo doi kenh",
];

/// Returns `true` when `text` matches a generic channel-promotion template.
///
/// Matching is case-insensitive, whitespace-insensitive, and folds Vietnamese
/// diacritics. At least two independent signals are required: either one call
/// to action plus one promotional context, or two different calls to action.
/// This keeps ordinary sentences about a channel, video, or registration.
pub fn is_rejected_caption(text: &str) -> bool {
    let normalized = normalize_for_matching(text);
    if normalized.is_empty() {
        return false;
    }

    if matched_phrase_count(&normalized, DEFINITIVE_PROMOTION_PHRASES) > 0 {
        return true;
    }

    let call_to_action_count = matched_phrase_count(&normalized, CHANNEL_CALL_TO_ACTIONS);
    let has_promotion_context = matched_phrase_count(&normalized, PROMOTION_CONTEXTS) > 0;

    call_to_action_count >= 2 || (call_to_action_count >= 1 && has_promotion_context)
}

fn matched_phrase_count(text: &str, phrases: &[&str]) -> usize {
    let padded = format!(" {text} ");
    phrases
        .iter()
        .filter(|phrase| padded.contains(&format!(" {phrase} ")))
        .count()
}

fn normalize_for_matching(text: &str) -> String {
    let mut normalized = String::with_capacity(text.len());
    let mut needs_space = false;

    for character in text.chars() {
        for lowercased in character.to_lowercase() {
            if let Some(folded) = fold_vietnamese_character(lowercased) {
                if needs_space && !normalized.is_empty() {
                    normalized.push(' ');
                }
                normalized.push(folded);
                needs_space = false;
            } else if lowercased.is_ascii_alphanumeric() {
                if needs_space && !normalized.is_empty() {
                    normalized.push(' ');
                }
                normalized.push(lowercased);
                needs_space = false;
            } else if is_combining_diacritic(lowercased) {
                // A decomposed Vietnamese vowel is still part of the word.
            } else {
                needs_space = true;
            }
        }
    }

    normalized
}

fn fold_vietnamese_character(character: char) -> Option<char> {
    match character {
        'a' | 'à' | 'á' | 'ả' | 'ã' | 'ạ' | 'ă' | 'ằ' | 'ắ' | 'ẳ' | 'ẵ' | 'ặ' | 'â' | 'ầ' | 'ấ'
        | 'ẩ' | 'ẫ' | 'ậ' => Some('a'),
        'd' | 'đ' => Some('d'),
        'e' | 'è' | 'é' | 'ẻ' | 'ẽ' | 'ẹ' | 'ê' | 'ề' | 'ế' | 'ể' | 'ễ' | 'ệ' => {
            Some('e')
        }
        'i' | 'ì' | 'í' | 'ỉ' | 'ĩ' | 'ị' => Some('i'),
        'o' | 'ò' | 'ó' | 'ỏ' | 'õ' | 'ọ' | 'ô' | 'ồ' | 'ố' | 'ổ' | 'ỗ' | 'ộ' | 'ơ' | 'ờ' | 'ớ'
        | 'ở' | 'ỡ' | 'ợ' => Some('o'),
        'u' | 'ù' | 'ú' | 'ủ' | 'ũ' | 'ụ' | 'ư' | 'ừ' | 'ứ' | 'ử' | 'ữ' | 'ự' => {
            Some('u')
        }
        'y' | 'ỳ' | 'ý' | 'ỷ' | 'ỹ' | 'ỵ' => Some('y'),
        _ => None,
    }
}

fn is_combining_diacritic(character: char) -> bool {
    matches!(
        character,
        '\u{0300}'
            | '\u{0301}'
            | '\u{0303}'
            | '\u{0309}'
            | '\u{0323}'
            | '\u{0302}'
            | '\u{0306}'
            | '\u{031B}'
    )
}

#[cfg(test)]
mod tests {
    use super::is_rejected_caption;

    #[test]
    fn rejects_the_reported_channel_promotion_hallucination() {
        assert!(is_rejected_caption(
            "Hãy subscribe cho kênh Ghiền Mì Gõ Để không bỏ lỡ những video hấp dẫn"
        ));
    }

    #[test]
    fn rejects_case_whitespace_and_diacritic_variants() {
        assert!(is_rejected_caption(
            "  HAY  DANG KY KENH\nDE  KHONG BO LO  VIDEO MOI "
        ));
    }

    #[test]
    fn rejects_a_partial_subscribe_template_before_the_full_hallucination_arrives() {
        assert!(is_rejected_caption("Hãy subscribe cho kênh Ghiền Mì Gõ"));
    }

    #[test]
    fn rejects_two_independent_channel_calls_to_action() {
        assert!(is_rejected_caption(
            "Hãy đăng ký kênh và bật chuông để nhận thông báo."
        ));
    }

    #[test]
    fn allows_everyday_mentions_of_channels_videos_and_registration() {
        for text in [
            "Kênh này đang phát video có tiếng Việt.",
            "Tôi đã đăng ký kênh âm nhạc này rồi.",
            "Bạn có thể đăng ký lớp học này không?",
            "Tôi không muốn bỏ lỡ cuộc hẹn chiều nay.",
        ] {
            assert!(!is_rejected_caption(text), "unexpected rejection: {text}");
        }
    }
}
