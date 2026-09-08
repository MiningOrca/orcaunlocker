use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use anyhow::{Context, Result, anyhow, bail};
use serde::Serialize;
use steam_vdf_parser::{Obj, Value, parse_appinfo, parse_text};

mod depot_manifest;

use depot_manifest::{
    DEPOT_FILE_DIRECTORY, DEPOT_FILE_SYMLINK, DepotManifest, Verification, parse_manifest_file,
    safe_manifest_relative_path, verify_manifest_files,
};
#[cfg(test)]
use depot_manifest::synthetic_manifest;
use crate::vdf::{object_string_ci, object_u32_key, object_value_ci, value_u32};

#[derive(Serialize)]
pub(crate) struct Snapshot {
    base_app_id: u32,
    storage: StorageLayout,
    #[serde(skip_serializing_if = "Option::is_none")]
    content_root: Option<String>,
    apps: Vec<AppRecord>,
}

#[derive(Serialize)]
struct AppRecord {
    app_id: u32,
    state: &'static str,
    source: &'static str,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Applicability {
    Yes,
    No,
    Unknown,
}

struct Depot<'a, 'text> {
    id: u32,
    metadata: &'a Obj<'text>,
    applicability: Applicability,
    installed: bool,
}

#[derive(Debug)]
struct ContentUnit {
    relative_path: PathBuf,
    total_size: u64,
    file_sizes: Vec<u64>,
}

#[derive(Debug)]
struct SizeInferenceLayout {
    root_relative: PathBuf,
    units: Vec<ContentUnit>,
}

#[derive(Clone, Copy, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum StorageLayout {
    Separate,
    Bundled,
    Unknown,
}

