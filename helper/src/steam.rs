use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

pub(crate) fn root(explicit: Option<&Path>) -> Result<PathBuf> {
    match explicit {
        Some(path) => Ok(path.to_owned()),
        None => Ok(steamlocate::locate()
            .context("Steam installation was not found")?
            .path()
            .to_owned()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn explicit_root_is_returned_without_lookup_or_normalization() {
        let explicit = Path::new("../synthetic-steam-root");
        assert_eq!(root(Some(explicit)).unwrap(), explicit.to_path_buf());
    }
}
