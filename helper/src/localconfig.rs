use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, anyhow, bail};
use serde::Serialize;
use steam_vdf_parser::{Obj, parse_text};

use crate::steam;
use crate::vdf::object_obj_ci;

#[derive(Serialize)]
pub(crate) struct Snapshot {
    app_id: u32,
    accounts: Vec<Account>,
}

#[derive(Serialize)]
struct Account {
    localconfig: String,
    launch_options: String,
}

#[derive(Serialize)]
pub(crate) struct Mutation {
    app_id: u32,
    modified_localconfigs: Vec<String>,
}

pub(crate) fn inspect(app_id: u32, explicit_steam_root: Option<&Path>) -> Result<Snapshot> {
    let steam_root = steam::root(explicit_steam_root)?;
    let configs = localconfig_paths(&steam_root)?;
    let mut accounts = Vec::with_capacity(configs.len());

    for config in configs {
        accounts.push(Account {
            launch_options: read_launch_options(&config, app_id)?,
            localconfig: config.to_string_lossy().into_owned(),
        });
    }

    Ok(Snapshot { app_id, accounts })
}

pub(crate) fn install(
    app_id: u32,
    prefix_wrapper: &Path,
    command_wrapper: &Path,
    explicit_steam_root: Option<&Path>,
) -> Result<Mutation> {
    mutate_all(app_id, explicit_steam_root, |current| {
        compose(current, prefix_wrapper, command_wrapper)
    })
}

pub(crate) fn remove(
    app_id: u32,
    prefix_wrapper: &Path,
    command_wrapper: &Path,
    explicit_steam_root: Option<&Path>,
) -> Result<Mutation> {
    mutate_all(app_id, explicit_steam_root, |current| {
        let cleaned = strip_inject_hook(current, prefix_wrapper, command_wrapper);
        if cleaned == "%command%" {
            String::new()
        } else {
            cleaned
        }
    })
}

fn mutate_all<F>(app_id: u32, explicit_steam_root: Option<&Path>, transform: F) -> Result<Mutation>
where
    F: Fn(&str) -> String,
{
    let steam_root = steam::root(explicit_steam_root)?;
    let configs = localconfig_paths(&steam_root)?;
    let mut updates = Vec::new();

    // Prepare every edit before the first write. A malformed/unreadable account
    // must not leave earlier accounts modified.
    for path in configs {
        let original = fs::read(&path)
            .with_context(|| format!("could not read {}", path.display()))?;
        let text = std::str::from_utf8(&original)
            .with_context(|| format!("{} is not valid UTF-8", path.display()))?;
        let desired = transform(&launch_options_from_text(text, &path, app_id)?);
        let replacement = set_launch_options(text, app_id, &desired, &path)?;

        if replacement.as_bytes() == original.as_slice() {
            continue;
        }

        updates.push(Update {
            permissions: fs::metadata(&path)
                .with_context(|| format!("could not inspect {}", path.display()))?
                .permissions(),
            path,
            original,
            replacement: replacement.into_bytes(),
        });
    }

    let modified = write_transaction(&updates)?;
    Ok(Mutation {
        app_id,
        modified_localconfigs: modified
            .into_iter()
            .map(|path| path.to_string_lossy().into_owned())
            .collect(),
    })
}

