#!/bin/bash

set -euo pipefail # Exit on error, unset variables, and pipe failures
IFS=$' \n\t' 

log_file="${0}.log" # Log to a file named after the script

silent_mode=false  # Default: logging enabled
min_free_space_gb=1  # Minimum free space in GB
skip_gamelist_sync=false # Flag for skipping gamelist metadata synchronization
purge_target=false # Flag for purging files from target not in source
dry_run_mode=false # Initialize dry_run_mode to false

# Fields to preserve from target gamelist to source
fields_to_preserve=("crc32" "cheevosId" "cheevosHash")

# --- Function to handle logging ---
# Moved to the top to ensure it's defined before first use.
log_message() {
  local message="$1"
  # Log to console only if not in silent mode
  if ! "$silent_mode"; then
    local timestamp=$(date "+%Y-%m-%dT%H:%M:%S%z")
    echo "$timestamp - $message"
  fi
  # Always log to file
  local timestamp=$(date "+%Y-%m-%dT%H:%M:%S%z")
  echo "$timestamp - $message" >> "$log_file"
}

# --- Function to escape strings for XPath string literals using concat() ---
# This handles strings that might contain single quotes for XPath 1.0 robustness.
escape_for_xpath() {
  local input="$1"
  local output=""
  
  # Check if the string contains any single quotes
  if [[ "$input" == *\'* ]]; then
    # Split the input string by single quotes
    IFS=$'\'' read -ra parts <<< "$input" # Use $'\'' for literal single quote as IFS
    
    local num_parts=${#parts[@]}
    
    for i in "${!parts[@]}"; do
      local part="${parts[$i]}"
      
      # Add the current part, quoted with single quotes
      output+="'$part'"
      
      # If this is not the last part, and there was a single quote separating it
      if (( i < num_parts - 1 )); then
        output+=", \"'\", " # Append ", '"', " to concatenate a single quote
      fi
    done
    # If the original string had single quotes, wrap in concat()
    echo "concat($output)"
  else
    # No single quotes, just enclose in single quotes.
    echo "'$input'"
  fi
}


# Source common parameters
if [ -f "./common_config.sh" ]; then
  source "./common_config.sh"
else
  log_message "Error: common_config.sh not found." >&2 # Now log_message is available
  exit 1
fi

# Source script-specific parameters
if [ -f "./rsync_rp4pro_config.sh" ]; then
  source "./rsync_rp4pro_config.sh"
else
  log_message "Error: rsync_rp4pro_config.sh not found." >&2 # Now log_message is available
  exit 1
fi

# Use parameters from both config files
log_message "Syncing from $GLOBAL_SOURCE_BASE to $target_dir using options $GLOBAL_RSYNC_OPTIONS"


# Create a reverse mapping for convenience. Because we're thorough.
declare -A reverse_rename_folders
for original in "${!rename_folders[@]}"; do
  new="${rename_folders[$original]}"
  reverse_rename_folders["$new"]="$original"
done

show_help() {
  echo "Usage: $(basename "$0") [options] [SYSTEM_NAME1 SYSTEM_NAME2 ...]"
  echo ""
  echo "Synchronizes ROMs from a source directory to a target device."
  echo "If no SYSTEM_NAMEs are provided, performs a full sync of all non-excluded systems."
  echo ""
  echo "Options:"
  echo "  -h, --help               Show this help message and exit."
  echo "  -s, --silent             Run in silent mode (no console output, only logs)."
  echo "  -n, --dry-run            Perform a dry run (simulate rsync, still merges gamelist.xml fields into source)."
  echo "  --skip-gamelist-sync     Skip gamelist.xml metadata synchronization (favorites, preserved fields)."
  echo "  --purge                  Enable purge mode: rsync will delete extraneous files from target that are not in source."
  echo ""
  echo "Configuration is loaded from:"
  echo "  - ./common_config.sh (global settings)"
  echo "  - ${0%.sh}_config.sh (script-specific settings, e.g., rsync_rp4pro_config.sh)"
  echo "Please ensure these files exist and are configured correctly."
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

# --- Optimized Function to merge preserved fields from target to source ---
merge_preserved_fields() {
  local system_name="$1"
  # IMPORTANT: gamelist_target is expected to be in the roms folder for merging
  local source_rom_dir="${GLOBAL_SOURCE_BASE}/${system_name}"
  local target_rom_dir="${target_dir}/${system_name}"
  local gamelist_source="${source_rom_dir}/gamelist.xml"
  local gamelist_target="${target_rom_dir}/gamelist.xml" # This is where it's temporarily moved

  log_message "Merging preserved fields for $system_name..."

  if [ ! -f "$gamelist_source" ]; then
    log_message "  - Source gamelist.xml not found: '$gamelist_source'. Skipping field merge."
    return 0
  fi

  if [ ! -f "$gamelist_target" ]; then
    log_message "  - Target gamelist.xml not found: '$gamelist_target'. Skipping field merge."
    return 0
  fi

  if ! command -v xmlstarlet &> /dev/null; then
    log_message "  - xmlstarlet not found. Cannot merge fields."
    return 1
  fi

  # Create a temporary file for the source gamelist
  local gamelist_source_temp="${gamelist_source}.temp"
  cp "$gamelist_source" "$gamelist_source_temp" || {
    log_message "Error: Failed to create temporary gamelist file." >&2
    return 1
  }

  local fields_updated=0
  declare -a xmlstarlet_args=() # Use an array for arguments

  # Read target gamelist and build xmlstarlet commands
  # The following command extracts id, path, and then the values for fields_to_preserve for each game.
  target_games_data=$(xmlstarlet sel -t -m "/gameList/game[@id and @id!='0' and @id!='']" \
    -v "concat(@id,'|',path,'|',crc32,'|',cheevosId,'|',cheevosHash)" -n "$gamelist_target" 2>/dev/null)

  # Check if target_games_data is empty, indicating no relevant games or fields
  if [ -z "$target_games_data" ]; then
    log_message "  - No game IDs with preserved fields found in target gamelist '$gamelist_target'. Skipping merge."
    rm -f "$gamelist_source_temp"
    return 0
  fi

  while IFS='|' read -r game_id game_path crc32_val cheevosId_val cheevosHash_val; do
    # Skip if game_path is empty; we are now primarily matching by path
    if [ -z "$game_path" ]; then
      log_message "    - Game entry (ID $game_id) has no path, skipping merge for this entry."
      continue
    fi
    
    # Try finding by path first, as it's more reliable for ROM files
    # Using normalize-space() for robustness against leading/trailing whitespace in paths
    local escaped_game_path=$(escape_for_xpath "$game_path")
    local game_exists=$(xmlstarlet sel -t -v "count(/gameList/game[normalize-space(path) = normalize-space($escaped_game_path)])" "$gamelist_source_temp" 2>/dev/null)
    
    if [ "$game_exists" -gt 0 ]; then
      log_message "  - Processing game (path match): $game_path"
      # Build the xmlstarlet command string for this game, targeting by path
      for field in "${fields_to_preserve[@]}"; do
        local field_value
        case "$field" in
          "crc32") field_value="$crc32_val";;
          "cheevosId") field_value="$cheevosId_val";;
          "cheevosHash") field_value="$cheevosHash_val";;
          *) continue;; # Should not happen
        esac

        if [ -n "$field_value" ]; then
          # Check if the field exists for this game in the source (by path)
          local field_exists=$(xmlstarlet sel -t -v "count(/gameList/game[normalize-space(path) = normalize-space($escaped_game_path)]/$field)" "$gamelist_source_temp" 2>/dev/null)
          
          if [ "$field_exists" -gt 0 ]; then
            xmlstarlet_args+=("-u" "/gameList/game[normalize-space(path) = normalize-space($escaped_game_path)]/$field" -v "$field_value")
            log_message "    - Scheduled update for $field for game path $game_path"
          else
            xmlstarlet_args+=("-s" "/gameList/game[normalize-space(path) = normalize-space($escaped_game_path)]" "-t" "elem" "-n" "$field" "-v" "$field_value")
            log_message "    - Scheduled add for $field for game path $game_path"
          fi
          fields_updated=$((fields_updated + 1))
        fi
      done
    else
      log_message "    - Game path '$game_path' (ID $game_id) not found in source gamelist. Skipping field merge."
    fi
  done <<< "$target_games_data"

  if [ $fields_updated -gt 0 ]; then
    log_message "  - Applying $fields_updated field updates/additions to $system_name..."
    xmlstarlet ed -L "${xmlstarlet_args[@]}" "$gamelist_source_temp" || { # Execute with array
      log_message "Error: Failed to apply xmlstarlet edits for fields." >&2
      rm -f "$gamelist_source_temp"
      return 1
    }
    mv "$gamelist_source_temp" "$gamelist_source" || {
      log_message "Error: Failed to replace original gamelist file." >&2
      return 1
    }
  else
    log_message "  - No fields updated for $system_name"
    rm -f "$gamelist_source_temp"
  fi
  
  return 0
}