struct ContentInference {
    storage: StorageLayout,
    root_relative: Option<PathBuf>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SizeMatch {
    Active,
    Historical,
    ActiveSubset,
    HistoricalSubset,
    ActiveUltraClose,
    HistoricalUltraClose,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SizeResolution {
    Match(SizeMatch),
    NoMatch,
    Ambiguous,
    Unavailable,
}


pub(crate) fn inspect(
    base_app_id: u32,
    dlc_app_ids: &[u32],
    steam_root: &Path,
    install_dir: &Path,
) -> Result<Snapshot> {
    let appmanifest_path = appmanifest_path(base_app_id, install_dir)?;
    let appmanifest_text = fs::read_to_string(&appmanifest_path)
        .with_context(|| format!("could not read {}", appmanifest_path.display()))?;
    let appmanifest = parse_text(&appmanifest_text)
        .map_err(|error| anyhow!("could not parse {}: {error}", appmanifest_path.display()))?;
    let app_state = app_state_object(&appmanifest)?;

    let appinfo_path = steam_root.join("appcache").join("appinfo.vdf");
    let appinfo_bytes = fs::read(&appinfo_path)
        .with_context(|| format!("could not read {}", appinfo_path.display()))?;
    let appinfo = parse_appinfo(&appinfo_bytes)
        .map_err(|error| anyhow!("could not parse {}: {error}", appinfo_path.display()))?;
    let appinfo_root = appinfo
        .as_obj()
        .context("appinfo.vdf root is not an object")?;

    let installed = installed_depots(app_state);
    let language = current_language(app_state);
    let branch = current_branch(app_state);
    let library_root = appmanifest_path
        .parent()
        .and_then(Path::parent)
        .context("appmanifest has no Steam library root")?;
    let depotcache_dirs = depotcache_dirs(steam_root, library_root);
    let base_record = object_u32_key(appinfo_root, base_app_id);

    let requested = dlc_app_ids
        .iter()
        .copied()
        .filter(|id| *id != 0)
        .collect::<BTreeSet<_>>();
    let mut apps = requested
        .iter()
        .copied()
        .map(|dlc_app_id| {
            inspect_dlc(
                base_app_id,
                dlc_app_id,
                base_record,
                object_u32_key(appinfo_root, dlc_app_id),
                &installed,
                language.as_deref(),
                &branch,
                &depotcache_dirs,
                install_dir,
            )
        })
        .collect::<Vec<_>>();

    let inference = apply_size_inference(
        &mut apps,
        base_app_id,
        &requested,
        base_record,
        appinfo_root,
        app_state,
        &installed,
        language.as_deref(),
        &branch,
        &depotcache_dirs,
        install_dir,
    );
    let content_root = inference
        .root_relative
        .map(|relative| install_dir.join(relative).to_string_lossy().into_owned());

    Ok(Snapshot {
        base_app_id,
        storage: inference.storage,
        content_root,
        apps,
    })
}

fn app_state_object<'a, 'text>(
    appmanifest: &'a steam_vdf_parser::Vdf<'text>,
) -> Result<&'a Obj<'text>> {
    if !appmanifest.key().eq_ignore_ascii_case("AppState") {
        bail!(
            "appmanifest root is {}, expected AppState",
            appmanifest.key()
        );
    }
    appmanifest
        .as_obj()
        .context("appmanifest AppState is not an object")
}

fn inspect_dlc<'a, 'text>(
    base_app_id: u32,
    dlc_app_id: u32,
    base_record: Option<&'a Obj<'text>>,
    dlc_record: Option<&'a Obj<'text>>,
    installed: &BTreeSet<u32>,
    language: Option<&str>,
    branch: &str,
    depotcache_dirs: &[PathBuf],
    install_dir: &Path,
) -> AppRecord {
    let (mut depots, relationship_conflict) =
        associated_depots(base_app_id, dlc_app_id, base_record, dlc_record);

    if depots.is_empty() {
        return if base_record.is_some() && dlc_record.is_some() && !relationship_conflict {
            record(dlc_app_id, "present", "bundled")
        } else {
            record(dlc_app_id, "unknown", "insufficient_evidence")
        };
    }

    for depot in &mut depots {
        depot.installed = installed.contains(&depot.id);
        depot.applicability = applicability(depot.metadata, language);
    }

    let candidates: Vec<&Depot<'_, '_>> = depots
        .iter()
        .filter(|depot| depot.applicability != Applicability::No || depot.installed)
        .collect();

    if candidates.is_empty() {
        return record(dlc_app_id, "present", "bundled");
    }

    let payloads: Vec<&Depot<'_, '_>> = candidates
        .into_iter()
        .filter(|depot| {
            depot.installed
                || object_obj_ci(depot.metadata, "manifests").is_some_and(|v| !v.is_empty())
                || has_cached_manifest(depotcache_dirs, depot.id)
        })
        .collect();

    if payloads.is_empty() {
        return record(dlc_app_id, "present", "bundled");
    }

    if payloads.iter().any(|depot| depot.installed) {
        return record(dlc_app_id, "present", "steam_installed_depots");
    }

    let mut checks = Vec::new();
    let mut unavailable = 0usize;
    let mut used_historical_manifest = false;
    for depot in &payloads {
        let (exact_cached, exact) =
            exact_manifest_verification(depot, branch, depotcache_dirs, install_dir);
        match exact {
            Some(Verification::Unknown) => unavailable += 1,
            Some(status) => checks.push(status),
            None if exact_cached => unavailable += 1,
            None => {
                if historical_manifest_present(depot, branch, depotcache_dirs, install_dir) {
                    checks.push(Verification::Present);
                    used_historical_manifest = true;
                } else {
                    unavailable += 1;
                }
            }
        }
    }

    if unavailable == 0 && !checks.is_empty() && checks.iter().all(|status| *status == Verification::Present) {
        return record(
            dlc_app_id,
            "present",
            if used_historical_manifest {
                "historical_manifest"
            } else {
                "exact_manifest"
            },
        );
    }
    if unavailable == 0 && !checks.is_empty() && checks.iter().all(|status| *status == Verification::Missing) {
        return record(dlc_app_id, "missing", "exact_manifest");
    }
    if checks
        .iter()
        .any(|status| matches!(status, Verification::Missing | Verification::Incomplete))
    {
        return record(dlc_app_id, "incomplete", "exact_manifest");
    }

    record(dlc_app_id, "unknown", "separate_payload_not_installed")
}

fn exact_manifest_verification(
    depot: &Depot<'_, '_>,
    branch: &str,
    depotcache_dirs: &[PathBuf],
    install_dir: &Path,
) -> (bool, Option<Verification>) {
    let Some(gid) = manifest_branch_gid(depot.metadata, branch) else {
        return (false, None);
    };
    let Some(path) = locate_cached_manifest(depotcache_dirs, depot.id, gid) else {
        return (false, None);
    };
    let Ok(manifest) = parse_manifest_file(&path) else {
        return (true, None);
    };

    if manifest.depot_id.is_some_and(|id| id != depot.id)
        || manifest.manifest_gid.is_some_and(|manifest_gid| manifest_gid != gid)
    {
        return (true, Some(Verification::Unknown));
    }

    (
        true,
        Some(verify_manifest_files(&manifest, install_dir).unwrap_or(Verification::Unknown)),
    )
}

fn historical_manifest_present(
    depot: &Depot<'_, '_>,
    branch: &str,
    depotcache_dirs: &[PathBuf],
    install_dir: &Path,
) -> bool {
    let active_gid = manifest_branch_gid(depot.metadata, branch);
    let Some((path, gid)) = newest_cached_manifest(depotcache_dirs, depot.id, active_gid) else {
        return false;
    };
    let Ok(manifest) = parse_manifest_file(&path) else {
        return false;
    };

    if manifest.depot_id.is_some_and(|id| id != depot.id)
        || manifest.manifest_gid.is_some_and(|manifest_gid| manifest_gid != gid)
    {
        return false;
    }

    verify_manifest_files(&manifest, install_dir).ok() == Some(Verification::Present)
}

fn apply_size_inference<'a, 'text>(
    apps: &mut [AppRecord],
    base_app_id: u32,
    dlc_app_ids: &BTreeSet<u32>,
    base_record: Option<&'a Obj<'text>>,
    appinfo_root: &'a Obj<'text>,
    app_state: &Obj<'_>,
    installed: &BTreeSet<u32>,
    language: Option<&str>,
    branch: &str,
    depotcache_dirs: &[PathBuf],
    install_dir: &Path,
) -> ContentInference {
    let mut support_units = Vec::new();
    let mut support_sizes = Vec::new();
    let mut support_dlc_ids = dlc_app_ids.clone();
    if let Some(list) = base_record
        .and_then(|base| nested_string_ci(base, &["appinfo", "extended", "listofdlc"]))
    {
        support_dlc_ids.extend(csv_app_ids(&list));
    }

    for dlc_app_id in support_dlc_ids {
        let (mut depots, _) = associated_depots(
            base_app_id,
            dlc_app_id,
            base_record,
            object_u32_key(appinfo_root, dlc_app_id),
        );
        for depot in &mut depots {
            depot.installed = installed.contains(&depot.id);
            depot.applicability = applicability(depot.metadata, language);
        }

        for depot in depots
            .iter()
            .filter(|depot| depot.applicability != Applicability::No || depot.installed)
        {
            let Some(manifest) =
                exact_present_manifest(depot, app_state, branch, depotcache_dirs, install_dir)
            else {
                continue;
            };
            let Some(unit) = manifest_unit_dir(&manifest) else {
                continue;
            };
            support_sizes.push((unit.clone(), manifest.disk_original));
            support_units.push(unit);
        }
    }


    let shared_base_content = has_shared_base_content(
        base_record,
        app_state,
        installed,
        branch,
        depotcache_dirs,
        install_dir,
        &support_units,
    );

    let layout = infer_size_layout(&support_units, install_dir);
    // With only one exact DLC manifest we cannot infer sibling layout. If that
    // manifest occupies less than half of its own unit directory, the unit is
    // strongly shared with other game content rather than being a dedicated DLC.
    let shared_unit_content = layout.is_none()
        && support_sizes.len() == 1
        && support_sizes[0]
            .1
            .filter(|size| *size > 0)
            .is_some_and(|size| {
                directory_size_exceeds(
                    &install_dir.join(&support_sizes[0].0),
                    size.saturating_mul(2),
                )
                .unwrap_or(false)
            });

    let storage = detect_storage_layout(
        layout.as_ref(),
        shared_base_content || shared_unit_content,
        apps,
    );

    let Some(layout) = layout else {
        return ContentInference {
            storage,
            root_relative: None,
        };
    };


    for app in apps.iter_mut().filter(|app| {
        app.state == "unknown" && app.source == "separate_payload_not_installed"
    }) {
        let (mut depots, _) = associated_depots(
            base_app_id,
            app.app_id,
            base_record,
            object_u32_key(appinfo_root, app.app_id),
        );
        for depot in &mut depots {
            depot.installed = installed.contains(&depot.id);
            depot.applicability = applicability(depot.metadata, language);
        }

        let payloads = depots
            .iter()
            .filter(|depot| depot.applicability != Applicability::No || depot.installed)
            .filter(|depot| {
                depot.installed
                    || object_obj_ci(depot.metadata, "manifests").is_some_and(|value| !value.is_empty())
                    || has_cached_manifest(depotcache_dirs, depot.id)
            })
            .collect::<Vec<_>>();
        if payloads.is_empty() {
            continue;
        }


        let mut matches = Vec::new();
        let mut missing = 0usize;
        let mut unresolved = false;
        for depot in payloads {
            match match_depot_size(depot.metadata, branch, &layout.units) {
                SizeResolution::Match(size_match) => matches.push(size_match),
                SizeResolution::NoMatch => missing += 1,
                SizeResolution::Ambiguous | SizeResolution::Unavailable => {
                    unresolved = true;
                    break;
                }
            }
        }
        if unresolved {
            continue;
        }
        if matches.is_empty() && missing > 0 {
            *app = record(app.app_id, "missing", "separate_layout_no_match");
            continue;
        }
        if missing > 0 {
            *app = record(app.app_id, "incomplete", "separate_layout_partial_match");
            continue;
        }
        if !matches.is_empty() {
            *app = record(app.app_id, "present", size_match_source(&matches));
        }
    }

    ContentInference {
        storage,
        root_relative: Some(layout.root_relative),
    }
}

fn detect_storage_layout(
    layout: Option<&SizeInferenceLayout>,
    shared_base_content: bool,
    apps: &[AppRecord],
) -> StorageLayout {
    if layout.is_some() {
        return StorageLayout::Separate;
    }
    if apps
        .iter()
        .any(|app| matches!(app.state, "missing" | "incomplete"))
    {
        return StorageLayout::Unknown;
    }
    if apps.iter().any(|app| app.state == "present" && app.source == "bundled")
        || shared_base_content
    {
        return StorageLayout::Bundled;
    }
    StorageLayout::Unknown
}

fn has_shared_base_content<'a, 'text>(
    base_record: Option<&'a Obj<'text>>,
    app_state: &Obj<'_>,
    installed: &BTreeSet<u32>,
    branch: &str,
    depotcache_dirs: &[PathBuf],
    install_dir: &Path,
    support_units: &[PathBuf],
) -> bool {
    if support_units.is_empty() {
        return false;
    }
    let Some(entries) = base_record.and_then(|base| nested_obj_ci(base, &["appinfo", "depots"])) else {
        return false;
    };
    for (key, value) in entries.iter() {
        let Ok(id) = key.parse::<u32>() else { continue };
        if !installed.contains(&id) {
            continue;
        }
        let Some(metadata) = value.as_obj() else { continue };
        if recursive_has_key(metadata, "dlcappid") || recursive_has_key(metadata, "depotfromapp") {
            continue;
        }
        let depot = Depot {
            id,
            metadata,
            applicability: Applicability::Yes,
            installed: true,
        };
        let Some(manifest) = exact_present_manifest(
            &depot,
            app_state,
            branch,
            depotcache_dirs,
            install_dir,
        ) else {
            continue;
        };
        for file in &manifest.files {
            if file.flags & DEPOT_FILE_DIRECTORY != 0
                || file.flags & DEPOT_FILE_SYMLINK != 0
                || file.has_linktarget
            {
                continue;
            }
            let Some(filename) = file.filename.as_deref() else { continue };
            let Ok(relative) = safe_manifest_relative_path(filename) else { continue };
            let Some(parent) = relative.parent() else { continue };
            if support_units.iter().any(|support| parent.starts_with(support)) {
                return true;
            }
        }
    }
    false
}

fn directory_size_exceeds(root: &Path, threshold: u64) -> Result<bool> {
    let mut total = 0u64;
    let mut stack = vec![root.to_path_buf()];

    while let Some(directory) = stack.pop() {
        for entry in fs::read_dir(&directory)
            .with_context(|| format!("could not read {}", directory.display()))?
        {
            let entry = entry?;
            let file_type = entry.file_type()?;
            if file_type.is_dir() {
                stack.push(entry.path());
            } else if file_type.is_file() {
                total = total.saturating_add(entry.metadata()?.len());
                if total > threshold {
                    return Ok(true);
                }
            }
        }
    }

    Ok(false)
}

fn exact_present_manifest(
    depot: &Depot<'_, '_>,
    app_state: &Obj<'_>,
    branch: &str,
    depotcache_dirs: &[PathBuf],
    install_dir: &Path,
) -> Option<DepotManifest> {
    let mut gids = Vec::new();
    if depot.installed {
        if let Some(gid) = installed_manifest_gid(app_state, depot.id) {
            gids.push(gid);
        }
    }
    if let Some(gid) = manifest_branch_gid(depot.metadata, branch) {
        if !gids.contains(&gid) {
            gids.push(gid);
        }
    }

    for gid in gids {
        let Some(path) = locate_cached_manifest(depotcache_dirs, depot.id, gid) else {
            continue;
        };
        let Ok(manifest) = parse_manifest_file(&path) else {
            continue;
        };
        if manifest.depot_id.is_some_and(|id| id != depot.id)
            || manifest.manifest_gid.is_some_and(|manifest_gid| manifest_gid != gid)
        {
            continue;
        }
        if verify_manifest_files(&manifest, install_dir).ok() == Some(Verification::Present) {
            return Some(manifest);
        }
    }
    None
}

fn installed_manifest_gid(app_state: &Obj<'_>, depot_id: u32) -> Option<u64> {
    let depots = object_obj_ci(app_state, "InstalledDepots")?;
    let key = depot_id.to_string();
    let value = object_value_ci(depots, &key)?;
    value
        .as_obj()
        .and_then(|entry| object_value_ci(entry, "manifest"))
        .and_then(value_u64)
        .or_else(|| value_u64(value))
}

fn manifest_unit_dir(manifest: &DepotManifest) -> Option<PathBuf> {
    let mut parents = Vec::new();
    for file in &manifest.files {
        if file.flags & DEPOT_FILE_DIRECTORY != 0
            || file.flags & DEPOT_FILE_SYMLINK != 0
            || file.has_linktarget
        {
            continue;
        }
        let filename = file.filename.as_deref()?;
        let relative = safe_manifest_relative_path(filename).ok()?;
        let parent = relative.parent()?.to_path_buf();
        if parent.as_os_str().is_empty() {
            return None;
        }
        parents.push(parent);
    }
    common_path_prefix(&parents)
}

fn infer_size_layout(support_units: &[PathBuf], install_dir: &Path) -> Option<SizeInferenceLayout> {
    if support_units.len() < 2 {
        return None;
    }

    let Some(root_relative) = common_path_prefix(support_units) else {
        return None;
    };
    let root_depth = root_relative.components().count();
    if support_units
        .iter()
        .any(|unit| unit.components().count() <= root_depth)
    {
        return None;
    }

    let claimed = support_units
        .iter()
        .filter_map(|unit| unit.components().nth(root_depth))
        .map(|component| component.as_os_str().to_os_string())
        .collect::<BTreeSet<_>>();

    let root = install_dir.join(&root_relative);
    let entries = match fs::read_dir(&root) {
        Ok(entries) => entries,
        Err(_) => return None,
    };
    let mut units = Vec::new();
    for entry in entries.flatten() {
        let file_type = match entry.file_type() {
            Ok(file_type) => file_type,
            Err(_) => return None,
        };
        if !file_type.is_dir() || claimed.contains(&entry.file_name()) {
            continue;
        }
        let unit = match scan_content_unit(
            &entry.path(),
            root_relative.join(entry.file_name()),
        ) {
            Ok(unit) => unit,
            Err(_) => return None,
        };
        units.push(unit);
    }
    units.sort_by(|left, right| left.relative_path.cmp(&right.relative_path));

    Some(SizeInferenceLayout {
        root_relative,
        units,
    })
}

fn common_path_prefix(paths: &[PathBuf]) -> Option<PathBuf> {
    let first = paths.first()?;
    let mut prefix = first
        .components()
        .map(|component| component.as_os_str().to_os_string())
        .collect::<Vec<_>>();

    for path in &paths[1..] {
        let parts = path
            .components()
            .map(|component| component.as_os_str().to_os_string())
            .collect::<Vec<_>>();
        let length = prefix
            .iter()
            .zip(parts.iter())
            .take_while(|(left, right)| left == right)
            .count();
        prefix.truncate(length);
        if prefix.is_empty() {
            return None;
        }
    }

    let mut path = PathBuf::new();
    for part in prefix {
        path.push(part);
    }
    (!path.as_os_str().is_empty()).then_some(path)
}

fn scan_content_unit(root: &Path, relative_path: PathBuf) -> Result<ContentUnit> {
    let mut total_size = 0u64;
    let mut file_sizes = Vec::new();
    let mut stack = vec![root.to_path_buf()];

    while let Some(directory) = stack.pop() {
        for entry in fs::read_dir(&directory)
            .with_context(|| format!("could not read {}", directory.display()))?
        {
            let entry = entry?;
            let file_type = entry.file_type()?;
            if file_type.is_symlink() {
                continue;
            }
            if file_type.is_dir() {
                stack.push(entry.path());
            } else if file_type.is_file() {
                let size = entry.metadata()?.len();
                total_size = total_size
                    .checked_add(size)
                    .context("content-unit size overflow")?;
                if size > 0 {
                    file_sizes.push(size);
                }
            }
        }
    }

    Ok(ContentUnit {
        relative_path,
        total_size,
        file_sizes,
    })
}

fn match_depot_size(
    metadata: &Obj<'_>,
    branch: &str,
    units: &[ContentUnit],
) -> SizeResolution {
    let active_size = manifest_branch_size(metadata, branch).filter(|size| *size > 0);
    let history_sizes = manifest_history_sizes(metadata);
    if active_size.is_none() && history_sizes.is_empty() {
        return SizeResolution::Unavailable;
    }

    let active_exact = active_size
        .map(|size| matching_units(units, |unit| unit.total_size == size))
        .unwrap_or_default();
    if active_exact.len() == 1 {
        return SizeResolution::Match(SizeMatch::Active);
    }
    if active_exact.len() > 1 {
        return SizeResolution::Ambiguous;
    }

    let historical_exact = matching_units(units, |unit| history_sizes.contains(&unit.total_size));
    if historical_exact.len() == 1 {
        return SizeResolution::Match(SizeMatch::Historical);
    }
    if historical_exact.len() > 1 {
        return SizeResolution::Ambiguous;
    }

    let active_subset = active_size
        .map(|size| matching_units(units, |unit| exact_subset_exclusion_match(unit, size)))
        .unwrap_or_default();
    if active_subset.len() == 1 {
        return SizeResolution::Match(SizeMatch::ActiveSubset);
    }
    if active_subset.len() > 1 {
        return SizeResolution::Ambiguous;
    }

    let historical_subset = matching_units(units, |unit| {
        history_sizes
            .iter()
            .any(|size| exact_subset_exclusion_match(unit, *size))
    });
    if historical_subset.len() == 1 {
        return SizeResolution::Match(SizeMatch::HistoricalSubset);
    }
    if historical_subset.len() > 1 {
        return SizeResolution::Ambiguous;
    }

    let active_ultra = active_size
        .map(|size| matching_units(units, |unit| ultra_close_size_match(unit.total_size, size)))
        .unwrap_or_default();
    if active_ultra.len() == 1 {
        return SizeResolution::Match(SizeMatch::ActiveUltraClose);
    }
    if active_ultra.len() > 1 {
        return SizeResolution::Ambiguous;
    }

    let historical_ultra = matching_units(units, |unit| {
        history_sizes
            .iter()
            .any(|size| ultra_close_size_match(unit.total_size, *size))
    });
    if historical_ultra.len() == 1 {
        return SizeResolution::Match(SizeMatch::HistoricalUltraClose);
    }
    if historical_ultra.len() > 1 {
        return SizeResolution::Ambiguous;
    }

    if active_size.is_some() {
        SizeResolution::NoMatch
    } else {
        SizeResolution::Unavailable
    }
}

fn matching_units<F>(units: &[ContentUnit], mut predicate: F) -> Vec<PathBuf>
where
    F: FnMut(&ContentUnit) -> bool,
{
    units
        .iter()
        .filter(|unit| predicate(unit))
        .map(|unit| unit.relative_path.clone())
        .collect()
}

fn exact_subset_exclusion_match(unit: &ContentUnit, expected_size: u64) -> bool {
    if expected_size == 0 || unit.total_size <= expected_size {
        return false;
    }
    let extra = unit.total_size - expected_size;
    if u128::from(extra) * 100 > u128::from(expected_size) * 5 {
        return false;
    }

    if unit.file_sizes.iter().any(|size| *size == extra) {
        return true;
    }

    let mut seen = BTreeSet::new();
    for size in &unit.file_sizes {
        if *size < extra && seen.contains(&(extra - *size)) {
            return true;
        }
        seen.insert(*size);
    }

    if unit.file_sizes.len() > 256 {
        return false;
    }
    let mut indices_by_size = BTreeMap::<u64, Vec<usize>>::new();
    for (index, size) in unit.file_sizes.iter().copied().enumerate() {
        indices_by_size.entry(size).or_default().push(index);
    }
    for i in 0..unit.file_sizes.len() {
        for j in (i + 1)..unit.file_sizes.len() {
            let Some(pair) = unit.file_sizes[i].checked_add(unit.file_sizes[j]) else {
                continue;
            };
            let Some(need) = extra.checked_sub(pair) else {
                continue;
            };
            if need == 0 {
                continue;
            }
            if indices_by_size
                .get(&need)
                .is_some_and(|indices| indices.iter().any(|index| *index > j))
            {
                return true;
            }
        }
    }
    false
}

fn ultra_close_size_match(actual_size: u64, expected_size: u64) -> bool {
    if actual_size == 0 || expected_size == 0 || actual_size == expected_size {
        return false;
    }
    let delta = actual_size.abs_diff(expected_size);
    delta <= 64 && u128::from(delta) * 1000 <= u128::from(expected_size)
}

fn size_match_source(matches: &[SizeMatch]) -> &'static str {
    if matches.iter().any(|kind| matches!(kind, SizeMatch::ActiveUltraClose | SizeMatch::HistoricalUltraClose)) {
        "ultra_close_size_match"
    } else if matches.iter().any(|kind| matches!(kind, SizeMatch::ActiveSubset | SizeMatch::HistoricalSubset)) {
        "subset_size_match"
    } else if matches.iter().any(|kind| *kind == SizeMatch::Historical) {
        "historical_size_match"
    } else {
        "active_size_match"
    }
}

fn manifest_branch_size(metadata: &Obj<'_>, branch: &str) -> Option<u64> {
    let manifests = object_obj_ci(metadata, "manifests")?;
    let value = object_value_ci(manifests, branch)?;
    value
        .as_obj()
        .and_then(|entry| object_value_ci(entry, "size"))
        .and_then(value_u64)
}

fn manifest_history_sizes(metadata: &Obj<'_>) -> BTreeSet<u64> {
    object_obj_ci(metadata, "manifests")
        .map(|manifests| {
            manifests
                .iter()
                .filter_map(|(_, value)| {
                    value
                        .as_obj()
                        .and_then(|entry| object_value_ci(entry, "size"))
                        .and_then(value_u64)
                })
                .filter(|size| *size > 0)
                .collect()
        })
        .unwrap_or_default()
}

fn record(app_id: u32, state: &'static str, source: &'static str) -> AppRecord {
    AppRecord { app_id, state, source }
}

fn appmanifest_path(base_app_id: u32, install_dir: &Path) -> Result<PathBuf> {
    let steamapps = install_dir
        .parent()
        .and_then(Path::parent)
        .context("game install directory is not under steamapps/common")?;
    let path = steamapps.join(format!("appmanifest_{base_app_id}.acf"));
    if !path.is_file() {
        bail!("base appmanifest was not found: {}", path.display());
    }
    Ok(path)
}

fn associated_depots<'a, 'text>(
    base_app_id: u32,
    dlc_app_id: u32,
    base_record: Option<&'a Obj<'text>>,
    dlc_record: Option<&'a Obj<'text>>,
) -> (Vec<Depot<'a, 'text>>, bool) {
    let mut depots = BTreeMap::<u32, &'a Obj<'text>>::new();

    if let Some(base) = base_record {
        if let Some(entries) = nested_obj_ci(base, &["appinfo", "depots"]) {
            for (key, value) in entries.iter() {
                let Ok(id) = key.parse::<u32>() else { continue };
                let Some(metadata) = value.as_obj() else { continue };
                if recursive_contains_u32(metadata, "dlcappid", dlc_app_id)
                    || recursive_contains_u32(metadata, "depotfromapp", dlc_app_id)
                {
                    depots.insert(id, metadata);
                }
            }
        }
    }

    let listed_by_base = base_record
        .and_then(|base| nested_string_ci(base, &["appinfo", "extended", "listofdlc"]))
        .is_some_and(|list| csv_app_ids(&list).contains(&dlc_app_id));
    let parent = dlc_record
        .and_then(|dlc| nested_value_ci(dlc, &["appinfo", "common", "parent"]))
        .and_then(value_u32);
    let relationship_conflict = parent.is_some_and(|parent| parent != base_app_id) && !listed_by_base;

    if !relationship_conflict {
        if let Some(entries) = dlc_record.and_then(|dlc| nested_obj_ci(dlc, &["appinfo", "depots"])) {
            for (key, value) in entries.iter() {
                let Ok(id) = key.parse::<u32>() else { continue };
                let Some(metadata) = value.as_obj() else { continue };
                depots.entry(id).or_insert(metadata);
            }
        }
    }

    (
        depots
            .into_iter()
            .map(|(id, metadata)| Depot {
                id,
                metadata,
                applicability: Applicability::Unknown,
                installed: false,
            })
            .collect(),
        relationship_conflict,
    )
}

fn applicability(metadata: &Obj<'_>, language: Option<&str>) -> Applicability {
    let Some(config) = object_obj_ci(metadata, "config") else {
        return Applicability::Yes;
    };
    let mut unknown = false;

    if let Some(oslist) = object_string_ci(config, "oslist") {
        if !split_csv(&oslist).iter().any(|value| matches!(value.as_str(), "macos" | "osx" | "mac" | "darwin")) {
            return Applicability::No;
        }
    }

    if let Some(osarch) = object_string_ci(config, "osarch") {
        let aliases = arch_aliases(env::consts::ARCH);
        if !split_csv(&osarch).iter().any(|value| aliases.contains(value.as_str())) {
            return Applicability::No;
        }
    }

    if let Some(languages) = object_string_ci(config, "language") {
        match language {
            Some(language) if split_csv(&languages).iter().any(|value| value.eq_ignore_ascii_case(language)) => {}
            Some(_) => return Applicability::No,
            None => unknown = true,
        }
    }

    if config.keys().any(|key| {
        !matches!(key.to_ascii_lowercase().as_str(), "oslist" | "osarch" | "language" | "dlcappid")
    }) {
        unknown = true;
    }

    if unknown { Applicability::Unknown } else { Applicability::Yes }
}

fn installed_depots(app_state: &Obj<'_>) -> BTreeSet<u32> {
    object_obj_ci(app_state, "InstalledDepots")
        .map(|depots| depots.keys().filter_map(|key| key.parse::<u32>().ok()).collect())
        .unwrap_or_default()
}

fn current_language(app_state: &Obj<'_>) -> Option<String> {
    ["UserConfig", "MountedConfig"].into_iter().find_map(|section| {
        object_obj_ci(app_state, section)
            .and_then(|value| object_string_ci(value, "language"))
            .filter(|value| !value.is_empty())
            .map(|value| value.to_ascii_lowercase())
    })
}

fn current_branch(app_state: &Obj<'_>) -> String {
    for section in ["UserConfig", "MountedConfig"] {
        let Some(config) = object_obj_ci(app_state, section) else { continue };
        for key in ["BetaKey", "betakey", "beta"] {
            if let Some(value) = object_string_ci(config, key).filter(|value| !value.is_empty()) {
                return value;
            }
        }
    }
    "public".to_owned()
}

fn depotcache_dirs(steam_root: &Path, library_root: &Path) -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    for path in [
        steam_root.join("depotcache"),
        library_root.join("depotcache"),
        steam_root.join("steamapps/depotcache"),
        library_root.join("steamapps/depotcache"),
    ] {
        if !dirs.contains(&path) {
            dirs.push(path);
        }
    }
    dirs
}

