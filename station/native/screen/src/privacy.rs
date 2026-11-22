// What an app that copied marked its copy, as Windows' clipboard managers and its history (Win+V) read it, and the
// same mark as still.fail's wires carry it (station/src/screens/source.ts `ClipPrivacy`: 1 concealed, 2 transient,
// 3 auto). Registered formats, their names compared without regard to case:
//   `Clipboard Viewer Ignore`                       present: transient (managers and viewers leave it be)
//   `ExcludeClipboardContentFromMonitorProcessing`  present: concealed (a password manager's)
//   `CanIncludeInClipboardHistory`                  a DWORD 0: concealed (kept out of Win+V); other values say nothing
//   `CanUploadToCloudClipboard`                     a DWORD 0 alone: not to the cloud, nothing more (no mark)
// A clip set with a mark is written with the formats that say it, each as 4 bytes of 0; `auto` has none on Windows.

pub const VIEWER_IGNORE: &str = "Clipboard Viewer Ignore";
pub const EXCLUDE_MONITOR: &str = "ExcludeClipboardContentFromMonitorProcessing";
pub const CAN_INCLUDE_HISTORY: &str = "CanIncludeInClipboardHistory";

pub const CONCEALED: u8 = 1;
pub const TRANSIENT: u8 = 2;
pub const AUTO: u8 = 3;

/// A message 4's flags: whether to paste (bit 0), and the clip's mark (bits 1..2).
pub fn flags(byte: u8) -> (bool, u8) {
    (byte & 1 == 1, (byte >> 1) & 3)
}

/// The mark the clipboard's registered formats say (each its name, and its data where it was read: the DWORDs'),
/// the strictest of them: transient, then concealed; 0 none.
pub fn mark_of(formats: &[(String, Option<Vec<u8>>)]) -> u8 {
    let has = |name: &str| formats.iter().find(|(n, _)| n.eq_ignore_ascii_case(name));
    if has(VIEWER_IGNORE).is_some() {
        return TRANSIENT;
    }
    if has(EXCLUDE_MONITOR).is_some() {
        return CONCEALED;
    }
    if let Some((_, Some(data))) = has(CAN_INCLUDE_HISTORY) {
        if data.len() >= 4 && u32::from_le_bytes([data[0], data[1], data[2], data[3]]) == 0 {
            return CONCEALED;
        }
    }
    0
}

/// The formats a mark is written as, each 4 bytes of 0.
pub fn formats_of(mark: u8) -> &'static [&'static str] {
    match mark {
        CONCEALED => &[EXCLUDE_MONITOR, CAN_INCLUDE_HISTORY],
        TRANSIENT => &[VIEWER_IGNORE],
        // (a program's own copy: Windows has no format that says it)
        AUTO => &[],
        _ => &[],
    }
}

/// The formats whose data `mark_of` reads (a DWORD's, never the content's).
pub fn read_data(name: &str) -> bool {
    name.eq_ignore_ascii_case(CAN_INCLUDE_HISTORY)
}

#[cfg(test)]
mod tests {
    use super::*;

    const CAN_UPLOAD_CLOUD: &str = "CanUploadToCloudClipboard";

    fn f(name: &str, data: Option<u32>) -> (String, Option<Vec<u8>>) {
        (name.to_string(), data.map(|d| d.to_le_bytes().to_vec()))
    }

    #[test]
    fn a_password_managers_copy_is_concealed() {
        assert_eq!(mark_of(&[f("HTML Format", None), f(EXCLUDE_MONITOR, None), f(CAN_INCLUDE_HISTORY, Some(0)), f(CAN_UPLOAD_CLOUD, Some(0))]), CONCEALED);
        assert_eq!(mark_of(&[f("canincludeinclipboardhistory", Some(0))]), CONCEALED);
        assert_eq!(mark_of(&[f("excludeclipboardcontentfrommonitorprocessing", None)]), CONCEALED);
    }

    #[test]
    fn a_copy_viewers_ignore_is_transient_whatever_else() {
        assert_eq!(mark_of(&[f(EXCLUDE_MONITOR, None), f("CLIPBOARD VIEWER IGNORE", None)]), TRANSIENT);
    }

    #[test]
    fn history_allowed_or_cloud_alone_is_no_mark() {
        assert_eq!(mark_of(&[f(CAN_INCLUDE_HISTORY, Some(1))]), 0);
        assert_eq!(mark_of(&[f(CAN_INCLUDE_HISTORY, None)]), 0);
        assert_eq!(mark_of(&[(CAN_INCLUDE_HISTORY.to_string(), Some(vec![0, 0]))]), 0);
        assert_eq!(mark_of(&[f(CAN_UPLOAD_CLOUD, Some(0))]), 0);
        assert_eq!(mark_of(&[]), 0);
    }

    #[test]
    fn a_mark_is_written_as_its_formats() {
        assert_eq!(formats_of(CONCEALED), &[EXCLUDE_MONITOR, CAN_INCLUDE_HISTORY]);
        assert_eq!(formats_of(TRANSIENT), &[VIEWER_IGNORE]);
        assert!(formats_of(AUTO).is_empty());
        assert!(formats_of(0).is_empty());
        // (and read back as it was written)
        let written: Vec<_> = formats_of(CONCEALED).iter().map(|n| f(n, Some(0))).collect();
        assert_eq!(mark_of(&written), CONCEALED);
    }

    #[test]
    fn a_sets_flags_say_paste_and_the_mark() {
        assert_eq!(flags(0), (false, 0));
        assert_eq!(flags(1), (true, 0));
        assert_eq!(flags(1 | (CONCEALED << 1)), (true, CONCEALED));
        assert_eq!(flags(TRANSIENT << 1), (false, TRANSIENT));
        assert_eq!(flags(0xff), (true, 3));
    }
}
