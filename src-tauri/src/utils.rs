use crate::managers::audio::AudioRecordingManager;
use crate::managers::transcription::TranscriptionManager;
use crate::shortcut;
use crate::TranscriptionCoordinator;
use log::info;
use std::sync::Arc;
use tauri::{AppHandle, Manager};

// Re-export all utility modules for easy access
// pub use crate::audio_feedback::*;
pub use crate::clipboard::*;
pub use crate::overlay::*;
pub use crate::tray::*;

#[cfg(any(test, all(target_os = "windows", target_arch = "x86_64")))]
const IMAGE_FILE_MACHINE_ARM64: u16 = 0xaa64;

#[cfg(any(test, all(target_os = "windows", target_arch = "x86_64")))]
fn native_machine_is_arm64(native_machine: Option<u16>) -> bool {
    native_machine == Some(IMAGE_FILE_MACHINE_ARM64)
}

/// Whether this is the x64 Windows build running under emulation on Windows ARM64.
///
/// Only that exact process/host pairing disables the transcribe.cpp GPU path.
/// Detection is deliberately fail-open: a native x64 host, an older Windows
/// version without `IsWow64Process2`, or any API error leaves existing behavior
/// unchanged.
pub fn is_windows_x64_emulated_on_arm64() -> bool {
    #[cfg(all(target_os = "windows", target_arch = "x86_64"))]
    {
        use std::sync::OnceLock;

        static DETECTED: OnceLock<bool> = OnceLock::new();
        *DETECTED.get_or_init(|| native_machine_is_arm64(native_windows_machine()))
    }

    #[cfg(not(all(target_os = "windows", target_arch = "x86_64")))]
    {
        false
    }
}

#[cfg(all(target_os = "windows", target_arch = "x86_64"))]
fn native_windows_machine() -> Option<u16> {
    use windows::core::{s, w, BOOL};
    use windows::Win32::Foundation::HANDLE;
    use windows::Win32::System::LibraryLoader::{GetModuleHandleW, GetProcAddress};
    use windows::Win32::System::Threading::GetCurrentProcess;

    type IsWow64Process2 = unsafe extern "system" fn(HANDLE, *mut u16, *mut u16) -> BOOL;

    // Resolve IsWow64Process2 dynamically so merely starting Handy never raises
    // the minimum Windows version. Windows-on-ARM versions provide this API,
    // while a missing symbol or failed query safely preserves the x64 behavior.
    unsafe {
        let kernel32 = GetModuleHandleW(w!("kernel32.dll")).ok()?;
        let address = GetProcAddress(kernel32, s!("IsWow64Process2"))?;
        // SAFETY: GetProcAddress returned the documented IsWow64Process2 symbol;
        // function pointers have the same representation on supported Windows.
        let is_wow64_process2: IsWow64Process2 = std::mem::transmute(address);
        let mut process_machine = 0u16;
        let mut native_machine = 0u16;
        is_wow64_process2(
            GetCurrentProcess(),
            &mut process_machine,
            &mut native_machine,
        )
        .as_bool()
        .then_some(native_machine)
    }
}

/// Centralized cancellation function that can be called from anywhere in the app.
/// Handles cancelling both recording and transcription operations and updates UI state.
pub fn cancel_current_operation(app: &AppHandle) {
    info!("Initiating operation cancellation...");

    // Unregister the cancel shortcut asynchronously
    shortcut::unregister_cancel_shortcut(app);

    // Cancel any ongoing recording
    let audio_manager = app.state::<Arc<AudioRecordingManager>>();
    let recording_was_active = audio_manager.is_recording();
    audio_manager.cancel_recording();

    // Abandon any live streaming transcription
    let tm = app.state::<Arc<TranscriptionManager>>();
    tm.cancel_stream();

    // Update tray icon and hide overlay
    change_tray_icon(app, crate::tray::TrayIconState::Idle);
    hide_recording_overlay(app);

    // Unload model if immediate unload is enabled
    tm.maybe_unload_immediately("cancellation");

    // Notify coordinator so it can keep lifecycle state coherent.
    if let Some(coordinator) = app.try_state::<TranscriptionCoordinator>() {
        coordinator.notify_cancel(recording_was_active);
    }

    info!("Operation cancellation completed - returned to idle state");
}

