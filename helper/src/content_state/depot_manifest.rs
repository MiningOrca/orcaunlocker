use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};

use crate::protobuf::{read_length_delimited, read_varint, skip_wire_value};

const MANIFEST_PAYLOAD_MAGIC: u32 = 0x71F6_17D0;
const MANIFEST_METADATA_MAGIC: u32 = 0x1F48_12BE;
const MANIFEST_SIGNATURE_MAGIC: u32 = 0x1B81_B817;
const MANIFEST_END_MAGIC: u32 = 0x32C4_15AB;
pub(super) const DEPOT_FILE_DIRECTORY: u64 = 64;
pub(super) const DEPOT_FILE_SYMLINK: u64 = 512;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Verification {
    Present,
    Missing,
    Incomplete,
    Unknown,
}

pub(super) struct ManifestFile {
    pub(super) filename: Option<String>,
    size: u64,
    pub(super) flags: u64,
    pub(super) has_linktarget: bool,
}

pub(super) struct DepotManifest {
    pub(super) depot_id: Option<u32>,
    pub(super) manifest_gid: Option<u64>,
    filenames_encrypted: Option<bool>,
    pub(super) disk_original: Option<u64>,
    pub(super) files: Vec<ManifestFile>,
}

pub(super) fn parse_manifest_file(path: &Path) -> Result<DepotManifest> {
    let data = fs::read(path).with_context(|| format!("could not read {}", path.display()))?;
    let mut cursor = 0usize;
    let mut payload_section = None;
    let mut metadata_section = None;

    while cursor + 4 <= data.len() {
        let magic = read_u32_le(&data, &mut cursor)?;
        if magic == MANIFEST_END_MAGIC {
            break;
        }
        let size = usize::try_from(read_u32_le(&data, &mut cursor)?)
            .context("Steam manifest section size does not fit usize")?;
        let end = cursor
            .checked_add(size)
            .context("Steam manifest section offset overflow")?;
        let section = data
            .get(cursor..end)
            .with_context(|| format!("Steam manifest section overruns {}", path.display()))?;
        cursor = end;

        match magic {
            MANIFEST_PAYLOAD_MAGIC => payload_section = Some(section),
            MANIFEST_METADATA_MAGIC => metadata_section = Some(section),
            MANIFEST_SIGNATURE_MAGIC => {}
            _ => bail!(
                "unknown Steam manifest section magic 0x{magic:08x} in {}",
                path.display()
            ),
        }
    }

    let payload = payload_section
        .with_context(|| format!("manifest has no payload section: {}", path.display()))?;
    let metadata = metadata_section
        .with_context(|| format!("manifest has no metadata section: {}", path.display()))?;

    let metadata_fields = protobuf_fields(metadata)?;
    let depot_id = first_varint(&metadata_fields, 1).and_then(|value| u32::try_from(value).ok());
    let manifest_gid = first_varint(&metadata_fields, 2);
    let filenames_encrypted = first_varint(&metadata_fields, 4).map(|value| value != 0);
    let disk_original = first_varint(&metadata_fields, 5);

    let mut files = Vec::new();
    for field in protobuf_fields(payload)? {
        let ProtoValue::Bytes(mapping) = field.value else { continue };
        if field.number != 1 || field.wire_type != 2 {
            continue;
        }

        let mut filename_raw = None;
        let mut size = 0u64;
        let mut flags = 0u64;
        let mut has_linktarget = false;
        for mapping_field in protobuf_fields(mapping)? {
            match (mapping_field.number, mapping_field.wire_type, mapping_field.value) {
                (1, 2, ProtoValue::Bytes(value)) => filename_raw = Some(value),
                (2, 0, ProtoValue::Varint(value)) => size = value,
                (3, 0, ProtoValue::Varint(value)) => flags = value,
                (7, 2, ProtoValue::Bytes(value)) => has_linktarget = !value.is_empty(),
                _ => {}
            }
        }

        let filename_raw = filename_raw
            .with_context(|| format!("manifest mapping without filename in {}", path.display()))?;
        let filename = if filenames_encrypted == Some(false) {
            Some(
                std::str::from_utf8(filename_raw)
                    .with_context(|| format!("non-UTF8 clear filename in {}", path.display()))?
                    .to_owned(),
            )
        } else {
            None
        };
        files.push(ManifestFile {
            filename,
            size,
            flags,
            has_linktarget,
        });
    }

    if files.is_empty() && disk_original.is_some_and(|size| size != 0) {
        bail!(
            "manifest payload decoded zero file mappings but metadata reports {} bytes: {}",
            disk_original.unwrap_or_default(),
            path.display()
        );
    }

    Ok(DepotManifest {
        depot_id,
        manifest_gid,
        filenames_encrypted,
        disk_original,
        files,
    })
}

