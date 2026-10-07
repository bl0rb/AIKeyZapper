//! JSON helpers for Claude settings files: strict check like Claude Code's `JSON.parse`, lenient reading
//! (trailing commas) so KeyZapper can still repair such files, sorted pretty output and dotted key paths.

use serde_json::{Map, Value};

pub type Object = Map<String, Value>;

/// Strict parse: the text is a JSON object for Claude Code (whitespace-only counts as empty object).
pub fn parse_strict(text: &str) -> Option<Object> {
    let text = text.trim_start_matches('\u{feff}');
    if text.trim().is_empty() {
        return Some(Object::new());
    }
    match serde_json::from_str::<Value>(text) {
        Ok(Value::Object(map)) => Some(map),
        _ => None,
    }
}

/// Lenient parse: also accepts trailing commas, which Claude Code rejects.
pub fn parse_lenient(text: &str) -> Option<Object> {
    parse_strict(text).or_else(|| parse_strict(&strip_trailing_commas(text)))
}

fn strip_trailing_commas(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let (mut in_string, mut escaped) = (false, false);
    for (i, &c) in chars.iter().enumerate() {
        if in_string {
            out.push(c);
            if escaped {
                escaped = false;
            } else if c == '\\' {
                escaped = true;
            } else if c == '"' {
                in_string = false;
            }
            continue;
        }
        if c == '"' {
            in_string = true;
        } else if c == ',' && matches!(chars[i + 1..].iter().find(|c| !c.is_whitespace()), Some('}' | ']')) {
            continue;
        }
        out.push(c);
    }
    out
}

fn sorted(value: &Value) -> Value {
    match value {
        Value::Object(map) => {
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort();
            Value::Object(keys.into_iter().map(|k| (k.clone(), sorted(&map[k]))).collect())
        }
        Value::Array(items) => Value::Array(items.iter().map(sorted).collect()),
        other => other.clone(),
    }
}

/// Pretty-printed with sorted keys and a final newline.
pub fn to_pretty_sorted(value: &Value) -> String {
    let mut text = serde_json::to_string_pretty(&sorted(value)).unwrap_or_default();
    text.push('\n');
    text
}

pub fn get<'a>(object: &'a Object, key_path: &str) -> Option<&'a Value> {
    match key_path.split_once('.') {
        Some((outer, inner)) => object.get(outer)?.as_object()?.get(inner),
        None => object.get(key_path),
    }
}

pub fn has(object: &Object, key_path: &str) -> bool {
    get(object, key_path).is_some()
}

pub fn get_str<'a>(object: &'a Object, key_path: &str) -> Option<&'a str> {
    get(object, key_path)?.as_str()
}

pub fn set(object: &mut Object, key_path: &str, value: &str) {
    match key_path.split_once('.') {
        Some((outer, inner)) => {
            let mut nested = object.get(outer).and_then(Value::as_object).cloned().unwrap_or_default();
            nested.insert(inner.to_string(), Value::String(value.to_string()));
            object.insert(outer.to_string(), Value::Object(nested));
        }
        None => {
            object.insert(key_path.to_string(), Value::String(value.to_string()));
        }
    }
}

pub fn remove(object: &mut Object, key_path: &str) {
    match key_path.split_once('.') {
        Some((outer, inner)) => {
            if let Some(Value::Object(nested)) = object.get_mut(outer) {
                nested.remove(inner);
            }
        }
        None => {
            object.remove(key_path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trailing_commas_are_only_accepted_leniently() {
        let text = r#"{ "a": [1, 2,], "b": "x,}", }"#;
        assert!(parse_strict(text).is_none());
        let parsed = parse_lenient(text).unwrap();
        assert_eq!(parsed["b"], "x,}");
        assert_eq!(parsed["a"].as_array().unwrap().len(), 2);
    }

    #[test]
    fn arrays_and_scalars_are_not_settings() {
        assert!(parse_strict("[]").is_none());
        assert!(parse_strict("null").is_none());
        assert_eq!(parse_strict("  \n").unwrap().len(), 0);
    }
}
