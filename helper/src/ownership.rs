use std::collections::{BTreeSet, HashSet};
use std::fs;
use std::path::Path;

use anyhow::{Context, Result, anyhow, bail};
use serde::Serialize;
use steam_vdf_parser::{Obj, parse_packageinfo, parse_text};

use crate::protobuf::{read_length_delimited, read_varint, skip_wire_value};
use crate::steam;
use crate::vdf::{object_obj_ci, object_string_ci, object_value_ci, value_u32};

const STEAM_ID64_BASE: u64 = 76_561_197_960_265_728;
const LICENSECACHE_TRAILER_BYTES: usize = 4;

#[derive(Serialize)]
pub(crate) struct Snapshot {
    account_selected: bool,
    account_id: Option<u32>,
    account_name: Option<String>,
    account_source: Option<&'static str>,
    license_source: Option<&'static str>,
    license_count: usize,
    package_metadata_complete: bool,
    missing_package_metadata_count: usize,
    apps: Vec<AppRecord>,
}

#[derive(Serialize)]
struct AppRecord {
    app_id: u32,
    status: &'static str,
}

#[derive(Clone)]
struct SteamAccount {
    account_id: u32,
    account_name: String,
    source: &'static str,
}

#[derive(Clone)]
struct LoginUser {
    account_id: u32,
    account_name: String,
    auto_login: bool,
    most_recent: bool,
    timestamp: u64,
}

pub(crate) fn inspect(app_ids: &[u32], explicit_steam_root: Option<&Path>) -> Result<Snapshot> {
    let steam_root = steam::root(explicit_steam_root)?;
    let requested: BTreeSet<u32> = app_ids.iter().copied().filter(|id| *id != 0).collect();

    let Some(account) = active_account(&steam_root)? else {
        return Ok(unknown_snapshot(&requested, None));
    };

    let licensecache_path = steam_root
        .join("userdata")
        .join(account.account_id.to_string())
        .join("config")
        .join("licensecache");
    if !licensecache_path.is_file() {
        return Ok(unknown_snapshot(&requested, Some(&account)));
    }

    let encrypted = fs::read(&licensecache_path)
        .with_context(|| format!("could not read {}", licensecache_path.display()))?;
    let licensed_packages = parse_licensecache(&encrypted, account.account_id)
        .with_context(|| format!("could not parse {}", licensecache_path.display()))?;
    if licensed_packages.is_empty() {
        // An empty cache is not sufficient evidence that every requested app is
        // unowned. Treat it as incomplete/stale and fail closed to Unknown.
        return Ok(unknown_snapshot(&requested, Some(&account)));
    }

    // AppTickets are direct AppID-keyed positive evidence. They are not needed
    // to prove non-ownership and must never turn a missing ticket into Not owned.
    let app_tickets = read_app_tickets(&steam_root, account.account_id).unwrap_or_default();

    let packageinfo_path = steam_root.join("appcache").join("packageinfo.vdf");
    let packageinfo_bytes = fs::read(&packageinfo_path)
        .with_context(|| format!("could not read {}", packageinfo_path.display()))?;
    let packageinfo = parse_packageinfo(&packageinfo_bytes)
        .map_err(|error| anyhow!("could not parse {}: {error}", packageinfo_path.display()))?;
    let package_root = packageinfo
        .as_obj()
        .context("packageinfo.vdf root is not an object")?;

    let mut owned_apps = HashSet::<u32>::new();
    let mut missing_package_metadata_count = 0usize;

    for package_id in &licensed_packages {
        match package_object(package_root, *package_id) {
            Some(package) => collect_package_app_ids(package, &mut owned_apps),
            None => missing_package_metadata_count += 1,
        }
    }

    // Steam package 0 is implicitly granted to normal logged-in accounts and is
    // used by some older free apps. It is not necessarily present in licensecache.
    if !licensed_packages.contains(&0) {
        if let Some(package) = package_object(package_root, 0) {
            collect_package_app_ids(package, &mut owned_apps);
        }
    }

    owned_apps.extend(app_tickets);

    let package_metadata_complete = missing_package_metadata_count == 0;
    let apps = requested
        .into_iter()
        .map(|app_id| AppRecord {
            app_id,
            status: if owned_apps.contains(&app_id) {
                "owned"
            } else if package_metadata_complete {
                "not_owned"
            } else {
                "unknown"
            },
        })
        .collect();

    Ok(Snapshot {
        account_selected: true,
        account_id: Some(account.account_id),
        account_name: Some(account.account_name),
        account_source: Some(account.source),
        license_source: Some("licensecache"),
        license_count: licensed_packages.len(),
        package_metadata_complete,
        missing_package_metadata_count,
        apps,
    })
}

