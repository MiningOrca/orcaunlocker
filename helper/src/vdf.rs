use steam_vdf_parser::{Obj, Value};

/// Returns the value for the first key matching `key` case-insensitively.
pub(crate) fn object_value_ci<'a, 'text>(
    root: &'a Obj<'text>,
    key: &str,
) -> Option<&'a Value<'text>> {
    root.iter()
        .find_map(|(candidate, value)| candidate.eq_ignore_ascii_case(key).then_some(value))
}

/// Returns the string for the first key matching `key` case-insensitively.
pub(crate) fn object_string_ci(root: &Obj<'_>, key: &str) -> Option<String> {
    object_value_ci(root, key)?
        .as_str()
        .map(str::trim)
        .map(str::to_owned)
}

/// Returns the first object stored under a key matching `key` case-insensitively.
/// Matching keys whose values are not objects are skipped.
pub(crate) fn object_obj_ci<'a, 'text>(
    root: &'a Obj<'text>,
    key: &str,
) -> Option<&'a Obj<'text>> {
    root.iter().find_map(|(candidate, value)| {
        if candidate.eq_ignore_ascii_case(key) {
            value.as_obj()
        } else {
            None
        }
    })
}

/// Returns the object stored under the decimal string representation of `key`.
pub(crate) fn object_u32_key<'a, 'text>(
    root: &'a Obj<'text>,
    key: u32,
) -> Option<&'a Obj<'text>> {
    let key = key.to_string();
    root.get(key.as_str()).and_then(|value| value.as_obj())
}

/// Decodes a VDF scalar as an unsigned 32-bit integer.
pub(crate) fn value_u32(value: &Value<'_>) -> Option<u32> {
    if let Some(value) = value.as_i32() {
        return u32::try_from(value).ok();
    }
    if let Some(value) = value.as_u64() {
        return u32::try_from(value).ok();
    }
    if let Some(value) = value.as_pointer() {
        return Some(value);
    }
    value.as_str()?.trim().parse::<u32>().ok()
}
