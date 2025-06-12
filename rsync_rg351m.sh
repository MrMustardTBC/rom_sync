#!/bin/bash

set -euo pipefail # Exit on error, unset variables, and pipe failures
IFS=$'\n\t' 

log_file="${0}.log" # Log to a file named after the script

silent_mode=false  # Default: logging enabled
min_free_space_gb=2  # Minimum free space in GB
purge_target=false # New flag for purging files from target not in source

# Source common parameters
if [ -f "./common_config.sh" ]; then
  source "./common_config.sh"
else
  echo "Error: common_config.sh not found."
  exit 1
fi

# Source script-specific parameters
if [ -f "./rsync_rg351m_config.sh" ]; then
  source "./rsync_rg351m_config.sh"
else
  echo "Error: rsync_rg351m_config.sh not found."
  exit 1
fi


declare -A reverse_rename_folders
for original in "${!rename_folders[@]}"; do
  new="${rename_folders[$original]}"
  reverse_rename_folders["$new"]="$original"
done

# --- Function to handle logging ---
log_message() {
  local message="$1"
  if ! "$silent_mode"; then
    local timestamp=$(date "+%Y-%m-%dT%H:%M:%S%z")
    echo "$timestamp - $message"
  fi
  local timestamp=$(date "+%Y-%m-%dT%H:%M:%S%z")
  echo "$timestamp - $message" >> "$log_file"
}

check_dir_exists() {
  local dir="$1"
  if [ ! -d "$dir" ]; then
    log_message "Error: Directory '$dir' not found." >&2
    exit 1
  fi
}

check_free_space() {
  local dir="$1"
  local required_gb="$2"
  local free_kb=$(df -k "$dir" | tail -n 1 | awk '{print $4}')
  local free_bytes=$((free_kb * 1024))  # Convert KB to bytes
  local free_gb=$((free_bytes / 1024 / 1024 / 1024))

  if [ "$free_gb" -lt "$required_gb" ]; then
    log_message "Error: Insufficient free space on '$dir'. Required: $required_gb GB, Available: $free_gb GB" >&2
    exit 1
  fi
}

merge_favorites() {
  local system_name="$1"
  local source_rom_dir="${GLOBAL_SOURCE_BASE}/${system_name}"
  local gamelist_source="${source_rom_dir}/gamelist.xml"
  local gamelist_target_existing="${target_dir}/${system_name}/gamelist.xml"

  log_message "Attempting to merge favorites for $system_name (pre-rsync)..."

  if [ ! -f "$gamelist_source" ]; then
    log_message "  - Debug: Source gamelist.xml not found: '$gamelist_source'. Skipping favorite merge for this system."
    return 0
  fi

  if [ -f "$gamelist_target_existing" ] && command -v xmlstarlet &> /dev/null; then
    favorites=$(xmlstarlet sel -t -m "/data/game[favorite='true']" -c "." "$gamelist_target_existing")

    if [ -n "$favorites" ]; then
      local gamelist_source_temp="${gamelist_source}.temp"
      cp "$gamelist_source" "$gamelist_source_temp" || {
        log_message "Error: Failed to create temporary gamelist file." >&2
        return 1
      }

      while IFS= read -r favorite_game_xml; do
        local old_path=$(echo "$favorite_game_xml" | xmlstarlet sel -t -v "path")
        local old_name=$(echo "$favorite_game_xml" | xmlstarlet sel -t -v "name")

        if xmlstarlet ed -L -u "/data/game[path='$old_path']/favorite" -v "true" "$gamelist_source_temp"; then
          log_message "  - Favorite marked (by path): $old_path"
        elif [ -n "$old_name" ]; then
          if xmlstarlet ed -L -u "/data/game[name='$old_name']/favorite" -v "true" "$gamelist_source_temp"; then
            log_message "  - Favorite marked (by name): $old_name"
          fi
        fi
      done <<< "$favorites"

      mv "$gamelist_source_temp" "$gamelist_source" || {
        log_message "Error: Failed to replace original gamelist file." >&2
        rm -f "$gamelist_source_temp"
        return 1
      }
      sync
    else
      log_message "  - No favorites found in old gamelist."
    fi
  else
    log_message "  - Debug: Old gamelist.xml not found or xmlstarlet not installed for $system_name."
  fi
  return 0
}