fn has_cached_manifest(dirs: &[PathBuf], depot_id: u32) -> bool {
    let prefix = format!("{depot_id}_");
    dirs.iter().any(|dir| {
        fs::read_dir(dir).ok().is_some_and(|entries| {
            entries.flatten().any(|entry| {
                let path = entry.path();
                path.is_file()
                    && path
                        .file_name()
                        .and_then(|value| value.to_str())
                        .is_some_and(|name| name.starts_with(&prefix) && name.ends_with(".manifest"))
            })
        })
    })
}

fn manifest_branch_gid(metadata: &Obj<'_>, branch: &str) -> Option<u64> {
    let manifests = object_obj_ci(metadata, "manifests")?;
    let value = object_value_ci(manifests, branch)?;
    value
        .as_obj()
        .and_then(|entry| object_value_ci(entry, "gid"))
        .and_then(value_u64)
        .or_else(|| value_u64(value))
}

fn locate_cached_manifest(dirs: &[PathBuf], depot_id: u32, gid: u64) -> Option<PathBuf> {
    let filename = format!("{depot_id}_{gid}.manifest");
    dirs.iter()
        .map(|dir| dir.join(&filename))
        .find(|path| path.is_file())
}

fn newest_cached_manifest(
    dirs: &[PathBuf],
    depot_id: u32,
    exclude_gid: Option<u64>,
) -> Option<(PathBuf, u64)> {
    let prefix = format!("{depot_id}_");
    let mut newest: Option<(SystemTime, PathBuf, u64)> = None;

    for dir in dirs {
        let Ok(entries) = fs::read_dir(dir) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            if !path.is_file() {
                continue;
            }
            let Some(name) = path.file_name().and_then(|value| value.to_str()) else {
                continue;
            };
            let Some(gid_text) = name
                .strip_prefix(&prefix)
                .and_then(|value| value.strip_suffix(".manifest"))
            else {
                continue;
            };
            let Ok(gid) = gid_text.parse::<u64>() else { continue };
            if exclude_gid == Some(gid) {
                continue;
            }
            let modified = entry
                .metadata()
                .and_then(|metadata| metadata.modified())
                .unwrap_or(SystemTime::UNIX_EPOCH);
            if newest.as_ref().is_none_or(|(best, _, _)| modified > *best) {
                newest = Some((modified, path, gid));
            }
        }
    }

    newest.map(|(_, path, gid)| (path, gid))
}