fn unknown_snapshot(app_ids: &BTreeSet<u32>, account: Option<&SteamAccount>) -> Snapshot {
    Snapshot {
        account_selected: account.is_some(),
        account_id: account.map(|value| value.account_id),
        account_name: account.map(|value| value.account_name.clone()),
        account_source: account.map(|value| value.source),
        license_source: account.map(|_| "licensecache"),
        license_count: 0,
        package_metadata_complete: false,
        missing_package_metadata_count: 0,
        apps: app_ids
            .iter()
            .copied()
            .map(|app_id| AppRecord {
                app_id,
                status: "unknown",
            })
            .collect(),
    }
}

fn active_account(steam_root: &Path) -> Result<Option<SteamAccount>> {
    let users = login_users(steam_root)?;
    if users.is_empty() {
        return Ok(None);
    }

    // Current Steam clients use AutoLogin instead of the historical MostRecent
    // marker. Prefer it and use Timestamp only to resolve malformed duplicate
    // AutoLogin entries deterministically.
    if let Some(user) = newest_matching(&users, |user| user.auto_login) {
        return Ok(Some(SteamAccount {
            account_id: user.account_id,
            account_name: user.account_name.clone(),
            source: "loginusers.AutoLogin",
        }));
    }

    // registry.vdf also carries the account name Steam intends to auto-login.
    // Use it as a compatibility fallback when loginusers lacks AutoLogin flags.
    if let Some(auto_login_user) = registry_auto_login_user(steam_root)? {
        if let Some(user) = users
            .iter()
            .find(|user| user.account_name.eq_ignore_ascii_case(&auto_login_user))
        {
            return Ok(Some(SteamAccount {
                account_id: user.account_id,
                account_name: user.account_name.clone(),
                source: "registry.AutoLoginUser",
            }));
        }
    }

    // Older clients used MostRecent. Keep this fallback for old Steam installs,
    // but do not guess from directory mtimes when no account marker is available.
    if let Some(user) = newest_matching(&users, |user| user.most_recent) {
        return Ok(Some(SteamAccount {
            account_id: user.account_id,
            account_name: user.account_name.clone(),
            source: "loginusers.MostRecent",
        }));
    }

    Ok(None)
}

fn newest_matching<F>(users: &[LoginUser], predicate: F) -> Option<&LoginUser>
where
    F: Fn(&LoginUser) -> bool,
{
    users
        .iter()
        .filter(|user| predicate(user))
        .max_by_key(|user| user.timestamp)
}

fn login_users(steam_root: &Path) -> Result<Vec<LoginUser>> {
    let path = steam_root.join("config").join("loginusers.vdf");
    if !path.is_file() {
        return Ok(Vec::new());
    }

    let text = fs::read_to_string(&path)
        .with_context(|| format!("could not read {}", path.display()))?;
    let parsed = parse_text(&text)
        .map_err(|error| anyhow!("could not parse {}: {error}", path.display()))?;
    let root = parsed
        .as_obj()
        .context("loginusers.vdf root is not an object")?;
    let users = object_obj_ci(root, "users").unwrap_or(root);

    let mut result = Vec::new();
    for (steam_id_text, value) in users.iter() {
        let Some(user) = value.as_obj() else { continue };
        let Ok(steam_id64) = steam_id_text.parse::<u64>() else { continue };
        let Some(account_id64) = steam_id64.checked_sub(STEAM_ID64_BASE) else { continue };
        let Ok(account_id) = u32::try_from(account_id64) else { continue };
        let Some(account_name) = object_string_ci(user, "AccountName") else { continue };

        result.push(LoginUser {
            account_id,
            account_name,
            auto_login: object_string_ci(user, "AutoLogin").as_deref() == Some("1"),
            most_recent: object_string_ci(user, "MostRecent").as_deref() == Some("1"),
            timestamp: object_string_ci(user, "Timestamp")
                .and_then(|value| value.parse::<u64>().ok())
                .unwrap_or(0),
        });
    }

    Ok(result)
}

fn registry_auto_login_user(steam_root: &Path) -> Result<Option<String>> {
    let path = steam_root.join("registry.vdf");
    if !path.is_file() {
        return Ok(None);
    }

    let text = fs::read_to_string(&path)
        .with_context(|| format!("could not read {}", path.display()))?;
    let parsed = parse_text(&text)
        .map_err(|error| anyhow!("could not parse {}: {error}", path.display()))?;
    let root = parsed
        .as_obj()
        .context("registry.vdf root is not an object")?;
    Ok(find_string_recursive_ci(root, "AutoLoginUser"))
}

fn find_string_recursive_ci(root: &Obj<'_>, key: &str) -> Option<String> {
    for (candidate, value) in root.iter() {
        if candidate.eq_ignore_ascii_case(key) {
            if let Some(value) = value.as_str() {
                return Some(value.trim().to_owned());
            }
        }
        if let Some(child) = value.as_obj() {
            if let Some(value) = find_string_recursive_ci(child, key) {
                return Some(value);
            }
        }
    }
    None
}