# --- Check for silent mode and process arguments ---
# Using a more robust argument parsing with case statement
targeted_systems=() # Initialize array
for arg in "$@"; do
  case "$arg" in
    -s|--silent)
      silent_mode=true
      ;;
    --purge) # New flag for purging
      purge_target=true
      ;;
    *)
      targeted_systems+=("$arg")
      ;;
  esac
done

# --- Check for targeted update arguments ---
if [ ${#targeted_systems[@]} -gt 0 ]; then
  log_message "Targeted update for: ${targeted_systems[@]}"
else
    log_message "Full sync from: ${GLOBAL_SOURCE_BASE}"
    # When doing a full sync, populate targeted_systems with all non-excluded source directories
    find_output=$(find "${GLOBAL_SOURCE_BASE}" -maxdepth 1 -type d -print0 | xargs -0 -n 1 basename)
    for system_name in $find_output; do
        is_excluded=false
        for exclude_dir in "${exclude_dirs[@]}"; do
          if [ "$system_name" = "$exclude_dir" ]; then
            is_excluded=true
            break
          fi
        done
        if [[ -d "${GLOBAL_SOURCE_BASE}/${system_name}" ]] && ! "$is_excluded"; then
            targeted_systems+=("$system_name")
            log_message "  - Found system for full sync: $system_name"
        fi
    done
fi

log_message "Targeted systems: ${targeted_systems[@]}"

# --- Check if source and target base directories exist ---
log_message "Checking for source directory: $GLOBAL_SOURCE_BASE"
check_dir_exists "$GLOBAL_SOURCE_BASE"
log_message "Checking for target directory: $target_dir"
check_dir_exists "$target_dir"

# --- Check free space on target ---
check_free_space "$target_dir" "$min_free_space_gb"

# --- Reverse Renaming for System Folders on Target (Pre-rsync) ---
log_message "Reverse renaming system folders on target device (pre-rsync)..."
for new_name in "${!reverse_rename_folders[@]}"; do
  original_name="${reverse_rename_folders[$new_name]}"
  is_targeted=false
  # If doing full sync, or if the original/new name is explicitly targeted
  if [ ${#targeted_systems[@]} -eq 0 ]; then # Full sync, unrename everything
      is_targeted=true
  else # Targeted sync, only unrename if it's one of the targeted systems
      for target in "${targeted_systems[@]}"; do
          if [[ "$target" == "$original_name" ]] || [[ "$target" == "$new_name" ]]; then
              is_targeted=true
              break
          fi
      done
  fi

  if "$is_targeted"; then
    target_new_dir="${target_dir}/${new_name}"
    target_original_dir="${target_dir}/${original_name}"
    if [ -d "$target_new_dir" ]; then
      log_message "  - Renaming '$target_new_dir' back to '$target_original_dir'"
      mv "$target_new_dir" "$target_original_dir" || log_message "Warning: Failed to rename '$target_new_dir'."
    fi
  fi
done
sync # Ensure renames are flushed before rsync
log_message "Finished reverse renaming."


# --- Merge Favorites ---
log_message "Merging favorites (before rsync)..."
for system in "${targeted_systems[@]}"; do
  log_message "begin merge for $system"
  merge_favorites "$system"
  log_message "end merge for $system"
done
sync

# --- rsync systems directly ---
log_message "Syncing systems..."
rsync_command="rsync $GLOBAL_RSYNC_OPTIONS"

# Add --delete flag if purge_target is true
if "$purge_target"; then
  rsync_command+=" --delete"
  log_message "Purge mode enabled: rsync will delete extraneous files from target."
fi

# Build the rsync command with individual source system paths
for system in "${targeted_systems[@]}"; do
  rsync_command+=" \"${GLOBAL_SOURCE_BASE}/${system}\""
done
rsync_command+=" \"${target_dir}/\""

# Dynamically add excludes: only exclude if not explicitly targeted
for dir in "${exclude_dirs[@]}"; do
  should_exclude=true
  for targeted_sys in "${targeted_systems[@]}"; do
    if [ "$dir" = "$targeted_sys" ]; then
      should_exclude=false
      break
    fi
  done
  if "$should_exclude"; then
    rsync_command+=" --exclude=\"$dir\""
  fi
done

# Only execute rsync if there are systems to sync or if purge is active for a full sync
if [ ${#targeted_systems[@]} -gt 0 ] || "$purge_target"; then # Ensure rsync runs for full purge even if no specific systems are found
  log_message "running rsync: $rsync_command"
  eval "$rsync_command" 2>> "$log_file" || {
    rsync_err=$(tail -n 5 "$log_file") # Capture full stderr
    log_message "Error: rsync operation failed. Details: $rsync_err" >&2
    echo "rsync error: $rsync_err" >&2
    exit 1 # Exit if a critical rsync fails
  }
  log_message "Systems synced."
else
  log_message "  - No systems to sync and purge not enabled."
fi

# --- Process gamelist.xml files for RG351m (post-rsync) ---
# This section is specific to RG351m's gamelist.xml handling
log_message "Processing gamelist.xml files..."
find "${target_dir}" -type f -name "gamelist.xml" -print0 | while IFS= read -r -d $'\0' file; do
  target_system=$(basename "$(dirname "$file")")
  is_targeted_for_gamelist_processing=false

  if [ ${#targeted_systems[@]} -eq 0 ]; then # Full sync, process all non-excluded systems
      is_excluded=false
      for exclude_dir in "${exclude_dirs[@]}"; do
          if [ "$target_system" = "$exclude_dir" ]; then
              is_excluded=true
              break
          fi
      done
      if ! "$is_excluded"; then
          is_targeted_for_gamelist_processing=true
      fi
  else # Targeted sync, process only targeted systems (or their renamed versions)
      for target in "${targeted_systems[@]}"; do
          if [[ "$target_system" == "$target" ]] || [[ "${rename_folders["$target"]}" == "$target_system" ]]; then
              is_targeted_for_gamelist_processing=true
              break
          fi
      done
  fi
done

# --- Forward Renaming for System Folders on Target (Post-rsync) ---
log_message "Renaming specific folders on target device (post-rsync)..."
for original_name in "${!rename_folders[@]}"; do
  new_name="${rename_folders[$original_name]}"
  is_targeted=false
  # If doing full sync, or if the original/new name is explicitly targeted
  if [ ${#targeted_systems[@]} -eq 0 ]; then # Full sync, rename everything
      is_targeted=true
  else # Targeted sync, only rename if it's one of the targeted systems
      for target in "${targeted_systems[@]}"; do
          if [[ "$target" == "$original_name" ]] || [[ "$target" == "$new_name" ]]; then
              is_targeted=true
              break
          fi
      done
  fi

  if "$is_targeted"; then
    target_original_dir="${target_dir}/${original_name}"
    target_new_dir="${target_dir}/${new_name}"
    log_message "  - Checking if '$target_original_dir' exists..."
    if [ -d "$target_original_dir" ]; then
      log_message "  - Renaming '$target_original_dir' to '$target_new_dir'"
      mv "$target_original_dir" "$target_new_dir" || log_message "Warning: Failed to rename '$target_original_dir'."
    else
      log_message "  - Warning: Directory '$target_original_dir' not found, skipping rename to '$target_new_dir'."
    fi
  fi
done
sync # Ensure renames are flushed
log_message "Finished forward renaming."

log_message "RG351m sync and modifications complete."

# --- Ensure all write operations are finished ---
sync
log_message "Final sync command executed to flush write buffers."
