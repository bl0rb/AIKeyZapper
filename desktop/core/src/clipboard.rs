//! Copies a key marked as confidential, so clipboard managers and the clipboard history skip it,
//! and clears it after a while unless something else has been copied in the meantime.
//! macOS: `org.nspasteboard.ConcealedType`; Windows: `ExcludeClipboardContentFromMonitorProcessing`.

/// Puts `text` on the clipboard; returns a change marker for `clear_if_unchanged`.
pub fn copy_concealed(text: &str) -> Option<i64> {
    platform::copy_concealed(text)
}

/// Empties the clipboard if it still holds what `copy_concealed` put there.
pub fn clear_if_unchanged(marker: i64) {
    platform::clear_if_unchanged(marker)
}

#[cfg(target_os = "macos")]
mod platform {
    use objc2_app_kit::{NSPasteboard, NSPasteboardTypeString};
    use objc2_foundation::{NSArray, NSString};

    pub fn copy_concealed(text: &str) -> Option<i64> {
        unsafe {
            let pasteboard = NSPasteboard::generalPasteboard();
            let concealed = NSString::from_str("org.nspasteboard.ConcealedType");
            let types = NSArray::from_slice(&[NSPasteboardTypeString, &*concealed]);
            pasteboard.declareTypes_owner(&types, None);
            let ok = pasteboard.setString_forType(&NSString::from_str(text), NSPasteboardTypeString);
            pasteboard.setString_forType(&NSString::from_str(""), &concealed);
            ok.then(|| pasteboard.changeCount() as i64)
        }
    }

    pub fn clear_if_unchanged(marker: i64) {
        let pasteboard = NSPasteboard::generalPasteboard();
        if pasteboard.changeCount() as i64 == marker {
            pasteboard.clearContents();
        }
    }
}

#[cfg(windows)]
mod platform {
    use windows_sys::Win32::System::DataExchange::{
        CloseClipboard, EmptyClipboard, GetClipboardSequenceNumber, OpenClipboard, RegisterClipboardFormatW, SetClipboardData,
    };
    use windows_sys::Win32::Foundation::GlobalFree;
    use windows_sys::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE};

    const CF_UNICODETEXT: u32 = 13;

    fn wide(text: &str) -> Vec<u16> {
        text.encode_utf16().chain(std::iter::once(0)).collect()
    }

    /// Copies `bytes` into movable global memory and hands it to the open clipboard.
    unsafe fn set(format: u32, bytes: &[u8]) -> bool {
        let handle = GlobalAlloc(GMEM_MOVEABLE, bytes.len().max(1));
        if handle.is_null() {
            return false;
        }
        let target = GlobalLock(handle) as *mut u8;
        if target.is_null() {
            GlobalFree(handle);
            return false;
        }
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), target, bytes.len());
        GlobalUnlock(handle);
        if SetClipboardData(format, handle as _).is_null() {
            GlobalFree(handle);
            return false;
        }
        true
    }

    unsafe fn open() -> bool {
        for _ in 0..10 {
            if OpenClipboard(std::ptr::null_mut()) != 0 {
                return true;
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        false
    }

    pub fn copy_concealed(text: &str) -> Option<i64> {
        unsafe {
            if !open() {
                return None;
            }
            EmptyClipboard();
            let units = wide(text);
            let bytes = std::slice::from_raw_parts(units.as_ptr() as *const u8, units.len() * 2);
            let ok = set(CF_UNICODETEXT, bytes);
            let zero = 0u32.to_le_bytes();
            for name in ["ExcludeClipboardContentFromMonitorProcessing", "CanIncludeInClipboardHistory", "CanUploadToCloudClipboard"] {
                let format = RegisterClipboardFormatW(wide(name).as_ptr());
                if format != 0 {
                    set(format, &zero);
                }
            }
            CloseClipboard();
            ok.then(|| GetClipboardSequenceNumber() as i64)
        }
    }

    pub fn clear_if_unchanged(marker: i64) {
        unsafe {
            if GetClipboardSequenceNumber() as i64 == marker && open() {
                EmptyClipboard();
                CloseClipboard();
            }
        }
    }
}

#[cfg(not(any(target_os = "macos", windows)))]
mod platform {
    pub fn copy_concealed(_text: &str) -> Option<i64> {
        None
    }
    pub fn clear_if_unchanged(_marker: i64) {}
}