fn localconfig_paths(steam_root: &Path) -> Result<Vec<PathBuf>> {
    let userdata = steam_root.join("userdata");
    let canonical_userdata = fs::canonicalize(&userdata)
        .with_context(|| format!("could not resolve {}", userdata.display()))?;
    let mut configs = Vec::new();

    if let Ok(entries) = fs::read_dir(&userdata) {
        for entry in entries.flatten() {
            // Follow an account-directory symlink only far enough to validate the
            // final localconfig against canonical userdata below.
            if !entry.path().is_dir() {
                continue;
            }

            let path = entry.path().join("config").join("localconfig.vdf");
            if !path.is_file() {
                continue;
            }
            if fs::symlink_metadata(&path)
                .with_context(|| format!("could not inspect {}", path.display()))?
                .file_type()
                .is_symlink()
            {
                bail!("refusing symbolic-link Steam localconfig: {}", path.display());
            }

            let canonical = fs::canonicalize(&path)
                .with_context(|| format!("could not resolve {}", path.display()))?;
            if !canonical.starts_with(&canonical_userdata) {
                bail!(
                    "Steam localconfig resolves outside userdata: {} -> {}",
                    path.display(),
                    canonical.display()
                );
            }
            configs.push(path);
        }
    }
    configs.sort();

    if configs.is_empty() {
        bail!("no Steam userdata/*/config/localconfig.vdf was found");
    }
    Ok(configs)
}

fn read_launch_options(path: &Path, app_id: u32) -> Result<String> {
    let text = fs::read_to_string(path)
        .with_context(|| format!("could not read {}", path.display()))?;
    launch_options_from_text(&text, path, app_id)
}

fn launch_options_from_text(text: &str, source: &Path, app_id: u32) -> Result<String> {
    let parsed = parse_text(text)
        .map_err(|error| anyhow!("could not parse {}: {error}", source.display()))?;
    let root = parsed
        .as_obj()
        .context("localconfig.vdf root is not an object")?;
    let store = object_obj_ci(root, "UserLocalConfigStore").unwrap_or(root);
    let app_key = app_id.to_string();

    Ok(nested_obj_ci(store, &["Software", "Valve", "Steam", "Apps", &app_key])
        .and_then(|app| object_string_ci(app, "LaunchOptions"))
        .unwrap_or_default())
}

fn object_string_ci(root: &Obj<'_>, key: &str) -> Option<String> {
    root.iter().find_map(|(candidate, value)| {
        if candidate.eq_ignore_ascii_case(key) {
            value.as_str().map(str::trim).map(str::to_owned)
        } else {
            None
        }
    })
}

fn nested_obj_ci<'a, 'text>(root: &'a Obj<'text>, path: &[&str]) -> Option<&'a Obj<'text>> {
    let mut current = root;
    for key in path {
        current = object_obj_ci(current, key)?;
    }
    Some(current)
}

#[derive(Clone, Copy)]
struct Block {
    open: usize,
    close: usize,
}

#[derive(Clone, Copy)]
struct StringField {
    remove_start: usize,
    remove_end: usize,
    value_start: usize,
    value_end: usize,
}

fn set_launch_options(text: &str, app_id: u32, value: &str, source: &Path) -> Result<String> {
    // Validate with the real VDF parser first. The surgical writer preserves the
    // original bytes around LaunchOptions; it is not a fallback parser/repair tool.
    parse_text(text)
        .map_err(|error| anyhow!("could not parse {}: {error}", source.display()))?;

    let apps = [
        &["UserLocalConfigStore", "Software", "Valve", "Steam", "Apps"][..],
        &["Software", "Valve", "Steam", "Apps"][..],
    ]
    .into_iter()
    .find_map(|path| nested_block(text, path))
    .with_context(|| format!("Steam Apps block was not found in {}", source.display()))?;

    let app_key = app_id.to_string();
    let Some(app) = block(text, &app_key, apps.open + 1, apps.close) else {
        if value.is_empty() {
            return Ok(text.to_owned());
        }
        let escaped = vdf_escape(value);
        let entry = format!(
            "\n\t\t\t\t\t\t\"{app_key}\"\n\t\t\t\t\t\t{{\n\t\t\t\t\t\t\t\"LaunchOptions\"\t\t\"{escaped}\"\n\t\t\t\t\t\t}}\n"
        );
        return Ok(splice(text, apps.close, apps.close, &entry));
    };

    if let Some(field) = string_field(text, app, "LaunchOptions") {
        if value.is_empty() {
            return Ok(splice(text, field.remove_start, field.remove_end, ""));
        }
        return Ok(splice(
            text,
            field.value_start,
            field.value_end,
            &vdf_escape(value),
        ));
    }

    if value.is_empty() {
        return Ok(text.to_owned());
    }
    let insertion = format!(
        "\n\t\t\t\t\t\t\t\"LaunchOptions\"\t\t\"{}\"\n",
        vdf_escape(value)
    );
    Ok(splice(text, app.close, app.close, &insertion))
}