fn read_app_tickets(steam_root: &Path, account_id: u32) -> Result<BTreeSet<u32>> {
    let path = steam_root
        .join("userdata")
        .join(account_id.to_string())
        .join("config")
        .join("localconfig.vdf");
    if !path.is_file() {
        return Ok(BTreeSet::new());
    }

    let text = fs::read_to_string(&path)
        .with_context(|| format!("could not read {}", path.display()))?;
    let parsed = parse_text(&text)
        .map_err(|error| anyhow!("could not parse {}: {error}", path.display()))?;
    let root = parsed
        .as_obj()
        .context("localconfig.vdf root is not an object")?;
    let store = object_obj_ci(root, "UserLocalConfigStore").unwrap_or(root);

    Ok(object_obj_ci(store, "apptickets")
        .map(|tickets| {
            tickets
                .keys()
                .filter_map(|key| key.parse::<u32>().ok())
                .collect()
        })
        .unwrap_or_default())
}

fn parse_licensecache(encrypted: &[u8], account_id: u32) -> Result<BTreeSet<u32>> {
    if encrypted.len() <= LICENSECACHE_TRAILER_BYTES {
        bail!("licensecache is too short");
    }

    let mut random = RandomStream::new(account_id);
    let mut decrypted = Vec::with_capacity(encrypted.len());
    for byte in encrypted {
        decrypted.push(*byte ^ random.random_char());
    }
    decrypted.truncate(decrypted.len() - LICENSECACHE_TRAILER_BYTES);

    parse_client_license_list(&decrypted)
}

struct RandomStream {
    idum: i64,
    iy: i64,
    iv: [i64; 32],
}

impl RandomStream {
    const MAX_RANDOM_RANGE: u32 = 0x7fff_ffff;
    const NTAB: usize = 32;
    const IA: i64 = 16_807;
    const IM: i64 = 2_147_483_647;
    const IQ: i64 = 127_773;
    const IR: i64 = 2_836;
    const NDIV: i64 = 1 + (Self::IM - 1) / Self::NTAB as i64;

    fn new(seed: u32) -> Self {
        // Steam's implementation accepts a signed 32-bit seed. AccountID is a
        // uint32, so preserve the bit pattern when crossing that ABI boundary.
        let signed_seed = seed as i32 as i64;
        let idum = if signed_seed < 0 {
            signed_seed
        } else {
            -signed_seed
        };
        Self {
            idum,
            iy: 0,
            iv: [0; Self::NTAB],
        }
    }

    fn generate_random_number(&mut self) -> i64 {
        if self.idum <= 0 || self.iy == 0 {
            if -self.idum < 1 {
                self.idum = 1;
            } else {
                self.idum = -self.idum;
            }

            for j in (0..=(Self::NTAB + 7)).rev() {
                let k = self.idum / Self::IQ;
                self.idum = Self::IA * (self.idum - k * Self::IQ) - Self::IR * k;
                if self.idum < 0 {
                    self.idum += Self::IM;
                }
                if j < Self::NTAB {
                    self.iv[j] = self.idum;
                }
            }
            self.iy = self.iv[0];
        }

        let k = self.idum / Self::IQ;
        self.idum = Self::IA * (self.idum - k * Self::IQ) - Self::IR * k;
        if self.idum < 0 {
            self.idum += Self::IM;
        }

        let mut j = self.iy / Self::NDIV;
        if !(0..Self::NTAB as i64).contains(&j) {
            j = (j % Self::NTAB as i64) & 0x7fff_ffff;
        }
        self.iy = self.iv[j as usize];
        self.iv[j as usize] = self.idum;
        self.iy
    }

    fn random_int(&mut self, low: u32, high: u32) -> u32 {
        let width = high - low + 1;
        if width <= 1 || Self::MAX_RANDOM_RANGE < width - 1 {
            return low;
        }

        let max_acceptable = Self::MAX_RANDOM_RANGE
            - ((Self::MAX_RANDOM_RANGE + 1) % width);
        loop {
            let number = self.generate_random_number() as u32;
            if number <= max_acceptable {
                return low + (number % width);
            }
        }
    }

    fn random_char(&mut self) -> u8 {
        self.random_int(32, 126) as u8
    }
}

fn parse_client_license_list(data: &[u8]) -> Result<BTreeSet<u32>> {
    let mut packages = BTreeSet::new();
    let mut cursor = 0usize;

    while cursor < data.len() {
        let key = read_varint(data, &mut cursor)?;
        let field = key >> 3;
        let wire = (key & 0x07) as u8;
        if field == 0 {
            bail!("protobuf contains field number 0");
        }

        if field == 2 && wire == 2 {
            let license = read_length_delimited(data, &mut cursor)?;
            if let Some(package_id) = parse_license_package_id(license)? {
                packages.insert(package_id);
            }
        } else {
            skip_wire_value(data, &mut cursor, wire)?;
        }
    }

    Ok(packages)
}