# --- Optimized Function to merge favorites ---
merge_favorites() {
  local system_name="$1"
  # IMPORTANT: gamelist_target_existing is expected to be in the roms folder for merging
  local source_rom_dir="${GLOBAL_SOURCE_BASE}/${system_name}"
  local target_rom_dir="${target_dir}/${system_name}"
  local gamelist_source="${source_rom_dir}/gamelist.xml"
  local gamelist_target_existing="${target_rom_dir}/gamelist.xml" # This is where it's temporarily moved

  log_message "Attempting to merge favorites for $system_name (pre-rsync)..."

  if [ ! -f "$gamelist_source" ]; then
    log_message "  - Source gamelist.xml not found: '$gamelist_source'. Skipping favorite merge for this system."
    return 0
  fi

  if [ ! -f "$gamelist_target_existing" ] || ! command -v xmlstarlet &> /dev/null; then
    log_message "  - Debug: Old gamelist.xml not found or xmlstarlet not installed for $system_name. Skipping favorite merge."
    return 0
  fi

  local gamelist_source_temp="${gamelist_source}.temp"
  cp "$gamelist_source" "$gamelist_source_temp" || {
    log_message "Error: Failed to create temporary gamelist file for favorites." >&2
    return 1
  }

  local favorites_updated=0
  declare -a xmlstarlet_args=() # Use an array for arguments

  # Extract paths and names of favorited games from the target gamelist in one go
  local favorite_games_data=$(xmlstarlet sel -t -m "/gameList/game[favorite='true']" \
    -v "path" -o "|" -v "name" -n "$gamelist_target_existing" 2>/dev/null)

  while IFS='|' read -r old_path old_name; do
    if [ -z "$old_path" ] && [ -z "$old_name" ]; then
      continue
    fi

    local marked_favorite=false
    if [ -n "$old_path" ]; then
      local escaped_old_path=$(escape_for_xpath "$old_path")
      # Check if game exists by path in source temp gamelist
      if xmlstarlet sel -t -v "count(/gameList/game[normalize-space(path) = normalize-space($escaped_old_path)])" "$gamelist_source_temp" | grep -q "1"; then
        # Check if 'favorite' element exists, if not, add it. If it exists, update it.
        if xmlstarlet sel -t -v "count(/gameList/game[normalize-space(path) = normalize-space($escaped_old_path)]/favorite)" "$gamelist_source_temp" | grep -q "1"; then
          xmlstarlet_args+=("-u" "/gameList/game[normalize-space(path) = normalize-space($escaped_old_path)]/favorite" -v "true")
          log_message "  - Scheduled favorite update (by path): $old_path"
        else
          xmlstarlet_args+=("-s" "/gameList/game[normalize-space(path) = normalize-space($escaped_old_path)]" "-t" "elem" "-n" "favorite" -v "true")
          log_message "  - Scheduled favorite add (by path): $old_path"
        fi
        marked_favorite=true
      fi
    fi

    if ! "$marked_favorite" && [ -n "$old_name" ]; then
      local escaped_old_name=$(escape_for_xpath "$old_name")
      # Check if game exists by name in source temp gamelist
      # Using normalize-space() for robustness here too
      if xmlstarlet sel -t -v "count(/gameList/game[normalize-space(name) = normalize-space($escaped_old_name)])" "$gamelist_source_temp" | grep -q "1"; then
        # Check if 'favorite' element exists, if not, add it. If it exists, update it.
        if xmlstarlet sel -t -v "count(/gameList/game[normalize-space(name) = normalize-space($escaped_old_name)]/favorite)" "$gamelist_source_temp" | grep -q "1"; then
          xmlstarlet_args+=("-u" "/gameList/game[normalize-space(name) = normalize-space($escaped_old_name)]/favorite" -v "true")
          log_message "  - Scheduled favorite update (by name): $old_name"
        else
          xmlstarlet_args+=("-s" "/gameList/game[normalize-space(name) = normalize-space($escaped_old_name)]" "-t" "elem" "-n" "favorite" -v "true")
          log_message "  - Scheduled favorite add (by name): $old_name"
        fi
        marked_favorite=true
      fi
    fi
    
    if "$marked_favorite"; then
      favorites_updated=$((favorites_updated + 1))
    fi

  done <<< "$favorite_games_data"

  if [ $favorites_updated -gt 0 ]; then
    log_message "  - Applying $favorites_updated favorite updates/additions to $system_name..."
    xmlstarlet ed -L "${xmlstarlet_args[@]}" "$gamelist_source_temp" || { # Execute with array
      log_message "Error: Failed to apply xmlstarlet edits for favorites." >&2
      rm -f "$gamelist_source_temp"
      return 1
    }
    mv "$gamelist_source_temp" "$gamelist_source" || {
      log_message "Error: Failed to replace original gamelist file." >&2
      return 1
    }
  else
    log_message "  - No favorites updated for $system_name"
    rm -f "$gamelist_source_temp"
  fi
  
  return 0
}