/// Check if using the Wayland display server protocol
#[cfg(target_os = "linux")]
pub fn is_wayland() -> bool {
    std::env::var("WAYLAND_DISPLAY").is_ok()
        || std::env::var("XDG_SESSION_TYPE")
            .map(|v| v.to_lowercase() == "wayland")
            .unwrap_or(false)
}

/// Check if running on KDE Plasma desktop environment
#[cfg(target_os = "linux")]
pub fn is_kde_plasma() -> bool {
    std::env::var("XDG_CURRENT_DESKTOP")
        .map(|v| v.to_uppercase().contains("KDE"))
        .unwrap_or(false)
        || std::env::var("KDE_SESSION_VERSION").is_ok()
}

/// Check if running on KDE Plasma with Wayland
#[cfg(target_os = "linux")]
pub fn is_kde_wayland() -> bool {
    is_wayland() && is_kde_plasma()
}

/// Name of the frontmost application (the dictation target). Used for the
/// `${app}` post-processing prompt variable so prompts can adapt tone to the
/// target app.
#[cfg(target_os = "macos")]
pub fn frontmost_app_name() -> Option<String> {
    use objc2_app_kit::NSWorkspace;
    let workspace = NSWorkspace::sharedWorkspace();
    let app = workspace.frontmostApplication()?;
    app.localizedName().map(|name| name.to_string())
}