fn value_u64(value: &Value<'_>) -> Option<u64> {
    if let Some(value) = value.as_u64() {
        return Some(value);
    }
    if let Some(value) = value.as_i32() {
        return u64::try_from(value).ok();
    }
    if let Some(value) = value.as_pointer() {
        return Some(u64::from(value));
    }
    value.as_str()?.trim().parse::<u64>().ok()
}

fn nested_obj_ci<'a, 'text>(root: &'a Obj<'text>, path: &[&str]) -> Option<&'a Obj<'text>> {
    path.iter().try_fold(root, |current, key| object_obj_ci(current, key))
}

fn nested_value_ci<'a, 'text>(root: &'a Obj<'text>, path: &[&str]) -> Option<&'a Value<'text>> {
    let (last, parents) = path.split_last()?;
    object_value_ci(nested_obj_ci(root, parents)?, last)
}

fn nested_string_ci(root: &Obj<'_>, path: &[&str]) -> Option<String> {
    nested_value_ci(root, path)?.as_str().map(str::trim).map(str::to_owned)
}

fn object_obj_ci<'a, 'text>(root: &'a Obj<'text>, key: &str) -> Option<&'a Obj<'text>> {
    object_value_ci(root, key)?.as_obj()
}

fn recursive_contains_u32(root: &Obj<'_>, key: &str, wanted: u32) -> bool {
    root.iter().any(|(candidate, value)| {
        (candidate.eq_ignore_ascii_case(key) && value_u32(value) == Some(wanted))
            || value.as_obj().is_some_and(|child| recursive_contains_u32(child, key, wanted))
    })
}