fn nested_block(text: &str, keys: &[&str]) -> Option<Block> {
    let mut start = 0;
    let mut end = text.len();
    let mut found = None;
    for key in keys {
        let current = block(text, key, start, end)?;
        start = current.open + 1;
        end = current.close;
        found = Some(current);
    }
    found
}

fn block(text: &str, key: &str, start: usize, end: usize) -> Option<Block> {
    let bytes = text.as_bytes();
    let mut i = start;
    let end = end.min(bytes.len());

    while i < end {
        if bytes[i] != b'"' {
            i += 1;
            continue;
        }
        let quote_end = quoted_end(bytes, i)?;
        let candidate = &text[i + 1..quote_end];
        let mut cursor = quote_end + 1;
        while cursor < end && bytes[cursor].is_ascii_whitespace() {
            cursor += 1;
        }
        if candidate.eq_ignore_ascii_case(key) && cursor < end && bytes[cursor] == b'{' {
            let close = block_end(bytes, cursor)?;
            if close <= end {
                return Some(Block { open: cursor, close });
            }
        }
        i = quote_end + 1;
    }
    None
}

fn string_field(text: &str, parent: Block, key: &str) -> Option<StringField> {
    let bytes = text.as_bytes();
    let mut i = parent.open + 1;

    while i < parent.close {
        if bytes[i] != b'"' {
            i += 1;
            continue;
        }
        let key_end = quoted_end(bytes, i)?;
        let candidate = &text[i + 1..key_end];
        let mut cursor = key_end + 1;
        while cursor < parent.close && bytes[cursor].is_ascii_whitespace() {
            cursor += 1;
        }

        if cursor < parent.close && bytes[cursor] == b'{' {
            i = block_end(bytes, cursor)? + 1;
            continue;
        }
        if cursor >= parent.close || bytes[cursor] != b'"' {
            i = key_end + 1;
            continue;
        }

        let value_end = quoted_end(bytes, cursor)?;
        if candidate.eq_ignore_ascii_case(key) {
            let line_start = text[..i].rfind('\n').map(|offset| offset + 1).unwrap_or(0);
            let line_content_end = text[value_end + 1..]
                .find('\n')
                .map(|offset| value_end + 1 + offset)
                .unwrap_or(text.len());
            let full_line = text[line_start..i].trim().is_empty()
                && text[value_end + 1..line_content_end].trim().is_empty();
            return Some(StringField {
                remove_start: if full_line { line_start } else { i },
                remove_end: if full_line && line_content_end < text.len() {
                    line_content_end + 1
                } else if full_line {
                    line_content_end
                } else {
                    value_end + 1
                },
                value_start: cursor + 1,
                value_end,
            });
        }
        i = value_end + 1;
    }
    None
}

fn quoted_end(bytes: &[u8], open: usize) -> Option<usize> {
    let mut escaped = false;
    for (i, byte) in bytes.iter().enumerate().skip(open + 1) {
        if escaped {
            escaped = false;
        } else if *byte == b'\\' {
            escaped = true;
        } else if *byte == b'"' {
            return Some(i);
        }
    }
    None
}

fn block_end(bytes: &[u8], open: usize) -> Option<usize> {
    let mut depth = 0usize;
    let mut quoted = false;
    let mut escaped = false;

    for (i, byte) in bytes.iter().enumerate().skip(open) {
        if quoted {
            if escaped {
                escaped = false;
            } else if *byte == b'\\' {
                escaped = true;
            } else if *byte == b'"' {
                quoted = false;
            }
            continue;
        }

        match *byte {
            b'"' => quoted = true,
            b'{' => depth += 1,
            b'}' => {
                depth = depth.checked_sub(1)?;
                if depth == 0 {
                    return Some(i);
                }
            }
            _ => {}
        }
    }
    None
}

