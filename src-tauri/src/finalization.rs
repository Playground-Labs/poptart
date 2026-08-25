use serde::{Deserialize, Serialize};
use specta::Type;
use std::collections::HashSet;

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize, Type)]
#[serde(rename_all = "lowercase")]
/// Strength of automatic cleanup applied to ordinary dictation.
pub enum CleanupLevel {
    /// Paste the transcript without model cleanup.
    Off,
    /// Correct transcription errors and abandoned speech conservatively.
    #[default]
    Light,
    /// Permit broader clarity and structure edits while preserving meaning.
    Polish,
}

impl CleanupLevel {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::Light => "light",
            Self::Polish => "polish",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize, Type)]
#[serde(rename_all = "snake_case")]
pub(crate) enum CleanupFallback {
    Timeout,
    ProviderError,
    InvalidOutput,
    UnsafeOutput,
    Cancelled,
    TargetChanged,
}

impl CleanupFallback {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Timeout => "timeout",
            Self::ProviderError => "provider_error",
            Self::InvalidOutput => "invalid_output",
            Self::UnsafeOutput => "unsafe_output",
            Self::Cancelled => "cancelled",
            Self::TargetChanged => "target_changed",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct CleanupEdit {
    pub(crate) kind: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct CleanupResult {
    pub(crate) text: String,
    pub(crate) edits: Vec<CleanupEdit>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) enum CleanupOutcome {
    NotRequested,
    Applied(CleanupResult),
    Failed(CleanupFallback),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct FinalizedTranscript {
    pub(crate) raw_text: String,
    pub(crate) final_text: String,
    pub(crate) processed_text: Option<String>,
    pub(crate) edits: Vec<CleanupEdit>,
    pub(crate) changed: bool,
    pub(crate) fallback: Option<CleanupFallback>,
    pub(crate) requested_level: CleanupLevel,
    pub(crate) applied_level: Option<CleanupLevel>,
    pub(crate) cleanup_ms: Option<u64>,
    pub(crate) total_ms: u64,
    pub(crate) paste_permitted: bool,
}

pub(crate) fn finalize_transcript(
    raw_text: &str,
    normalized_text: String,
    cleanup: CleanupOutcome,
    requested_level: CleanupLevel,
    cleanup_ms: Option<u64>,
    total_ms: u64,
    paste_permitted: bool,
) -> FinalizedTranscript {
    let (final_text, processed_text, edits, fallback, applied_level) = match cleanup {
        CleanupOutcome::NotRequested => {
            let processed = (normalized_text != raw_text).then(|| normalized_text.clone());
            (normalized_text, processed, Vec::new(), None, None)
        }
        CleanupOutcome::Applied(result) => (
            result.text.clone(),
            Some(result.text),
            result.edits,
            None,
            Some(requested_level),
        ),
        CleanupOutcome::Failed(reason) => {
            (raw_text.to_string(), None, Vec::new(), Some(reason), None)
        }
    };
    let changed = final_text != raw_text;

    FinalizedTranscript {
        raw_text: raw_text.to_string(),
        final_text,
        processed_text,
        edits,
        changed,
        fallback,
        requested_level,
        applied_level,
        cleanup_ms,
        total_ms,
        paste_permitted,
    }
}

/// Reject cleanup output that could destroy a valid dictation. Light cleanup is
/// deliberately conservative: it may remove words and make a small number of
/// spelling corrections, but it cannot add new identifiers or substantially
/// expand the utterance. Polish permits broader rewriting while retaining the
/// same high-risk value checks.
pub(crate) fn validate_cleanup_output(
    source: &str,
    output: &str,
    level: CleanupLevel,
) -> Result<(), CleanupFallback> {
    if !source.trim().is_empty() && output.trim().is_empty() {
        return Err(CleanupFallback::InvalidOutput);
    }
    if output.contains("<transcript>") || output.contains("</transcript>") {
        return Err(CleanupFallback::UnsafeOutput);
    }

    let source_lower = source.to_lowercase();
    for token in output.split_whitespace() {
        let normalized = token
            .trim_matches(|character: char| {
                !character.is_alphanumeric() && !matches!(character, '@' | '.' | ':' | '/')
            })
            .to_lowercase();
        let is_url = normalized.starts_with("http://")
            || normalized.starts_with("https://")
            || normalized.starts_with("www.");
        let is_email = normalized.contains('@') && normalized.contains('.');
        if (is_url || is_email) && !source_lower.contains(&normalized) {
            return Err(CleanupFallback::UnsafeOutput);
        }
    }

    let source_has_digits = source.chars().any(|character| character.is_ascii_digit());
    let source_has_number_word = source
        .split(|character: char| !character.is_alphabetic())
        .any(|word| {
            matches!(
                word.to_ascii_lowercase().as_str(),
                "zero"
                    | "one"
                    | "two"
                    | "three"
                    | "four"
                    | "five"
                    | "six"
                    | "seven"
                    | "eight"
                    | "nine"
                    | "ten"
                    | "eleven"
                    | "twelve"
                    | "thirteen"
                    | "fourteen"
                    | "fifteen"
                    | "sixteen"
                    | "seventeen"
                    | "eighteen"
                    | "nineteen"
                    | "twenty"
                    | "thirty"
                    | "forty"
                    | "fifty"
                    | "sixty"
                    | "seventy"
                    | "eighty"
                    | "ninety"
                    | "hundred"
                    | "thousand"
            )
        });
    if output.chars().any(|character| character.is_ascii_digit())
        && !source_has_digits
        && !source_has_number_word
    {
        return Err(CleanupFallback::UnsafeOutput);
    }

    let expansion_allowance = match level {
        CleanupLevel::Off => 0,
        CleanupLevel::Light => source.len() / 3 + 48,
        CleanupLevel::Polish => source.len() / 2 + 96,
    };
    if output.len() > source.len().saturating_add(expansion_allowance) {
        return Err(CleanupFallback::UnsafeOutput);
    }

    if level == CleanupLevel::Light {
        let source_words: HashSet<String> = source
            .split(|character: char| !character.is_alphanumeric())
            .filter(|word| word.len() > 2)
            .map(str::to_ascii_lowercase)
            .collect();
        let added_words: HashSet<String> = output
            .split(|character: char| !character.is_alphanumeric())
            .filter(|word| word.len() > 2)
            .map(str::to_ascii_lowercase)
            .filter(|word| !source_words.contains(word))
            .collect();
        let allowance = (source_words.len() / 8).max(2);
        if added_words.len() > allowance {
            return Err(CleanupFallback::UnsafeOutput);
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{
        finalize_transcript, validate_cleanup_output, CleanupFallback, CleanupLevel,
        CleanupOutcome, CleanupResult,
    };

    fn applied(text: &str) -> CleanupOutcome {
        CleanupOutcome::Applied(CleanupResult {
            text: text.to_string(),
            edits: Vec::new(),
        })
    }

    #[test]
    fn finalization_uses_applied_cleanup_and_preserves_raw_text() {
        let result = finalize_transcript(
            "Let's meet Friday, no, Monday",
            "Let's meet Friday, no, Monday.".to_string(),
            applied("Let's meet Monday."),
            CleanupLevel::Light,
            Some(84),
            91,
            true,
        );

        assert_eq!(result.raw_text, "Let's meet Friday, no, Monday");
        assert_eq!(result.final_text, "Let's meet Monday.");
        assert_eq!(result.processed_text.as_deref(), Some("Let's meet Monday."));
        assert!(result.changed);
        assert_eq!(result.fallback, None);
        assert_eq!(result.requested_level, CleanupLevel::Light);
        assert_eq!(result.applied_level, Some(CleanupLevel::Light));
        assert_eq!(result.cleanup_ms, Some(84));
        assert!(result.paste_permitted);
    }

    #[test]
    fn finalization_falls_back_to_raw_text_after_cleanup_failure() {
        let result = finalize_transcript(
            "raw text",
            "Normalized text.".to_string(),
            CleanupOutcome::Failed(super::CleanupFallback::ProviderError),
            CleanupLevel::Light,
            Some(25),
            31,
            true,
        );

        assert_eq!(result.raw_text, "raw text");
        assert_eq!(result.final_text, "raw text");
        assert_eq!(result.processed_text, None);
        assert!(!result.changed);
        assert_eq!(result.fallback, Some(super::CleanupFallback::ProviderError));
    }

    #[test]
    fn finalization_keeps_normalized_text_when_cleanup_is_not_requested() {
        let result = finalize_transcript(
            "Already final.",
            "Already final.".to_string(),
            CleanupOutcome::NotRequested,
            CleanupLevel::Off,
            None,
            3,
            true,
        );

        assert_eq!(result.final_text, "Already final.");
        assert_eq!(result.processed_text, None);
        assert!(!result.changed);
        assert_eq!(result.fallback, None);
    }

    #[test]
    fn deterministic_normalization_is_recorded_as_processed_text() {
        let result = finalize_transcript(
            "简体字",
            "簡體字".to_string(),
            CleanupOutcome::NotRequested,
            CleanupLevel::Off,
            None,
            2,
            true,
        );

        assert_eq!(result.final_text, "簡體字");
        assert_eq!(result.processed_text.as_deref(), Some("簡體字"));
        assert!(result.changed);
    }

    #[test]
    fn light_cleanup_accepts_a_clear_backtrack_subset() {
        assert_eq!(
            validate_cleanup_output(
                "Let's meet Friday, no, Monday.",
                "Let's meet Monday.",
                CleanupLevel::Light,
            ),
            Ok(())
        );
    }

    #[test]
    fn nonblank_transcript_cannot_be_replaced_with_blank_output() {
        assert_eq!(
            validate_cleanup_output("Keep this", "  ", CleanupLevel::Light),
            Err(CleanupFallback::InvalidOutput)
        );
    }

    #[test]
    fn light_cleanup_rejects_unjustified_urls_and_numbers() {
        assert_eq!(
            validate_cleanup_output(
                "Send the summary",
                "Send the summary to https://example.com with code 4729",
                CleanupLevel::Light,
            ),
            Err(CleanupFallback::UnsafeOutput)
        );
    }

    #[test]
    fn target_change_can_disable_paste_without_losing_generated_text() {
        let result = finalize_transcript(
            "Friday, no, Monday",
            "Friday, no, Monday".to_string(),
            applied("Monday"),
            CleanupLevel::Light,
            Some(10),
            12,
            false,
        );

        assert_eq!(result.final_text, "Monday");
        assert!(!result.paste_permitted);
    }
}