fn parse_license_package_id(data: &[u8]) -> Result<Option<u32>> {
    let mut cursor = 0usize;
    let mut package_id = None;

    while cursor < data.len() {
        let key = read_varint(data, &mut cursor)?;
        let field = key >> 3;
        let wire = (key & 0x07) as u8;
        if field == 0 {
            bail!("protobuf license contains field number 0");
        }

        if field == 1 && wire == 0 {
            package_id = Some(u32::try_from(read_varint(data, &mut cursor)?)
                .context("package_id does not fit in uint32")?);
        } else {
            skip_wire_value(data, &mut cursor, wire)?;
        }
    }

    Ok(package_id)
}

#[cfg(test)]
mod tests {
    use super::*;


    #[test]
    fn valve_random_stream_matches_known_account_vector() {
        let mut random = RandomStream::new(61_200_707);
        let actual: Vec<u8> = (0..16).map(|_| random.random_char()).collect();
        let expected = vec![43, 119, 76, 49, 39, 103, 84, 124, 42, 59, 118, 123, 52, 81, 77, 33];

        assert_eq!(actual, expected);
    }

    #[test]
    fn protobuf_parser_extracts_package_ids_and_skips_unknown_fields() {
        // CMsgClientLicenseList { eresult: 1, licenses: [{package_id: 42},
        // {package_id: 70000, time_created: 123}], unknown_field_9: "x" }
        let bytes = [
            0x08, 0x01,
            0x12, 0x02, 0x08, 0x2a,
            0x12, 0x09, 0x08, 0xf0, 0xa2, 0x04, 0x15, 0x7b, 0x00, 0x00, 0x00,
            0x4a, 0x01, b'x',
        ];
        let packages = parse_client_license_list(&bytes).unwrap();

        assert_eq!(packages, BTreeSet::from([42, 70_000]));
    }

    #[test]
    fn licensecache_roundtrip_uses_trailing_four_byte_footer() {
        let protobuf = [0x08, 0x01, 0x12, 0x03, 0x08, 0xac, 0x02]; // package 300
        let mut plaintext = protobuf.to_vec();
        plaintext.extend_from_slice(&[0xde, 0xad, 0xbe, 0xef]);

        let mut random = RandomStream::new(61_200_707);
        let encrypted: Vec<u8> = plaintext
            .iter()
            .map(|byte| *byte ^ random.random_char())
            .collect();

        let packages = parse_licensecache(&encrypted, 61_200_707).unwrap();

        assert_eq!(packages, BTreeSet::from([300]));
    }
}

fn package_object<'a, 'text>(root: &'a Obj<'text>, package_id: u32) -> Option<&'a Obj<'text>> {
    let key = package_id.to_string();

    // steam-vdf-parser normally exposes package payloads directly under numeric
    // root keys. Be deliberately conservative if a cache/parser variant adds an
    // extra wrapper: an unrecognised package must make ownership Unknown rather
    // than accidentally turning it into Not owned.
    let mut candidates = Vec::<&Obj<'text>>::new();

    if let Some(package) = root.get(key.as_str()).and_then(|value| value.as_obj()) {
        candidates.push(package);
        if let Some(nested) = object_obj_ci(package, key.as_str()) {
            candidates.push(nested);
        }
        for wrapper_key in ["data", "packageinfo"] {
            if let Some(wrapper) = object_obj_ci(package, wrapper_key) {
                candidates.push(wrapper);
                if let Some(nested) = object_obj_ci(wrapper, key.as_str()) {
                    candidates.push(nested);
                }
            }
        }
    }

    for wrapper_key in ["data", "packageinfo"] {
        if let Some(wrapper) = object_obj_ci(root, wrapper_key) {
            if let Some(package) = wrapper.get(key.as_str()).and_then(|value| value.as_obj()) {
                candidates.push(package);
                if let Some(nested) = object_obj_ci(package, key.as_str()) {
                    candidates.push(nested);
                }
            }
        }
    }

    if let Some(package) = candidates
        .iter()
        .copied()
        .find(|candidate| object_obj_ci(candidate, "appids").is_some())
    {
        return Some(package);
    }

    candidates
        .into_iter()
        .find(|candidate| object_value_ci(candidate, "packageid").is_some())
}

fn collect_package_app_ids(package: &Obj<'_>, destination: &mut HashSet<u32>) {
    let Some(appids) = object_obj_ci(package, "appids") else {
        return;
    };
    for value in appids.values() {
        if let Some(app_id) = value_u32(value) {
            if app_id != 0 {
                destination.insert(app_id);
            }
        }
    }
}