fn splice(text: &str, start: usize, end: usize, replacement: &str) -> String {
    let mut result = String::with_capacity(text.len() + replacement.len());
    result.push_str(&text[..start]);
    result.push_str(replacement);
    result.push_str(&text[end..]);
    result
}

fn vdf_escape(value: &str) -> String {
    value.replace('\\', "\\\\").replace('"', "\\\"")
}

fn compose(current: &str, prefix: &Path, command: &Path) -> String {
    let mut clean = strip_inject_hook(current, prefix, command);
    if clean == "%command%" {
        clean.clear();
    }

    if let Some(position) = clean.find("%command%") {
        clean.replace_range(
            position..position + "%command%".len(),
            &format!("{} %command%", quoted(command)),
        );
        clean
    } else {
        let fragment = format!("{} %command%", quoted(prefix));
        if clean.is_empty() {
            fragment
        } else {
            format!("{fragment} {clean}")
        }
    }
}

fn strip_inject_hook(value: &str, prefix_wrapper: &Path, command_wrapper: &Path) -> String {
    let mut result = value.trim().to_owned();
    loop {
        let previous = result.clone();
        if let Some(updated) = strip_one_hook(&result, prefix_wrapper, command_wrapper) {
            result = updated;
        }
        result = collapse_duplicate_commands(&result).trim().to_owned();
        if result == previous {
            return result;
        }
    }
}

fn strip_one_hook(value: &str, prefix_wrapper: &Path, command_wrapper: &Path) -> Option<String> {
    let bytes = value.as_bytes();
    let mut i = 0usize;

    while i < bytes.len() {
        if bytes[i] != b'"' {
            i += 1;
            continue;
        }
        let Some(end_quote) = quoted_end(bytes, i) else {
            break;
        };
        let path = value[i + 1..end_quote].to_ascii_lowercase();
        let prefix_suffix = wrapper_suffix(prefix_wrapper);
        let command_suffix = wrapper_suffix(command_wrapper);
        let replacement = if path.contains(&prefix_suffix) {
            Some("")
        } else if path.contains(&command_suffix) {
            Some("%command%")
        } else {
            None
        };

        if let Some(replacement) = replacement {
            let mut end = end_quote + 1;
            while end < bytes.len() && bytes[end].is_ascii_whitespace() {
                end += 1;
            }
            if value[end..].starts_with("%command%") {
                return Some(splice(value, i, end + "%command%".len(), replacement));
            }
        }
        i = end_quote + 1;
    }

    None
}

fn wrapper_suffix(wrapper: &Path) -> String {
    let directory = wrapper
        .parent()
        .and_then(Path::file_name)
        .map(|value| value.to_string_lossy().into_owned())
        .unwrap_or_default();
    let file = wrapper
        .file_name()
        .map(|value| value.to_string_lossy().into_owned())
        .unwrap_or_default();
    format!("/{directory}/{file}").to_ascii_lowercase()
}

fn collapse_duplicate_commands(value: &str) -> String {
    let mut result = value.to_owned();
    loop {
        let mut search = 0usize;
        let mut duplicate = None;
        while let Some(offset) = result[search..].find("%command%") {
            let first = search + offset;
            let mut second = first + "%command%".len();
            while second < result.len() && result.as_bytes()[second].is_ascii_whitespace() {
                second += 1;
            }
            if result[second..].starts_with("%command%") {
                duplicate = Some((first, second + "%command%".len()));
                break;
            }
            search = first + "%command%".len();
        }
        let Some((start, end)) = duplicate else {
            return result;
        };
        result.replace_range(start..end, "%command%");
    }
}

