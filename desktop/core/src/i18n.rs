//! Localization: keys are the German source strings with `%@` placeholders, `locales/en.json` maps them to English.
//! German is used when the system language is German, English otherwise (like the macOS app).

use std::collections::HashMap;
use std::fmt::Display;
use std::sync::OnceLock;

const EN_JSON: &str = include_str!("../../locales/en.json");

/// The English table, shared with the web UI.
pub fn english() -> &'static HashMap<String, String> {
    static TABLE: OnceLock<HashMap<String, String>> = OnceLock::new();
    TABLE.get_or_init(|| serde_json::from_str(EN_JSON).unwrap_or_default())
}

/// `de` or `en`. `KEYZAPPER_LANG` overrides the system language (tests).
pub fn language() -> &'static str {
    static LANG: OnceLock<&'static str> = OnceLock::new();
    LANG.get_or_init(|| {
        let preferred = std::env::var("KEYZAPPER_LANG").ok().or_else(sys_locale::get_locale).unwrap_or_default();
        if preferred.to_lowercase().starts_with("de") { "de" } else { "en" }
    })
}

/// Translates `key` and fills its `%@` placeholders in order.
pub fn tr(key: &str, args: &[&dyn Display]) -> String {
    let text = if language() == "de" { key } else { english().get(key).map(String::as_str).unwrap_or(key) };
    let mut out = String::with_capacity(text.len());
    let mut args = args.iter();
    let mut rest = text;
    while let Some(i) = rest.find("%@") {
        out.push_str(&rest[..i]);
        match args.next() {
            Some(arg) => out.push_str(&arg.to_string()),
            None => out.push_str("%@"),
        }
        rest = &rest[i + 2..];
    }
    out.push_str(rest);
    out
}

/// `l!("Unbekanntes Profil: %@", id)`
#[macro_export]
macro_rules! l {
    ($key:expr) => { $crate::i18n::tr($key, &[]) };
    ($key:expr, $($arg:expr),+ $(,)?) => { $crate::i18n::tr($key, &[$(&$arg as &dyn ::std::fmt::Display),+]) };
}