# --- Function to rename target directories back to source names (pre-sync) ---
unrename_target_directories() {
  local new_name original_name target_new_dir target_original_dir should_process sys
  log_message "Attempting to unrename target directories on Retroid Pocket 4 Pro (pre-rsync)..."
  # Optimized: Only iterate through reverse_rename_folders for efficiency.
  for new_name in "${!reverse_rename_folders[@]}"; do
    original_name="${reverse_rename_folders[$new_name]}"
    target_new_dir="${target_dir}/${new_name}"
    target_original_dir="${target_dir}/${original_name}"

    should_process=false
    if [ ${#targeted_systems[@]} -eq 0 ]; then # Full sync, unrename all
      should_process=true
    else # Targeted sync, unrename only the specific original system
      for sys in "${targeted_systems[@]}"; do
        if [ "$sys" = "$original_name" ]; then
          should_process=true
          break
        fi
      done # Corrected from F to done
    fi

    if "$should_process"; then
      if [ -d "$target_new_dir" ]; then
        log_message "  - Renaming '$target_new_dir' back to '$target_original_dir' for rsync."
        mv "$target_new_dir" "$target_original_dir" || log_message "Warning: Failed to rename '$target_new_dir'."
      fi
    fi
  done
}

# --- Function to rename target directories to their new names (post-sync) ---
rename_target_directories() {
  local original_name new_name target_original_dir target_new_dir should_process sys
  log_message "Attempting to rename target directories on Retroid Pocket 4 Pro (post-rsync)..."
  # Optimized: Only iterate through rename_folders for efficiency.
  for original_name in "${!rename_folders[@]}"; do
    new_name="${rename_folders[$original_name]}"
    target_original_dir="${target_dir}/${original_name}"
    target_new_dir="${target_dir}/${new_name}"

    should_process=false
    if [ ${#targeted_systems[@]} -eq 0 ]; then # Full sync, rename all
      should_process=true
    else # Targeted sync, rename only the specific original system
      for sys in "${targeted_systems[@]}"; do
        if [ "$sys" = "$original_name" ]; then
          should_process=true
          break
        fi
      done
    fi

    if "$should_process"; then
      if [ -d "$target_original_dir" ]; then
        log_message "  - Renaming '$target_original_dir' to '$target_new_dir'."
        mv "$target_original_dir" "$target_new_dir" || log_message "Warning: Failed to rename '$target_original_dir'."
      else
        log_message "  - Warning: Directory '$target_original_dir' not found, skipping rename to '$target_new_dir'."
      fi
    fi
  done
}

# --- Function to reverse move media folders (pre-rsync) ---
reverse_move_media_folders() {
  local original_system_name="$1"
  local effective_system_name="${original_system_name}"

  # Determine if this system was renamed. If so, its media on the RP4 Pro
  # will likely be under the *renamed* folder in media_target_base.
  if [[ -n "${rename_folders[$original_system_name]:-}" ]]; then
    effective_system_name="${rename_folders[$original_system_name]}"
    log_message "  - Detected previous rename for '$original_system_name' to '$effective_system_name' for reverse media move."
  fi

  local target_original_system_dir="${target_dir}/${original_system_name}" # Where it goes for rsync
  local media_source_base_dir="${media_target_base}/${effective_system_name}" # Where it is now (possibly renamed)

  log_message "  - Reversing media folder moves for $original_system_name (looking under '${effective_system_name}') (pre-rsync)..."

  for folder in "${media_folders[@]}"; do
    local source_folder="${media_source_base_dir}/${folder}"
    local dest_folder="${target_original_system_dir}/${folder}"

    # Special handling for 'Imgs' if it was renamed to 'miximages'
    if [ "$folder" == "Imgs" ]; then
      source_folder="${media_source_base_dir}/${miximages_name}"
    fi

    if [ -d "$source_folder" ]; then
      log_message "    - Moving '$source_folder' back to '$dest_folder'"
      mkdir -p "$(dirname "$dest_folder")" # Ensure parent dir exists before mv
      mv "$source_folder" "$dest_folder" || log_message "    - Warning: Failed to move '$source_folder'."
    else
      log_message "    - Source media folder '$source_folder' not found, skipping reverse move."
    fi
  done
}

# --- Function to move media folders (post-rsync) ---
move_media_folders() {
  local original_system_name="$1" # This is the original system name (e.g., 'snes')
  local effective_system_name="${original_system_name}" # Initialize with original name

  # Check if this system was renamed and update the effective name
  if [[ -n "${rename_folders[$original_system_name]:-}" ]]; then
    effective_system_name="${rename_folders[$original_system_name]}"
    log_message "  - Detected rename for '$original_system_name' to '$effective_system_name' for media moves."
  fi

  local target_system_dir="${target_dir}/${effective_system_name}" # Use the effective name
  local media_dest_dir="${media_target_base}/${effective_system_name}" # Use the effective name

  log_message "  - Moving media folders for $original_system_name (now '${effective_system_name}')..."
  log_message "    - Target system directory: $target_system_dir"
  log_message "    - Media destination directory: $media_dest_dir"
  mkdir -p "$media_dest_dir" || log_message "    - Warning: Failed to create '$media_dest_dir'."

  for folder in "${media_folders[@]}"; do
    local source_folder="${target_system_dir}/${folder}"
    local dest_folder="${media_dest_dir}/${folder}"

    log_message "    - Processing folder: $folder"
    log_message "      - Source folder: $source_folder"

    if [ -d "$source_folder" ]; then
      if [ "$folder" == "Imgs" ]; then
        dest_folder="${media_dest_dir}/${miximages_name}"
        log_message "      - Moving and renaming '$source_folder' to '$dest_folder'"
        mv "$source_folder" "$dest_folder" || log_message "      - Warning: Failed to move and rename '$source_folder'."
      else
        log_message "      - Moving '$source_folder' to '$dest_folder'"
        mv "$source_folder" "$dest_folder" || log_message "      - Warning: Failed to move '$source_folder'."
      fi
    else
      log_message "      - Source folder '$source_folder' does not exist, skipping move."
    fi
  done
}

# --- Function to unmove gamelist.xml from special target location to roms folder (pre-rsync) ---
unmove_target_gamelists() {
  local original_system_name="$1" # This is the original system name (e.g., 'snes')
  local effective_system_name="${original_system_name}" # Assume original, check for rename

  # Determine if this system was renamed. If so, its gamelist on the RP4 Pro
  # will likely be under the *renamed* folder in gamelist_target_base.
  if [[ -n "${rename_folders[$original_system_name]:-}" ]]; then
    effective_system_name="${rename_folders[$original_system_name]}"
    log_message "  - Detected previous rename for '$original_system_name' to '$effective_system_name' for gamelist unmove."
  fi

  # Source path is where the gamelist is currently located on the RP4Pro, possibly under the *renamed* folder.
  local gamelist_source_path="${gamelist_target_base}/${effective_system_name}/gamelist.xml"
  # Destination path is where it needs to be *for rsync*, which is under the *original* name.
  local gamelist_dest_path="${target_dir}/${original_system_name}/gamelist.xml"

  log_message "  - Unmoving gamelist.xml for '$original_system_name' (looking under '${effective_system_name}') from '$gamelist_source_path' to '$gamelist_dest_path' (pre-rsync)."

  if [ -f "$gamelist_source_path" ]; then
    mkdir -p "$(dirname "$gamelist_dest_path")" # Ensure target roms folder (original name) exists
    mv "$gamelist_source_path" "$gamelist_dest_path" || log_message "    - Warning: Failed to unmove '$gamelist_source_path'."
  else
    log_message "    - Gamelist.xml not found at '$gamelist_source_path'. Skipping unmove."
  fi
}

# --- Function to move gamelist.xml back to special target location from roms folder (post-rsync) ---
move_target_gamelists_back() {
  local original_system_name="$1" # This is the original system name (e.g., 'snes')
  local effective_system_name="${original_system_name}" # Initialize with original name

  # Check if this system was renamed and update the effective name
  if [[ -n "${rename_folders[$original_system_name]:-}" ]]; then
    effective_system_name="${rename_folders[$original_system_name]}"
    log_message "  - Detected rename for '$original_system_name' to '$effective_system_name' for gamelist move."
  fi

  local gamelist_source_path="${target_dir}/${effective_system_name}/gamelist.xml" # Use effective name for source
  local gamelist_dest_path="${gamelist_target_base}/${effective_system_name}/gamelist.xml" # Use effective name for destination

  log_message "  - Moving gamelist.xml for '$original_system_name' (now '${effective_system_name}') back from '$gamelist_source_path' to '$gamelist_dest_path' (post-rsync)."

  if [ -f "$gamelist_source_path" ]; then
    mkdir -p "$(dirname "$gamelist_dest_path")" # Ensure target gamelists folder exists
    mv "$gamelist_source_path" "$gamelist_dest_path" || log_message "    - Warning: Failed to move back '$gamelist_source_path'."
  else
    log_message "    - Gamelist.xml not found at '$gamelist_source_path'. Skipping move back."
  fi
}


# --- Wrapper function for parallel gamelist processing ---
# This function is executed in a subshell by xargs.
# It needs access to other functions and global variables.
process_gamelist_for_system() {
  local system_name="$1"
  log_message "BEGIN parallel gamelist processing for $system_name"
  # These functions are now exported, so they are available in the subshell.
  merge_preserved_fields "$system_name"
  merge_favorites "$system_name"
  log_message "END parallel gamelist processing for $system_name"
}

# --- Export all necessary functions and variables for subshells ---
# Functions called by process_gamelist_for_system need to be exported.
export -f log_message escape_for_xpath check_dir_exists check_free_space merge_preserved_fields merge_favorites process_gamelist_for_system
export -f unrename_target_directories rename_target_directories reverse_move_media_folders move_media_folders # Export media functions
export -f unmove_target_gamelists move_target_gamelists_back # NEW: Export new gamelist move functions
# Variables used by the exported functions need to be exported.
export GLOBAL_SOURCE_BASE target_dir log_file silent_mode fields_to_preserve exclude_dirs rename_folders reverse_rename_folders # Export rename arrays as well
export tools_dir media_target_base media_folders miximages_name # Export media variables
export gamelist_target_base # Export gamelist target base variable


main() {
  # --- Check for silent mode and process arguments ---
  declare -a targeted_systems=() # Initialize array globally, no 'local' here.
  for arg in "$@"; do
    case "$arg" intransferrable
        targeted_systems+=("$arg")
        ;;
    esac
  done

  # --- Check for targeted update arguments ---
  if [ ${#targeted_systems[@]} -eq 0 ]; then
    log_message "Full sync from: ${GLOBAL_SOURCE_BASE}"
    # When doing a full sync, we need to populate targeted_systems with all
    # source directories that are not excluded, so the rename logic works.
    # Use a loop with read -r -d $'\0' to process null-separated output robustly.
    while IFS= read -r -d $'\0' full_path; do
      local system_name=$(basename "$full_path") 

      # Skip if system_name is empty or just '.'
      if [ -z "$system_name" ] || [ "$system_name" = "." ]; then
        continue
      fi

      local is_excluded=false
      for exclude_dir in "${exclude_dirs[@]}"; do
        if [ "$system_name" = "$exclude_dir" ]; then
          is_excluded=true
          break
        fi
      done
      if ! "$is_excluded" && [[ -d "${GLOBAL_SOURCE_BASE}/${system_name}" ]]; then
        targeted_systems+=("$system_name")
        log_message "  - Found system for full sync: $system_name"
      fi
    done < <(find "${GLOBAL_SOURCE_BASE}" -maxdepth 1 -mindepth 1 -type d -print0)
  else
    log_message "Targeted update for: ${targeted_systems[@]}"
  fi

  log_message "Targeted systems for this run: ${targeted_systems[@]}"

  # --- Check if source and target base directories exist ---
  log_message "Checking for source directory: $GLOBAL_SOURCE_BASE"
  check_dir_exists "$GLOBAL_SOURCE_BASE"
  log_message "Checking for target directory: $target_dir"
  check_dir_exists "$target_dir"
  log_message "Checking for tools directory: $tools_dir"
  check_dir_exists "$tools_dir"
  log_message "Checking for media target base directory: $media_target_base"
  mkdir -p "$media_target_base"  # Create if it doesn't exist (and check result)
  if [ ! -d "$media_target_base" ]; then
      log_message "Error: Failed to create or find media target base directory: $media_target_base" >&2
      exit 1
  fi
  
  # NEW: Check and create gamelist target base directory
  log_message "Checking for gamelist target base directory: $gamelist_target_base"
  mkdir -p "$gamelist_target_base"
  if [ ! -d "$gamelist_target_base" ]; then
      log_message "Error: Failed to create or find gamelist target base directory: $gamelist_target_base" >&2
      exit 1
  fi

  # --- Pre-sync operations ---
  unrename_target_directories
  # Add a single sync here after all renames are done, if any.
  if [ ${#rename_folders[@]} -gt 0 ]; then # Only sync if there are actual renames configured
    log_message "Executing sync after pre-rsync directory renames."
    sync
  fi

  # --- Reverse Move Media Folders (before rsync) ---
  log_message "Reversing media folder moves (before rsync)..."
  for system in "${targeted_systems[@]}"; do
    reverse_move_media_folders "$system"
  done
  log_message "Executing sync after reverse media moves."
  sync

  # --- Unmove Gamelist.xml files from special target location to roms folder (pre-rsync) ---
  log_message "Unmoving gamelist.xml files from special target location to roms folder (pre-rsync)..."
  for system in "${targeted_systems[@]}"; do
    unmove_target_gamelists "$system"
  done
  log_message "Executing sync after unmoving gamelist.xml files."
  sync


  # --- Check free space on target ---
  check_free_space "$target_dir" "$min_free_space_gb"

  # --- Conditional Gamelist Sync (Parallelized) ---
  if ! "$skip_gamelist_sync"; then
    log_message "Starting parallel gamelist.xml metadata synchronization for ${#targeted_systems[@]} systems."
    
    # Pipe the targeted systems to xargs for parallel execution
    # -P $(nproc --all) will use as many parallel processes as CPU cores. Adjust if needed.
    # -I {} replaces {} with each argument (system name)
    # The bash -c command now properly finds exported functions and variables.
    printf '%s\n' "${targeted_systems[@]}" | xargs -P "$(nproc --all)" -I {} bash -c 'process_gamelist_for_system "{}"'

    # Consolidate sync here after all parallel gamelist operations are done.
    if [ ${#targeted_systems[@]} -gt 0 ]; then # Only sync if some systems were processed
      log_message "Executing sync after all gamelist operations."
      sync
    fi
  else
    log_message "Skipping gamelist.xml metadata synchronization as --skip-gamelist-sync flag is present."
  fi

  # --- Calculate number of files to copy ---
  log_message "Calculating number of files and directories in the logical romset..."
  total_items_to_copy=0

  for system in "${targeted_systems[@]}"; do
      local source_path="${GLOBAL_SOURCE_BASE}/${system}"
      
      # Start a find command for each targeted system
      find_command="find \"$source_path\" -mindepth 1"

      # Add excludes for directories that should not be part of this system's sync
      for exclude_dir_name in "${exclude_dirs[@]}"; do
          # Only exclude if this system's path is not the exclude_dir itself
          # and the exclude_dir is not one of the targeted systems.
          # This prevents excluding the very system we are trying to count.
          local is_targeted_exclude=false
          for targeted_sys in "${targeted_systems[@]}"; do
              if [ "$exclude_dir_name" = "$targeted_sys" ]; then 
                  is_targeted_exclude=true
                  break
              fi
          done

          if ! "$is_targeted_exclude"; then # Only exclude if it's NOT a targeted system
              find_command+=" -not -path \"$source_path/$exclude_dir_name/*\" -not -path \"$source_path/$exclude_dir_name\""
          else
              log_message "  - Not excluding '$exclude_dir_name' from count for system '$system' as it is a targeted system."
          fi
      done
      
      # Execute the find command and count lines (each line is an item)
      # Exclude the root system directory itself to count its contents
      current_system_items=$(eval "$find_command" 2>/dev/null | wc -l)
      total_items_to_copy=$((total_items_to_copy + current_system_items))
      log_message "  - System '$system': $current_system_items items."
  done

  log_message "Total items (files and directories) in logical romset to copy: $total_items_to_copy"
  # --- End of file calculation ---
  # --- rsync systems ---
  log_message "Syncing systems..."
  # ... (other code) ...

  # Explicitly convert GLOBAL_RSYNC_OPTIONS string into an array of options
  # using read -r -a for robust splitting.
  local rsync_options_array=()
  read -r -a rsync_options_array <<< "$GLOBAL_RSYNC_OPTIONS"

  # Initialize rsync arguments as an array: first element is 'rsync',
  # followed by the now-correctly-split global options.
  rsync_args=("${rsync_options_array[@]}")

  # Add --delete flag if purge_target is true
  if "$purge_target"; then
    rsync_args+=(--delete)
    log_message "Purge mode enabled: rsync will delete extraneous files from target."
  fi

  # Build the rsync command with individual source system paths
  for system in "${targeted_systems[@]}"; do
      # If a system is targeted, we need to ensure its original name is passed to rsync
      # as the target directories have been "unrenamed" by now.
      rsync_args+=("${GLOBAL_SOURCE_BASE}/${system}")
  done

  # Add target directory - ensure trailing slash for directory content sync
  rsync_args+=("${target_dir}/")

  # Dynamically add excludes: always exclude if not explicitly targeted.
  # This prevents accidentally syncing excluded directories if they exist in GLOBAL_SOURCE_BASE
  # but are not part of the targeted systems.
  for dir in "${exclude_dirs[@]}"; do
    should_exclude=true
    for targeted_sys in "${targeted_systems[@]}"; do
      if [ "$dir" = "$targeted_sys" ]; then
        should_exclude=false
        break
      fi
    done
    if "$should_exclude"; then
      rsync_args+=("--exclude=${dir}/") # Add trailing slash to exclude directory content
    fi
  done

  # --- Execution ---
  # Log the command before running (for debugging, expand the array elements)
  log_message "Running rsync: ${rsync_args[*]}"

  # Execute the rsync command using the array.
  if "$dry_run_mode"; then
    rsync_args+=("--dry-run")
  fi

  rsync "${rsync_args[@]}" 2>> "$log_file" || {
    rsync_exit_status=$? # Capture the exit status
    rsync_err=$(tail -n 5 "$log_file") # Get last 5 lines of error
    log_message "Error: rsync operation failed with exit code $rsync_exit_status. Details: $rsync_err" >&2
    echo "rsync error: $rsync_err" >&2 # Also print to console
    exit "$rsync_exit_status" # Exit with the rsync error code
}

  # First, rename the target directories to their new names
  log_message "Renaming target directories (post-rsync, before media/gamelist moves)."
  rename_target_directories
  log_message "Executing sync after directory renames."
  sync

  # Now, move media and gamelists using the newly renamed directory paths
  log_message "Moving media folders (after directory rename)..."
  for system in "${targeted_systems[@]}"; do
    move_media_folders "$system" # This function now handles the new names
  done

  log_message "Moving gamelist.xml files back to special target location (after directory rename)..."
  for system in "${targeted_systems[@]}"; do
    move_target_gamelists_back "$system" # This function now handles the new names
  done

  # Final sync to ensure all writes are flushed
  log_message "Retroid Pocket 4 Pro sync and modifications complete."
  log_message "Executing final sync command to flush write buffers."
  sync
}

main "$@"transferrable