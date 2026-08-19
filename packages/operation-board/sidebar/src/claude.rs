use anyhow::{Context, Result};
use std::fs;
use std::path::Path;
use std::path::PathBuf;

/// Get the path to the Claude Code configuration file
fn get_config_path() -> Option<PathBuf> {
    home::home_dir().map(|h| h.join(".claude.json"))
}

/// Prunes entries from ~/.claude.json that point to non-existent directories.
/// Returns the number of entries removed.
pub fn prune_stale_entries() -> Result<usize> {
    let config_path = match get_config_path() {
        Some(path) if path.exists() => path,
        Some(path) => {
            println!("No Claude configuration found at {}", path.display());
            return Ok(0);
        }
        None => {
            println!("Could not determine home directory");
            return Ok(0);
        }
    };

    let contents = fs::read_to_string(&config_path)
        .with_context(|| format!("Failed to read Claude config: {:?}", config_path))?;

    let mut config_value: serde_json::Value = serde_json::from_str(&contents)
        .with_context(|| format!("Failed to parse Claude config: {:?}", config_path))?;

    let projects = match config_value
        .as_object_mut()
        .and_then(|root| root.get_mut("projects"))
        .and_then(|projects| projects.as_object_mut())
    {
        Some(projects) => projects,
        None => {
            println!("No projects section found in {}", config_path.display());
            return Ok(0);
        }
    };

    let original_len = projects.len();
    let mut stale_paths = Vec::new();

    for path_str in projects.keys() {
        let path = Path::new(path_str);
        // Only consider absolute paths that don't exist
        // We keep relative paths and existing paths
        if path.is_absolute() && !path.exists() {
            println!("  - Removing: {}", path.display());
            stale_paths.push(path_str.clone());
        }
    }

    let removed_count = stale_paths.len();

    for path_str in &stale_paths {
        projects.remove(path_str);
    }

    if removed_count > 0 {
        // Create a backup
        let backup_path = config_path.with_extension("json.bak");
        fs::copy(&config_path, &backup_path).with_context(|| {
            format!(
                "Failed to create backup of Claude config at {:?}",
                backup_path
            )
        })?;
        println!("\n✓ Created backup at {}", backup_path.display());

        // Write the new file
        let new_contents = serde_json::to_string_pretty(&config_value)?;
        fs::write(&config_path, new_contents).with_context(|| {
            format!("Failed to write updated Claude config to {:?}", config_path)
        })?;

        println!(
            "✓ Removed {} stale {} from {}",
            removed_count,
            if removed_count == 1 {
                "entry"
            } else {
                "entries"
            },
            config_path.display()
        );
    } else {
        println!(
            "No stale entries found in {} ({} total {})",
            config_path.display(),
            original_len,
            if original_len == 1 {
                "entry"
            } else {
                "entries"
            }
        );
    }

    Ok(removed_count)
}