pub(super) fn verify_manifest_files(
    manifest: &DepotManifest,
    install_dir: &Path,
) -> Result<Verification> {
    if manifest.filenames_encrypted != Some(false) {
        return Ok(Verification::Unknown);
    }

    let mut regular_present = 0usize;
    let mut missing = 0usize;
    let mut mismatch = 0usize;

    for file in &manifest.files {
        let Some(filename) = file.filename.as_deref() else {
            return Ok(Verification::Unknown);
        };
        let relative = safe_manifest_relative_path(filename)?;
        let path = install_dir.join(relative);

        if file.flags & DEPOT_FILE_DIRECTORY != 0 {
            continue;
        }
        if file.flags & DEPOT_FILE_SYMLINK != 0 || file.has_linktarget {
            match fs::symlink_metadata(&path) {
                Ok(_) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => missing += 1,
                Err(error) => {
                    return Err(error).with_context(|| format!("could not stat {}", path.display()));
                }
            }
            continue;
        }

        match fs::metadata(&path) {
            Ok(metadata) if metadata.is_file() && metadata.len() == file.size => regular_present += 1,
            Ok(_) => mismatch += 1,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => missing += 1,
            Err(error) => {
                return Err(error).with_context(|| format!("could not stat {}", path.display()));
            }
        }
    }

    let expected_material = regular_present + missing + mismatch;
    if missing == 0 && mismatch == 0 {
        Ok(Verification::Present)
    } else if expected_material > 0 && missing == expected_material && mismatch == 0 {
        Ok(Verification::Missing)
    } else {
        Ok(Verification::Incomplete)
    }
}

pub(super) fn safe_manifest_relative_path(name: &str) -> Result<PathBuf> {
    let normalized = name.replace('\\', "/");
    if normalized.starts_with('/') {
        bail!("unsafe absolute manifest filename {name:?}");
    }

    let mut path = PathBuf::new();
    for part in normalized.split('/') {
        match part {
            "" | "." => {}
            ".." => bail!("unsafe manifest filename {name:?}"),
            value => path.push(value),
        }
    }
    if path.as_os_str().is_empty() {
        bail!("empty manifest filename {name:?}");
    }
    Ok(path)
}

#[derive(Clone, Copy)]
struct ProtoField<'a> {
    number: u64,
    wire_type: u8,
    value: ProtoValue<'a>,
}

#[derive(Clone, Copy)]
enum ProtoValue<'a> {
    Varint(u64),
    Bytes(&'a [u8]),
    Other,
}

fn protobuf_fields(data: &[u8]) -> Result<Vec<ProtoField<'_>>> {
    let mut cursor = 0usize;
    let mut fields = Vec::new();
    while cursor < data.len() {
        let key = read_varint(data, &mut cursor)?;
        let number = key >> 3;
        let wire_type = (key & 7) as u8;
        if number == 0 {
            bail!("invalid protobuf field number 0");
        }

        let value = match wire_type {
            0 => ProtoValue::Varint(read_varint(data, &mut cursor)?),
            2 => ProtoValue::Bytes(read_length_delimited(data, &mut cursor)?),
            1 | 5 => {
                skip_wire_value(data, &mut cursor, wire_type)?;
                ProtoValue::Other
            }
            _ => {
                skip_wire_value(data, &mut cursor, wire_type)?;
                ProtoValue::Other
            }
        };
        fields.push(ProtoField {
            number,
            wire_type,
            value,
        });
    }
    Ok(fields)
}

fn first_varint(fields: &[ProtoField<'_>], number: u64) -> Option<u64> {
    fields.iter().find_map(|field| match field {
        ProtoField {
            number: candidate,
            wire_type: 0,
            value: ProtoValue::Varint(value),
        } if *candidate == number => Some(*value),
        _ => None,
    })
}

fn read_u32_le(data: &[u8], cursor: &mut usize) -> Result<u32> {
    let end = cursor.checked_add(4).context("Steam manifest offset overflow")?;
    let bytes = data
        .get(*cursor..end)
        .context("truncated Steam manifest u32")?;
    *cursor = end;
    Ok(u32::from_le_bytes(bytes.try_into().unwrap()))
}

#[cfg(test)]
pub(super) fn synthetic_manifest(
    depot_id: u32,
    gid: u64,
    filename: &str,
    size: u64,
) -> Vec<u8> {
    fn push_varint(out: &mut Vec<u8>, mut value: u64) {
        loop {
            let mut byte = (value & 0x7f) as u8;
            value >>= 7;
            if value != 0 {
                byte |= 0x80;
            }
            out.push(byte);
            if value == 0 {
                break;
            }
        }
    }

    fn push_varint_field(out: &mut Vec<u8>, number: u64, value: u64) {
        push_varint(out, number << 3);
        push_varint(out, value);
    }

    fn push_bytes_field(out: &mut Vec<u8>, number: u64, value: &[u8]) {
        push_varint(out, (number << 3) | 2);
        push_varint(out, value.len() as u64);
        out.extend_from_slice(value);
    }

    let mut mapping = Vec::new();
    push_bytes_field(&mut mapping, 1, filename.as_bytes());
    push_varint_field(&mut mapping, 2, size);
    push_varint_field(&mut mapping, 3, 0);

    let mut payload = Vec::new();
    push_bytes_field(&mut payload, 1, &mapping);

    let mut metadata = Vec::new();
    push_varint_field(&mut metadata, 1, u64::from(depot_id));
    push_varint_field(&mut metadata, 2, gid);
    push_varint_field(&mut metadata, 4, 0);
    push_varint_field(&mut metadata, 5, size);

    let mut data = Vec::new();
    for (magic, section) in [
        (MANIFEST_PAYLOAD_MAGIC, payload.as_slice()),
        (MANIFEST_METADATA_MAGIC, metadata.as_slice()),
    ] {
        data.extend_from_slice(&magic.to_le_bytes());
        data.extend_from_slice(&(section.len() as u32).to_le_bytes());
        data.extend_from_slice(section);
    }
    data.extend_from_slice(&MANIFEST_END_MAGIC.to_le_bytes());
    data
}