fn recursive_has_key(root: &Obj<'_>, key: &str) -> bool {
    root.iter().any(|(candidate, value)| {
        candidate.eq_ignore_ascii_case(key)
            || value.as_obj().is_some_and(|child| recursive_has_key(child, key))
    })
}

fn csv_app_ids(value: &str) -> BTreeSet<u32> {
    value
        .split(|character: char| character == ',' || character == ';' || character.is_whitespace())
        .filter_map(|token| token.parse::<u32>().ok())
        .filter(|id| *id != 0)
        .collect()
}

fn split_csv(value: &str) -> Vec<String> {
    value
        .split(',')
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(|value| value.to_ascii_lowercase())
        .collect()
}

fn arch_aliases(arch: &str) -> BTreeSet<&'static str> {
    match arch {
        "aarch64" | "arm64" => BTreeSet::from(["aarch64", "arm64", "64"]),
        "x86_64" | "amd64" | "x64" => BTreeSet::from(["x86_64", "amd64", "x64", "64"]),
        "x86" | "i386" | "i686" => BTreeSet::from(["x86", "i386", "i686", "32"]),
        _ => BTreeSet::new(),
    }
}


#[cfg(test)]
mod tests {
    use super::*;


    fn parsed_app<'a, 'text>(parsed: &'a steam_vdf_parser::Vdf<'text>, app_id: u32) -> &'a Obj<'text> {
        assert_eq!(parsed.key(), app_id.to_string());
        parsed.as_obj().unwrap()
    }