fn quoted(path: &Path) -> String {
    format!("\"{}\"", path.to_string_lossy().replace('"', "\\\""))
}

struct Update {
    path: PathBuf,
    original: Vec<u8>,
    replacement: Vec<u8>,
    permissions: fs::Permissions,
}

fn write_transaction(updates: &[Update]) -> Result<Vec<PathBuf>> {
    let mut written = Vec::<usize>::new();

    for (index, update) in updates.iter().enumerate() {
        if let Err(error) = atomic_replace(&update.path, &update.replacement, &update.permissions) {
            let mut rollback_errors = Vec::new();
            for previous_index in written.iter().rev().copied() {
                let previous = &updates[previous_index];
                if let Err(rollback) =
                    atomic_replace(&previous.path, &previous.original, &previous.permissions)
                {
                    rollback_errors.push(format!("{}: {rollback:#}", previous.path.display()));
                }
            }
            if rollback_errors.is_empty() {
                return Err(error)
                    .context("Steam localconfig transaction failed; written files were restored");
            }
            bail!(
                "Steam localconfig transaction failed: {error:#}; rollback failures: {}",
                rollback_errors.join("; ")
            );
        }
        written.push(index);
    }

    Ok(written
        .into_iter()
        .map(|index| updates[index].path.clone())
        .collect())
}

fn atomic_replace(path: &Path, data: &[u8], permissions: &fs::Permissions) -> Result<()> {
    let parent = path
        .parent()
        .with_context(|| format!("{} has no parent directory", path.display()))?;
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .context("Steam localconfig filename is not valid UTF-8")?;

    let mut attempt = 0u32;
    let (temp_path, mut file) = loop {
        let temp = parent.join(format!(
            ".{name}.miningorca.{}.{}.tmp",
            std::process::id(),
            attempt
        ));
        match OpenOptions::new().write(true).create_new(true).open(&temp) {
            Ok(file) => break (temp, file),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                attempt = attempt.checked_add(1).context("too many temporary file collisions")?;
            }
            Err(error) => {
                return Err(error).with_context(|| format!("could not create {}", temp.display()));
            }
        }
    };

    let result = (|| -> Result<()> {
        file.write_all(data)
            .with_context(|| format!("could not write {}", temp_path.display()))?;
        file.set_permissions(permissions.clone())
            .with_context(|| format!("could not preserve permissions for {}", path.display()))?;
        file.sync_all()
            .with_context(|| format!("could not sync {}", temp_path.display()))?;
        drop(file);
        fs::rename(&temp_path, path).with_context(|| {
            format!(
                "could not atomically replace {} with {}",
                path.display(),
                temp_path.display()
            )
        })
    })();

    if result.is_err() {
        let _ = fs::remove_file(&temp_path);
    }
    result
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::strip_inject_hook;

    #[test]
    fn strip_inject_hook_only_recognizes_configured_wrapper_layout() {
        let prefix = Path::new("/tmp/Game/.custom-runtime/run-prefix.sh");
        let command = Path::new("/tmp/Game/.custom-runtime/run-command.sh");

        assert_eq!(
            strip_inject_hook(
                r#""/other/library/.custom-runtime/run-prefix.sh" %command% -foo"#,
                prefix,
                command,
            ),
            "-foo"
        );
        assert_eq!(
            strip_inject_hook(
                r#"-foo "/other/library/.custom-runtime/run-command.sh" %command% -bar"#,
                prefix,
                command,
            ),
            "-foo %command% -bar"
        );

        for value in [
            r#""/tmp/Game/.other-runtime/run-prefix.sh" %command% -foo"#,
            r#""/tmp/Game/.custom-runtime/inject/run.sh" %command% -foo"#,
            r#""/tmp/tww3-wrapper.sh" %command% -foo"#,
        ] {
            assert_eq!(strip_inject_hook(value, prefix, command), value);
        }
    }
}
