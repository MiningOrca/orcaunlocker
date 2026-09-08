mod content_state;
mod localconfig;
mod ownership;
mod protobuf;
mod steam;
mod vdf;

use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::ffi::{OsStr, OsString};
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, anyhow, bail};
use serde::Serialize;
use steam_vdf_parser::{Obj, parse_appinfo};

use crate::vdf::object_u32_key;

#[derive(Serialize)]
struct GamesResponse {
    steam_root: String,
    games: Vec<GameRecord>,
}

#[derive(Serialize)]
struct GameRecord {
    app_id: u32,
    name: String,
    install_dir: String,
}

#[derive(Serialize)]
struct AppInfoResponse {
    app_id: u32,
    dlcs: Vec<DlcRecord>,
}

#[derive(Serialize)]
struct DlcRecord {
    app_id: u32,
    name: Option<String>,
}

fn main() {
    if let Err(error) = run() {
        eprintln!("{error:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let mut args = env::args_os().skip(1);
    let command = args.next().context("missing helper command")?;
    let command = command
        .to_str()
        .context("helper command is not valid UTF-8")?;

    let output = match command {
        "games" => {
            require_end(&mut args)?;
            serde_json::to_string(&games()?)?
        }
        "appinfo" => {
            let app_id = next_app_id(&mut args)?;
            let path = optional_path(&mut args, "--path")?;
            serde_json::to_string(&appinfo(app_id, path.as_deref())?)?
        }
        "ownership" => {
            let app_ids = next_app_ids(&mut args)?;
            let steam_root = optional_path(&mut args, "--steam-root")?;
            serde_json::to_string(&ownership::inspect(&app_ids, steam_root.as_deref())?)?
        }
        "content-state" => {
            let base_app_id = next_app_id(&mut args)?;
            let dlc_app_ids = next_app_ids(&mut args)?;
            let steam_root = required_path(&mut args, "--steam-root")?;
            let install_dir = required_path(&mut args, "--install-dir")?;
            require_end(&mut args)?;
            serde_json::to_string(&content_state::inspect(
                base_app_id,
                &dlc_app_ids,
                &steam_root,
                &install_dir,
            )?)?
        }
        "launch-options-all" => {
            let app_id = next_app_id(&mut args)?;
            let steam_root = optional_path(&mut args, "--steam-root")?;
            serde_json::to_string(&localconfig::inspect(app_id, steam_root.as_deref())?)?
        }
        "install-launch-options" => {
            let app_id = next_app_id(&mut args)?;
            let prefix_wrapper = next_path(&mut args, "prefix wrapper path")?;
            let command_wrapper = next_path(&mut args, "command wrapper path")?;
            let steam_root = optional_path(&mut args, "--steam-root")?;
            serde_json::to_string(&localconfig::install(
                app_id,
                &prefix_wrapper,
                &command_wrapper,
                steam_root.as_deref(),
            )?)?
        }
        "remove-launch-options" => {
            let app_id = next_app_id(&mut args)?;
            let prefix_wrapper = next_path(&mut args, "prefix wrapper path")?;
            let command_wrapper = next_path(&mut args, "command wrapper path")?;
            let steam_root = optional_path(&mut args, "--steam-root")?;
            serde_json::to_string(&localconfig::remove(
                app_id,
                &prefix_wrapper,
                &command_wrapper,
                steam_root.as_deref(),
            )?)?
        }
        other => bail!("unknown helper command: {other}"),
    };

    println!("{output}");
    Ok(())
}

fn next_app_id(args: &mut impl Iterator<Item = OsString>) -> Result<u32> {
    let raw = args.next().context("missing AppID")?;
    let text = raw.to_str().context("AppID is not valid UTF-8")?;
    text.parse::<u32>()
        .with_context(|| format!("invalid AppID: {text}"))
}

fn next_app_ids(args: &mut impl Iterator<Item = OsString>) -> Result<Vec<u32>> {
    let raw = args.next().context("missing comma-separated AppID list")?;
    let text = raw.to_str().context("AppID list is not valid UTF-8")?;
    let mut ids = BTreeSet::new();

    for token in text.split(',') {
        let token = token.trim();
        if token.is_empty() {
            bail!("empty AppID in AppID list");
        }
        let id = token
            .parse::<u32>()
            .with_context(|| format!("invalid AppID: {token}"))?;
        if id != 0 {
            ids.insert(id);
        }
    }

    if ids.is_empty() {
        bail!("AppID list is empty");
    }
    Ok(ids.into_iter().collect())
}

fn next_path(args: &mut impl Iterator<Item = OsString>, name: &str) -> Result<PathBuf> {
    args.next().map(PathBuf::from).with_context(|| format!("missing {name}"))
}

fn required_path(
    args: &mut impl Iterator<Item = OsString>,
    flag: &str,
) -> Result<PathBuf> {
    let argument = args.next().with_context(|| format!("missing {flag}"))?;
    if argument.as_os_str() != OsStr::new(flag) {
        bail!("expected {flag}, got {}", argument.to_string_lossy());
    }
    next_path(args, flag)
}

fn optional_path(
    args: &mut impl Iterator<Item = OsString>,
    flag: &str,
) -> Result<Option<PathBuf>> {
    let Some(argument) = args.next() else {
        return Ok(None);
    };
    if argument.as_os_str() != OsStr::new(flag) {
        bail!("unexpected helper argument: {}", argument.to_string_lossy());
    }
    let value = next_path(args, flag)?;
    require_end(args)?;
    Ok(Some(value))
}

fn require_end(args: &mut impl Iterator<Item = OsString>) -> Result<()> {
    if let Some(argument) = args.next() {
        bail!("unexpected helper argument: {}", argument.to_string_lossy());
    }
    Ok(())
}

fn games() -> Result<GamesResponse> {
    let steam = steamlocate::locate().context("Steam installation was not found")?;
    let mut games = BTreeMap::<u32, GameRecord>::new();

    for library in steam.libraries().context("could not read Steam libraries")? {
        let library = library.context("could not parse a Steam library")?;
        for app in library.apps() {
            let app = match app {
                Ok(app) => app,
                Err(error) => {
                    eprintln!("warning: skipping unreadable app manifest: {error}");
                    continue;
                }
            };

            let install_dir = library
                .path()
                .join("steamapps")
                .join("common")
                .join(&app.install_dir);

            if !install_dir.is_dir() {
                continue;
            }

            games.insert(
                app.app_id,
                GameRecord {
                    app_id: app.app_id,
                    name: app
                        .name
                        .unwrap_or_else(|| format!("Steam App {}", app.app_id)),
                    install_dir: install_dir.to_string_lossy().into_owned(),
                },
            );
        }
    }

    Ok(GamesResponse {
        steam_root: steam.path().to_string_lossy().into_owned(),
        games: games.into_values().collect(),
    })
}

fn appinfo(app_id: u32, explicit_path: Option<&Path>) -> Result<AppInfoResponse> {
    let appinfo_path = match explicit_path {
        Some(path) => path.to_owned(),
        None => steam::root(None)?.join("appcache").join("appinfo.vdf"),
    };

    let bytes = fs::read(&appinfo_path)
        .with_context(|| format!("could not read {}", appinfo_path.display()))?;
    let vdf = parse_appinfo(&bytes)
        .map_err(|error| anyhow!("could not parse {}: {error}", appinfo_path.display()))?;
    let root = vdf
        .as_obj()
        .context("appinfo.vdf root is not an object")?;

    let parent = object_u32_key(root, app_id)
        .with_context(|| format!("AppID {app_id} is not present in appinfo.vdf"))?;
    let list = nested_string(parent, &["appinfo", "extended", "listofdlc"])
        .unwrap_or_default();

    let mut ids = BTreeSet::new();
    for token in list.split(|character: char| character == ',' || character.is_whitespace()) {
        if token.is_empty() {
            continue;
        }
        if let Ok(id) = token.parse::<u32>() {
            if id != 0 {
                ids.insert(id);
            }
        }
    }

    let dlcs = ids
        .into_iter()
        .map(|dlc_id| DlcRecord {
            app_id: dlc_id,
            name: object_u32_key(root, dlc_id)
                .and_then(|app| nested_string(app, &["appinfo", "common", "name"])),
        })
        .collect();

    Ok(AppInfoResponse { app_id, dlcs })
}

fn nested_string(root: &Obj<'_>, path: &[&str]) -> Option<String> {
    let (last, parents) = path.split_last()?;
    let mut current = root;

    for key in parents {
        current = current.get(key)?.as_obj()?;
    }

    current
        .get(last)?
        .as_str()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}