    #[test]
    fn appmanifest_root_is_app_state() {
        let parsed = parse_text(r#"
            "AppState"
            {
                "InstalledDepots"
                {
                    "844811"
                    {
                        "manifest" "123"
                    }
                }
                "UserConfig"
                {
                    "language" "english"
                }
            }
        "#).unwrap();
        let app_state = app_state_object(&parsed).unwrap();
        let installed = installed_depots(app_state);
        let installed_manifest = installed_manifest_gid(app_state, 844811);
        let language = current_language(app_state);


        assert_eq!(installed, BTreeSet::from([844811]));
        assert_eq!(installed_manifest, Some(123));
        assert_eq!(language.as_deref(), Some("english"));
    }

    #[test]
    fn bundled_dlc_is_present_without_separate_depot() {
        let base = parse_text(r#"
            "281990"
            {
                "appinfo"
                {
                    "extended"
                    {
                        "listofdlc" "844810"
                    }
                }
            }
        "#).unwrap();
        let dlc = parse_text(r#"
            "844810"
            {
                "appinfo"
                {
                    "common"
                    {
                        "parent" "281990"
                    }
                }
            }
        "#).unwrap();

        let record = inspect_dlc(
            281990,
            844810,
            Some(parsed_app(&base, 281990)),
            Some(parsed_app(&dlc, 844810)),
            &BTreeSet::new(),
            None,
            "public",
            &[],
            Path::new("/nonexistent"),
        );

        assert_eq!(record.state, "present");
        assert_eq!(record.source, "bundled");
    }

    #[test]
    fn installed_payload_depot_is_present() {
        let base = parse_text(r#"
            "281990"
            {
                "appinfo"
                {
                    "extended"
                    {
                        "listofdlc" "844810"
                    }
                    "depots"
                    {
                        "844811"
                        {
                            "dlcappid" "844810"
                            "manifests"
                            {
                                "public" "123"
                            }
                        }
                    }
                }
            }
        "#).unwrap();
        let dlc = parse_text(r#"
            "844810"
            {
                "appinfo"
                {
                    "common"
                    {
                        "parent" "281990"
                    }
                }
            }
        "#).unwrap();

        let record = inspect_dlc(
            281990,
            844810,
            Some(parsed_app(&base, 281990)),
            Some(parsed_app(&dlc, 844810)),
            &BTreeSet::from([844811]),
            None,
            "public",
            &[],
            Path::new("/nonexistent"),
        );

        assert_eq!(record.state, "present");
        assert_eq!(record.source, "steam_installed_depots");
    }

    #[test]
    fn separate_payload_without_positive_evidence_stays_unknown() {
        let base = parse_text(r#"
            "281990"
            {
                "appinfo"
                {
                    "extended"
                    {
                        "listofdlc" "844810"
                    }
                    "depots"
                    {
                        "844811"
                        {
                            "dlcappid" "844810"
                            "manifests"
                            {
                                "public" "123"
                            }
                        }
                    }
                }
            }
        "#).unwrap();
        let dlc = parse_text(r#"
            "844810"
            {
                "appinfo"
                {
                    "common"
                    {
                        "parent" "281990"
                    }
                }
            }
        "#).unwrap();

        let record = inspect_dlc(
            281990,
            844810,
            Some(parsed_app(&base, 281990)),
            Some(parsed_app(&dlc, 844810)),
            &BTreeSet::new(),
            None,
            "public",
            &[],
            Path::new("/nonexistent"),
        );

        assert_eq!(record.state, "unknown");
        assert_eq!(record.source, "separate_payload_not_installed");
    }

    fn test_root(name: &str) -> PathBuf {
        let root = env::temp_dir().join(format!(
            "miningorca-content-state-{}-{}",
            std::process::id(),
            name
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        root
    }

    #[test]
    fn exact_active_branch_manifest_recovers_present_files() {
        let base = parse_text(r#"
            "281990"
            {
                "appinfo"
                {
                    "extended" { "listofdlc" "844810" }
                    "depots"
                    {
                        "844811"
                        {
                            "dlcappid" "844810"
                            "manifests" { "public" { "gid" "123" } }
                        }
                    }
                }
            }
        "#).unwrap();
        let dlc = parse_text(r#"
            "844810"
            {
                "appinfo" { "common" { "parent" "281990" } }
            }
        "#).unwrap();
        let root = test_root("exact-present");
        let install_dir = root.join("game");
        let depotcache = root.join("depotcache");
        fs::create_dir_all(install_dir.join("content")).unwrap();
        fs::create_dir_all(&depotcache).unwrap();
        fs::write(install_dir.join("content/file.dat"), b"data").unwrap();
        fs::write(
            depotcache.join("844811_123.manifest"),
            synthetic_manifest(844811, 123, r"content\file.dat", 4),
        ).unwrap();

        let record = inspect_dlc(
            281990,
            844810,
            Some(parsed_app(&base, 281990)),
            Some(parsed_app(&dlc, 844810)),
            &BTreeSet::new(),
            None,
            "public",
            &[depotcache],
            &install_dir,
        );
        assert_eq!(record.state, "present");
        assert_eq!(record.source, "exact_manifest");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn exact_manifest_distinguishes_missing_and_incomplete() {
        let root = test_root("exact-negative");
        let install_dir = root.join("game");
        let depotcache = root.join("depotcache");
        fs::create_dir_all(&install_dir).unwrap();
        fs::create_dir_all(&depotcache).unwrap();
        let manifest_path = depotcache.join("844811_123.manifest");
        fs::write(
            &manifest_path,
            synthetic_manifest(844811, 123, "content/file.dat", 4),
        ).unwrap();
        let manifest = parse_manifest_file(&manifest_path).unwrap();

        let missing = verify_manifest_files(&manifest, &install_dir).unwrap();
        fs::create_dir_all(install_dir.join("content")).unwrap();
        fs::write(install_dir.join("content/file.dat"), b"wrong").unwrap();
        let incomplete = verify_manifest_files(&manifest, &install_dir).unwrap();

        assert_eq!(missing, Verification::Missing);
        assert_eq!(incomplete, Verification::Incomplete);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn manifest_paths_reject_backslash_traversal() {
        let result = safe_manifest_relative_path(r"..\escape.dat");
        assert!(result.is_err());
    }

    #[test]
    fn historical_manifest_can_recover_present_files() {
        let base = parse_text(r#"
            "281990"
            {
                "appinfo"
                {
                    "extended" { "listofdlc" "844810" }
                    "depots"
                    {
                        "844811"
                        {
                            "dlcappid" "844810"
                            "manifests" { "public" { "gid" "123" } }
                        }
                    }
                }
            }
        "#).unwrap();
        let dlc = parse_text(r#"
            "844810"
            {
                "appinfo" { "common" { "parent" "281990" } }
            }
        "#).unwrap();
        let root = test_root("historical-present");
        let install_dir = root.join("game");
        let depotcache = root.join("depotcache");
        fs::create_dir_all(install_dir.join("content")).unwrap();
        fs::create_dir_all(&depotcache).unwrap();
        fs::write(install_dir.join("content/file.dat"), b"data").unwrap();
        fs::write(
            depotcache.join("844811_122.manifest"),
            synthetic_manifest(844811, 122, "content/file.dat", 4),
        ).unwrap();

        let record = inspect_dlc(
            281990,
            844810,
            Some(parsed_app(&base, 281990)),
            Some(parsed_app(&dlc, 844810)),
            &BTreeSet::new(),
            None,
            "public",
            &[depotcache],
            &install_dir,
        );
        assert_eq!(record.state, "present");
        assert_eq!(record.source, "historical_manifest");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn historical_manifest_never_proves_missing_files() {
        let base = parse_text(r#"
            "281990"
            {
                "appinfo"
                {
                    "extended" { "listofdlc" "844810" }
                    "depots"
                    {
                        "844811"
                        {
                            "dlcappid" "844810"
                            "manifests" { "public" { "gid" "123" } }
                        }
                    }
                }
            }
        "#).unwrap();
        let dlc = parse_text(r#"
            "844810"
            {
                "appinfo" { "common" { "parent" "281990" } }
            }
        "#).unwrap();
        let root = test_root("historical-negative");
        let install_dir = root.join("game");
        let depotcache = root.join("depotcache");
        fs::create_dir_all(&install_dir).unwrap();
        fs::create_dir_all(&depotcache).unwrap();
        fs::write(
            depotcache.join("844811_122.manifest"),
            synthetic_manifest(844811, 122, "content/file.dat", 4),
        ).unwrap();

        let record = inspect_dlc(
            281990,
            844810,
            Some(parsed_app(&base, 281990)),
            Some(parsed_app(&dlc, 844810)),
            &BTreeSet::new(),
            None,
            "public",
            &[depotcache],
            &install_dir,
        );
        assert_eq!(record.state, "unknown");
        assert_eq!(record.source, "separate_payload_not_installed");
        let _ = fs::remove_dir_all(root);
    }


    #[test]
    fn size_layout_uses_two_exact_manifest_units() {
        let root = test_root("size-layout");
        let install_dir = root.join("game");
        fs::create_dir_all(install_dir.join("dlc/a")).unwrap();
        fs::create_dir_all(install_dir.join("dlc/b")).unwrap();
        fs::create_dir_all(install_dir.join("dlc/c")).unwrap();
        fs::write(install_dir.join("dlc/a/file.dat"), b"aaaa").unwrap();
        fs::write(install_dir.join("dlc/b/file.dat"), b"bbbbb").unwrap();
        fs::write(install_dir.join("dlc/c/file.dat"), b"cccccc").unwrap();

        let layout = infer_size_layout(
            &[PathBuf::from("dlc/a"), PathBuf::from("dlc/b")],
            &install_dir,
        )
        .unwrap();


        assert_eq!(layout.root_relative, PathBuf::from("dlc"));
        assert_eq!(layout.units.len(), 1);
        assert_eq!(layout.units[0].relative_path, PathBuf::from("dlc/c"));
        assert_eq!(layout.units[0].total_size, 6);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn size_match_prefers_active_then_unique_history() {
        let active = parse_text(r#"
            "844811"
            {
                "manifests"
                {
                    "public" { "gid" "123" "size" "6" }
                    "legacy" { "gid" "122" "size" "7" }
                }
            }
        "#).unwrap();
        let history = parse_text(r#"
            "844811"
            {
                "manifests"
                {
                    "public" { "gid" "123" "size" "8" }
                    "legacy" { "gid" "122" "size" "7" }
                }
            }
        "#).unwrap();
        let units = vec![
            ContentUnit { relative_path: PathBuf::from("dlc/c"), total_size: 6, file_sizes: vec![6] },
            ContentUnit { relative_path: PathBuf::from("dlc/d"), total_size: 7, file_sizes: vec![7] },
        ];
        let active_match = match_depot_size(active.as_obj().unwrap(), "public", &units);
        let historical_match = match_depot_size(
            history.as_obj().unwrap(),
            "public",
            &units[1..],
        );


        assert_eq!(active_match, SizeResolution::Match(SizeMatch::Active));
        assert_eq!(historical_match, SizeResolution::Match(SizeMatch::Historical));
    }


    #[test]
    fn size_match_uses_subset_then_ultra_close_fallbacks() {
        let subset = parse_text(r#"
            "844811"
            {
                "manifests" { "public" { "gid" "123" "size" "100" } }
            }
        "#).unwrap();
        let ultra = parse_text(r#"
            "844812"
            {
                "manifests" { "public" { "gid" "124" "size" "100000" } }
            }
        "#).unwrap();
        let subset_units = vec![ContentUnit {
            relative_path: PathBuf::from("dlc/subset"),
            total_size: 105,
            file_sizes: vec![100, 5],
        }];
        let ultra_units = vec![ContentUnit {
            relative_path: PathBuf::from("dlc/ultra"),
            total_size: 100032,
            file_sizes: vec![100032],
        }];

        let subset_match = match_depot_size(
            subset.as_obj().unwrap(),
            "public",
            &subset_units,
        );
        let ultra_match = match_depot_size(
            ultra.as_obj().unwrap(),
            "public",
            &ultra_units,
        );


        assert_eq!(subset_match, SizeResolution::Match(SizeMatch::ActiveSubset));
        assert_eq!(ultra_match, SizeResolution::Match(SizeMatch::ActiveUltraClose));
    }

    #[test]
    fn bundled_storage_does_not_rewrite_per_dlc_evidence() {
        let apps = vec![
            record(404010, "unknown", "insufficient_evidence"),
            record(999999, "unknown", "insufficient_evidence"),
        ];

        let storage = detect_storage_layout(None, true, &apps);
        assert_eq!(storage, StorageLayout::Bundled);


        assert!(apps.iter().all(|app| app.state == "unknown"));
        assert!(apps.iter().all(|app| app.source == "insufficient_evidence"));
    }


    #[test]
    fn shared_unit_size_threshold_detects_content_mixed_into_game_tree() {
        let root = test_root("shared-unit-size");
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join("a.bin"), vec![0u8; 120]).unwrap();
        fs::write(root.join("b.bin"), vec![0u8; 121]).unwrap();

        let shared = directory_size_exceeds(&root, 200).unwrap();
        let dedicated = directory_size_exceeds(&root, 300).unwrap();


        assert!(shared);
        assert!(!dedicated);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn active_size_no_match_is_negative_but_historical_only_is_not() {
        let active = parse_text(r#"
            "844811"
            {
                "manifests" { "public" { "gid" "123" "size" "100" } }
            }
        "#).unwrap();
        let historical_only = parse_text(r#"
            "844812"
            {
                "manifests" { "legacy" { "gid" "122" "size" "100" } }
            }
        "#).unwrap();
        let units = vec![ContentUnit {
            relative_path: PathBuf::from("dlc/other"),
            total_size: 200,
            file_sizes: vec![200],
        }];

        let active_result = match_depot_size(
            active.as_obj().unwrap(),
            "public",
            &units,
        );
        let historical_result = match_depot_size(
            historical_only.as_obj().unwrap(),
            "public",
            &units,
        );


        assert_eq!(active_result, SizeResolution::NoMatch);
        assert_eq!(historical_result, SizeResolution::Unavailable);
    }

}