// ponytail: macOS only; Windows (GetForegroundWindow) / Linux when needed
#[cfg(not(target_os = "macos"))]
pub fn frontmost_app_name() -> Option<String> {
    None
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct PasteTargetIdentity {
    pub(crate) application: String,
    pub(crate) application_pid: i32,
    pub(crate) window: Option<String>,
    pub(crate) element: Option<String>,
}

impl PasteTargetIdentity {
    pub(crate) fn still_matches(&self, current: Option<&Self>) -> bool {
        let Some(current) = current else {
            return false;
        };
        self.application == current.application
            && self.application_pid == current.application_pid
            && self.window == current.window
            && self.element.is_some()
            && self.element == current.element
    }
}

#[cfg(target_os = "macos")]
fn copy_attr(
    el: &objc2_application_services::AXUIElement,
    name: &str,
) -> Option<objc2_core_foundation::CFRetained<objc2_core_foundation::CFType>> {
    use objc2_application_services::AXError;
    use objc2_core_foundation::{CFRetained, CFString, CFType};
    use std::ptr::NonNull;

    let attr = CFString::from_str(name);
    let mut value: *const CFType = std::ptr::null();
    let err = unsafe { el.copy_attribute_value(&attr, NonNull::from(&mut value)) };
    if err != AXError::Success {
        return None;
    }
    NonNull::new(value.cast_mut()).map(|v| unsafe { CFRetained::from_raw(v) })
}

#[cfg(target_os = "macos")]
fn as_text(v: objc2_core_foundation::CFRetained<objc2_core_foundation::CFType>) -> Option<String> {
    let s = v
        .downcast::<objc2_core_foundation::CFString>()
        .ok()?
        .to_string();
    if s.trim().is_empty() {
        None
    } else {
        Some(s)
    }
}

#[cfg(target_os = "macos")]
pub(crate) fn paste_target_identity() -> Option<PasteTargetIdentity> {
    use objc2_app_kit::NSWorkspace;
    use objc2_application_services::{AXUIElement, AXValue, AXValueType};
    use std::ffi::c_void;
    use std::ptr::NonNull;

    #[repr(C)]
    struct Pair {
        first: f64,
        second: f64,
    }

    fn value_pair(
        element: &AXUIElement,
        attribute: &str,
        value_type: AXValueType,
    ) -> Option<String> {
        let value = copy_attr(element, attribute)?.downcast::<AXValue>().ok()?;
        let mut pair = Pair {
            first: 0.0,
            second: 0.0,
        };
        let pointer = NonNull::new((&mut pair as *mut Pair).cast::<c_void>())?;
        unsafe { value.value(value_type, pointer) }
            .then(|| format!("{:.1},{:.1}", pair.first, pair.second))
    }

    let application = NSWorkspace::sharedWorkspace().frontmostApplication()?;
    let application_name = application.localizedName()?.to_string();
    let application_pid = application.processIdentifier();
    let app_element = unsafe { AXUIElement::new_application(application_pid) };
    let _ = unsafe { app_element.set_messaging_timeout(0.05) };
    let window = copy_attr(&app_element, "AXFocusedWindow")
        .and_then(|value| value.downcast::<AXUIElement>().ok());
    let window_title = window
        .as_ref()
        .and_then(|window| copy_attr(window, "AXTitle"))
        .and_then(as_text);

    let system = unsafe { AXUIElement::new_system_wide() };
    let focused = copy_attr(&system, "AXFocusedUIElement")
        .and_then(|value| value.downcast::<AXUIElement>().ok());
    let element = focused.as_ref().and_then(|focused| {
        copy_attr(focused, "AXIdentifier")
            .or_else(|| copy_attr(focused, "AXDOMIdentifier"))
            .and_then(as_text)
            .or_else(|| {
                // Many native text controls do not publish an identifier. Use
                // descriptive attributes plus geometry rather than treating a
                // missing identifier as a wildcard across every field.
                let mut attributes = ["AXRole", "AXSubrole", "AXTitle", "AXDescription"]
                    .into_iter()
                    .filter_map(|name| copy_attr(focused, name).and_then(as_text))
                    .collect::<Vec<_>>();
                if let Some(position) = value_pair(focused, "AXPosition", AXValueType::CGPoint) {
                    attributes.push(format!("position:{position}"));
                }
                if let Some(size) = value_pair(focused, "AXSize", AXValueType::CGSize) {
                    attributes.push(format!("size:{size}"));
                }
                (!attributes.is_empty()).then(|| attributes.join("|"))
            })
    });

    Some(PasteTargetIdentity {
        application: application_name,
        application_pid,
        window: window_title,
        element,
    })
}

#[cfg(not(target_os = "macos"))]
pub(crate) fn paste_target_identity() -> Option<PasteTargetIdentity> {
    None
}

/// Selected text and full text value of the focused UI element, read via the
/// Accessibility API. Uses the same TCC Accessibility grant the app already
/// requires for shortcuts; any failure (trust revoked, no focused element,
/// non-text element) yields None and callers fall back to the clipboard path.
#[cfg(target_os = "macos")]
pub fn ax_focused_texts() -> (Option<String>, Option<String>) {
    use objc2_application_services::AXUIElement;

    let system = unsafe { AXUIElement::new_system_wide() };
    let Some(focused) =
        copy_attr(&system, "AXFocusedUIElement").and_then(|v| v.downcast::<AXUIElement>().ok())
    else {
        return (None, None);
    };
    if copy_attr(&focused, "AXRole").and_then(as_text).as_deref() == Some("AXSecureTextField") {
        return (None, None);
    }
    let selected = copy_attr(&focused, "AXSelectedText").and_then(as_text);
    // ponytail: no size cap on the field value; truncate if giant text views
    // ever blow the LLM context
    let value = copy_attr(&focused, "AXValue").and_then(as_text);
    (selected, value)
}

#[cfg(target_os = "macos")]
pub(crate) fn ax_focused_context(max_chars: usize) -> Option<String> {
    use objc2_application_services::{AXUIElement, AXValue, AXValueType};
    use objc2_core_foundation::CFRange;
    use std::ffi::c_void;
    use std::ptr::NonNull;

    let system = unsafe { AXUIElement::new_system_wide() };
    let focused = copy_attr(&system, "AXFocusedUIElement")?
        .downcast::<AXUIElement>()
        .ok()?;
    if copy_attr(&focused, "AXRole").and_then(as_text).as_deref() == Some("AXSecureTextField") {
        return None;
    }
    let text = copy_attr(&focused, "AXValue").and_then(as_text)?;
    let selected_range = copy_attr(&focused, "AXSelectedTextRange")?
        .downcast::<AXValue>()
        .ok()?;
    let mut range = CFRange {
        location: 0,
        length: 0,
    };
    let pointer = NonNull::new((&mut range as *mut CFRange).cast::<c_void>())?;
    if !unsafe { selected_range.value(AXValueType::CFRange, pointer) } || range.location < 0 {
        return None;
    }

    let cursor_utf16 = (range.location + range.length.max(0)) as usize;
    let mut utf16_units = 0usize;
    let cursor_byte = text
        .char_indices()
        .find_map(|(byte, character)| {
            if utf16_units >= cursor_utf16 {
                Some(byte)
            } else {
                utf16_units += character.len_utf16();
                None
            }
        })
        .unwrap_or(text.len());
    let half = max_chars / 2;
    let before: String = text[..cursor_byte]
        .chars()
        .rev()
        .take(half)
        .collect::<String>()
        .chars()
        .rev()
        .collect();
    let after: String = text[cursor_byte..].chars().take(half).collect();
    Some(format!("{before}<cursor>{after}"))
}

#[cfg(not(target_os = "macos"))]
pub(crate) fn ax_focused_context(_max_chars: usize) -> Option<String> {
    None
}

#[cfg(not(target_os = "macos"))]
pub fn ax_focused_texts() -> (Option<String>, Option<String>) {
    (None, None) // ponytail: clipboard fallback covers other platforms
}

/// Last `max_chars` characters of `s`, char-boundary safe.
pub(crate) fn tail_chars(s: &str, max_chars: usize) -> &str {
    if max_chars == 0 {
        return "";
    }
    match s.char_indices().rev().nth(max_chars - 1) {
        Some((i, _)) => &s[i..],
        None => s, // fewer than max_chars chars
    }
}

/// Visible text of the frontmost app's focused window, gathered by walking its
/// Accessibility tree. Gives Command Mode conversation-level context (message
/// threads, terminal output) beyond the focused field. Best effort: any
/// failure yields None and commands behave as if no window text existed.
///
/// The walk visits children in REVERSE document order and collects each node's
/// value after its children, then reverses the pieces at the end — exact
/// pre-order output, but every cap (nodes, chars, deadline) trims the HEAD of
/// the window, never the tail, so "the last message" always survives.
#[cfg(target_os = "macos")]
pub fn ax_window_text(max_chars: usize) -> Option<String> {
    use objc2_app_kit::NSWorkspace;
    use objc2_application_services::AXUIElement;
    use objc2_core_foundation::{kCFBooleanTrue, CFArray, CFString};
    use std::time::{Duration, Instant};

    const MAX_DEPTH: usize = 40; // Chromium AX trees nest deep
    const MAX_NODES: usize = 2000; // belt; the deadline is the real time bound

    fn walk(
        el: &AXUIElement,
        depth: usize,
        nodes: &mut usize,
        chars: &mut usize,
        max_chars: usize,
        deadline: Instant,
        pieces: &mut Vec<String>,
    ) {
        if depth == 0 || *nodes == 0 || *chars >= max_chars || Instant::now() > deadline {
            return;
        }
        *nodes -= 1;
        if let Some(children) =
            copy_attr(el, "AXChildren").and_then(|v| v.downcast::<CFArray>().ok())
        {
            // Safety: AXChildren is documented to contain AXUIElements.
            let children = unsafe { children.cast_unchecked::<AXUIElement>() };
            for i in (0..children.len()).rev() {
                if let Some(child) = children.get(i) {
                    walk(&child, depth - 1, nodes, chars, max_chars, deadline, pieces);
                }
            }
        }
        if let Some(text) = copy_attr(el, "AXValue").and_then(as_text) {
            *chars += text.chars().count() + 1;
            pieces.push(text);
        } else if let Some(desc) = copy_attr(el, "AXDescription").and_then(as_text) {
            // Transcript views (e.g. Messages bubbles) expose their text via
            // AXDescription, not AXValue — including the sender's name. Take
            // it as a fallback, but skip control chrome whose descriptions
            // are UI labels ("Send", "emoji picker"), not content.
            let role = copy_attr(el, "AXRole")
                .and_then(as_text)
                .unwrap_or_default();
            let chrome = role.contains("Button")
                || role == "AXMenuItem"
                || role == "AXImage"
                || role == "AXToolbar";
            if !chrome {
                *chars += desc.chars().count() + 1;
                pieces.push(desc);
            }
        }
    }

    let started = Instant::now();
    let pid = NSWorkspace::sharedWorkspace()
        .frontmostApplication()?
        .processIdentifier();
    let app_el = unsafe { AXUIElement::new_application(pid) };
    // Bound each AX IPC call so a hung app can't stall the walk (default is 6s).
    let _ = unsafe { app_el.set_messaging_timeout(0.25) };
    // Best-effort: Electron/Chromium apps only build their AX tree when asked.
    if let Some(b) = unsafe { kCFBooleanTrue } {
        let err = unsafe {
            app_el.set_attribute_value(&CFString::from_str("AXManualAccessibility"), b.as_ref())
        };
        log::debug!("AXManualAccessibility set: {:?}", err);
    }
    let window = copy_attr(&app_el, "AXFocusedWindow")?
        .downcast::<AXUIElement>()
        .ok()?;

    let deadline = Instant::now() + Duration::from_millis(800);
    let mut pieces = Vec::new();
    let (mut nodes, mut chars) = (MAX_NODES, 0usize);
    walk(
        &window,
        MAX_DEPTH,
        &mut nodes,
        &mut chars,
        max_chars,
        deadline,
        &mut pieces,
    );
    if pieces.is_empty() {
        log::debug!("window text walk: empty after {:?}", started.elapsed());
        return None;
    }
    pieces.reverse();
    // Window title first: in chat apps the 1:1 window title IS the contact's
    // name, which instructions like "address them by name" depend on.
    if let Some(title) = copy_attr(&window, "AXTitle").and_then(as_text) {
        let app = frontmost_app_name().unwrap_or_default();
        pieces.insert(0, format!("[{} — {}]", app, title));
    }
    let joined = pieces.join("\n");
    let text = tail_chars(&joined, max_chars).to_string();
    log::debug!(
        "window text walk: {} chars in {:?} (nodes left {})",
        text.chars().count(),
        started.elapsed(),
        nodes
    );
    Some(text)
}

#[cfg(not(target_os = "macos"))]
pub fn ax_window_text(_max_chars: usize) -> Option<String> {
    None // ponytail: macOS only; UIA/AT-SPI walks if other platforms need it
}

#[cfg(test)]
mod tests {
    use super::{
        native_machine_is_arm64, tail_chars, PasteTargetIdentity, IMAGE_FILE_MACHINE_ARM64,
    };

    #[test]
    fn tail_chars_passthrough_and_truncation() {
        assert_eq!(tail_chars("hello", 10), "hello");
        assert_eq!(tail_chars("hello", 5), "hello");
        assert_eq!(tail_chars("hello world", 5), "world");
        assert_eq!(tail_chars("", 5), "");
    }

    #[test]
    fn tail_chars_respects_char_boundaries() {
        assert_eq!(tail_chars("日本語テスト", 3), "テスト");
        assert_eq!(tail_chars("aé😀b", 2), "😀b");
    }

    #[test]
    fn tail_chars_zero_is_empty() {
        assert_eq!(tail_chars("hello", 0), "");
    }

    #[test]
    fn arm64_native_machine_is_the_only_match() {
        assert!(native_machine_is_arm64(Some(IMAGE_FILE_MACHINE_ARM64)));
        assert!(!native_machine_is_arm64(Some(0x8664))); // AMD64
        assert!(!native_machine_is_arm64(Some(0x014c))); // I386
        assert!(!native_machine_is_arm64(None)); // API unavailable or failed
    }

    #[test]
    fn paste_target_checks_each_available_component() {
        let captured = PasteTargetIdentity {
            application: "Mail".to_string(),
            application_pid: 100,
            window: Some("Draft".to_string()),
            element: Some("body".to_string()),
        };
        assert!(captured.still_matches(Some(&captured)));

        for current in [
            PasteTargetIdentity {
                application: "Messages".to_string(),
                ..captured.clone()
            },
            PasteTargetIdentity {
                window: Some("Inbox".to_string()),
                ..captured.clone()
            },
            PasteTargetIdentity {
                element: Some("subject".to_string()),
                ..captured.clone()
            },
        ] {
            assert!(!captured.still_matches(Some(&current)));
        }
        assert!(!captured.still_matches(None));

        let unsupported = PasteTargetIdentity {
            element: None,
            ..captured
        };
        assert!(!unsupported.still_matches(Some(&unsupported)));
    }
}
