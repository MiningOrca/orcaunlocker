use anyhow::{Context, Result, bail};

pub(crate) fn read_varint(data: &[u8], cursor: &mut usize) -> Result<u64> {
    let mut result = 0u64;
    for shift in (0..70).step_by(7) {
        let Some(&byte) = data.get(*cursor) else {
            bail!("truncated protobuf varint");
        };
        *cursor += 1;

        if shift == 63 && byte > 1 {
            bail!("protobuf varint overflows uint64");
        }
        result |= u64::from(byte & 0x7f) << shift;
        if byte & 0x80 == 0 {
            return Ok(result);
        }
    }
    bail!("protobuf varint is too long")
}

pub(crate) fn read_length_delimited<'a>(data: &'a [u8], cursor: &mut usize) -> Result<&'a [u8]> {
    let length = usize::try_from(read_varint(data, cursor)?)
        .context("protobuf length does not fit in usize")?;
    let end = cursor
        .checked_add(length)
        .context("protobuf length overflow")?;
    let value = data
        .get(*cursor..end)
        .context("truncated protobuf length-delimited field")?;
    *cursor = end;
    Ok(value)
}

pub(crate) fn skip_wire_value(data: &[u8], cursor: &mut usize, wire: u8) -> Result<()> {
    match wire {
        0 => {
            let _ = read_varint(data, cursor)?;
        }
        1 => advance(data, cursor, 8)?,
        2 => {
            let length = usize::try_from(read_varint(data, cursor)?)
                .context("protobuf length does not fit in usize")?;
            advance(data, cursor, length)?;
        }
        5 => advance(data, cursor, 4)?,
        3 | 4 => bail!("protobuf groups are not supported"),
        _ => bail!("invalid protobuf wire type {wire}"),
    }
    Ok(())
}

fn advance(data: &[u8], cursor: &mut usize, count: usize) -> Result<()> {
    let end = cursor.checked_add(count).context("protobuf offset overflow")?;
    if end > data.len() {
        bail!("truncated protobuf field");
    }
    *cursor = end;
    Ok(())
}
