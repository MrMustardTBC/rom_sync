#!/bin/bash

set -euo pipefail
IFS=$' \n\t'

if [ $# -lt 1 ]; then
  echo "Usage: $0 <device> [options...]"
  echo "Example: $0 rg35xxh [other options]"
  exit 1
fi

show_help() {
  echo "Usage: $(basename "$0") <device> [options] [SYSTEM_NAME1 SYSTEM_NAME2 ...]"
  echo ""
  echo "Synchronizes ROMs from a source directory to a target device."
  echo "If no SYSTEM_NAMEs are provided, performs a full sync of all non-excluded systems."
  echo ""
  echo "Options:"
  echo "  -h, --help                 Show this help message and exit."
  echo "  -s, --silent               Run in silent mode (no console output, only logs)."
  echo "  -n, --dry-run              Perform a dry run (simulate rsync, still merges gamelist.xml fields into source)."
  echo "  --skip-gamelist-sync       Skip gamelist.xml metadata synchronization (favorites, preserved fields)."
  echo "  --purge                    Enable purge mode: rsync will delete extraneous files from target that are not in source."
  echo "  --bios                     Enable BIOS copying from source to target."
  echo ""
  echo "Configuration is loaded from:"
  echo "  - common_config.sh (global settings)"
  echo "  - rsync_<device>_config.sh (script-specific settings)"
  echo "Please ensure these files exist and are configured correctly."
}

device="$1"
shift

if [ "$device" == "--help" ] || [ "$device" == "-h" ]; then
  show_help
  exit 1
fi

config_file="rsync_${device}_config.sh"

if [ ! -f "./common_config.sh" ]; then
  echo "Error: common_config.sh not found."
  exit 1
fi
source "./common_config.sh"

if [ ! -f "./$config_file" ]; then
  echo "Error: $config_file not found."
  exit 1
fi
source "./$config_file"

log_file="${0%.sh}_${device}.log"

silent_mode=false
min_free_space_gb=1
skip_gamelist_sync=false
purge_target=false
fields_to_preserve=("crc32" "cheevosId" "cheevosHash")

declare -A reverse_rename_folders
for original in "${!rename_folders[@]}"; do
  new="${rename_folders[$original]}"
  reverse_rename_folders["$new"]="$original"
done

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
  local free_bytes=0
  local free_gb=0
  # Check if free_kb is a valid integer
  if [[ -z "$free_kb" || ! "$free_kb" =~ ^[0-9]+$ ]]; then
    log_message "Warning: Could not determine free space for '$dir'. df output: '$free_kb'" >&2
    free_gb=0
  else
    free_bytes=$((free_kb * 1024))
    free_gb=$((free_bytes / 1024 / 1024 / 1024))
  fi
  # Check if required_gb is a valid integer
  if [[ -z "$required_gb" || ! "$required_gb" =~ ^[0-9]+$ ]]; then
    log_message "Warning: Required GB value is not a valid integer: '$required_gb'" >&2
    required_gb=1
  fi
  log_message "Debug: Free space on '$dir': $free_gb GB, Required: $required_gb GB"
  if [ "$free_gb" -lt "$required_gb" ]; then
    log_message "Error: Insufficient free space on '$dir'. Required: $required_gb GB, Available: $free_gb GB" >&2
    exit 1
  fi
}

merge_preserved_fields() {
  local system_name="$1"
  local source_rom_dir="${GLOBAL_SOURCE_BASE}/${system_name}"
  local target_rom_dir="${target_dir}/${system_name}"
  local gamelist_source="${source_rom_dir}/gamelist.xml"
  local gamelist_target="${target_rom_dir}/gamelist.xml"
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
  local gamelist_source_temp="${gamelist_source}.temp"
  cp "$gamelist_source" "$gamelist_source_temp" || {
    log_message "Error: Failed to create temporary gamelist file." >&2
    return 1
  }
  local fields_updated=0
  local xmlstarlet_commands=""
  target_games_data=$(xmlstarlet sel -t -m "/gameList/game[@id and @id!='0' and @id!='']" \
    -v "concat(@id,'|',path,'|',crc32,'|',cheevosId,'|',cheevosHash)" -n "$gamelist_target" 2>/dev/null)
  if [ -z "$target_games_data" ]; then
    log_message "  - No game IDs with preserved fields found in target gamelist '$gamelist_target'. Skipping merge."
    rm -f "$gamelist_source_temp"
    return 0
  fi
  while IFS='|' read -r game_id game_path crc32_val cheevosId_val cheevosHash_val; do
    if [ -z "$game_path" ]; then
      log_message "    - Game entry (ID $game_id) has no path, skipping merge for this entry."
      continue
    fi
    local game_exists=$(xmlstarlet sel -t -v "count(/gameList/game[normalize-space(path) = normalize-space('$game_path')])" "$gamelist_source_temp" 2>/dev/null)
    if [ "$game_exists" -gt 0 ]; then
      log_message "  - Processing game (path match): $game_path"
      for field in "${fields_to_preserve[@]}"; do
        local field_value
        case "$field" in
          "crc32") field_value="$crc32_val";;
          "cheevosId") field_value="$cheevosId_val";;
          "cheevosHash") field_value="$cheevosHash_val";;
          *) continue;;
        esac
        if [ -n "$field_value" ]; then
          local field_exists=$(xmlstarlet sel -t -v "count(/gameList/game[normalize-space(path) = normalize-space('$game_path')]/$field)" "$gamelist_source_temp" 2>/dev/null)
          if [ "$field_exists" -gt 0 ]; then
            xmlstarlet_commands+=" -u \"/gameList/game[normalize-space(path) = normalize-space('$game_path')]/$field\" -v \"$field_value\""
            log_message "    - Scheduled update for $field for game path $game_path"
          else
            xmlstarlet_commands+=" -s \"/gameList/game[normalize-space(path) = normalize-space('$game_path')]\" -t elem -n \"$field\" -v \"$field_value\""
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
    eval "xmlstarlet ed -L $xmlstarlet_commands \"$gamelist_source_temp\"" || {
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

merge_favorites() {
  local system_name="$1"
  local source_rom_dir="${GLOBAL_SOURCE_BASE}/${system_name}"
  local target_rom_dir="${target_dir}/${system_name}"
  local gamelist_source="${source_rom_dir}/gamelist.xml"
  local gamelist_target_existing="${target_dir}/${system_name}/gamelist.xml"
  log_message "Attempting to merge favorites and hidden status for $system_name (pre-rsync)..."
  if [ ! -f "$gamelist_source" ]; then
    log_message "  - Source gamelist.xml not found: '$gamelist_source'. Skipping favorite/hidden merge for this system."
    return 0
  fi
  if [ ! -f "$gamelist_target_existing" ] || ! command -v xmlstarlet &> /dev/null; then
    log_message "  - Debug: Old gamelist.xml not found or xmlstarlet not installed for $system_name. Skipping favorite/hidden merge."
    return 0
  fi
  local gamelist_source_temp="${gamelist_source}.temp"
  cp "$gamelist_source" "$gamelist_source_temp" || {
    log_message "Error: Failed to create temporary gamelist file for favorites/hidden." >&2
    return 1
  }
  local updates=0
  local xmlstarlet_commands=""
  # Merge favorites
  local favorite_games_data=$(xmlstarlet sel -t -m "/gameList/game[favorite='true']" \
    -v "path" -o "|" -v "name" -n "$gamelist_target_existing" 2>/dev/null)
  while IFS='|' read -r old_path old_name; do
    if [ -z "$old_path" ] && [ -z "$old_name" ]; then
      continue
    fi
    local marked_favorite=false
    if [ -n "$old_path" ]; then
      if xmlstarlet sel -t -v "count(/gameList/game[normalize-space(path) = normalize-space('$old_path')])" "$gamelist_source_temp" | grep -q "1"; then
        if xmlstarlet sel -t -v "count(/gameList/game[normalize-space(path) = normalize-space('$old_path')]/favorite)" "$gamelist_source_temp" | grep -q "1"; then
          xmlstarlet_commands+=" -u \"/gameList/game[normalize-space(path) = normalize-space('$old_path')]/favorite\" -v \"true\""
          log_message "  - Scheduled favorite update (by path): $old_path"
        else
          xmlstarlet_commands+=" -s \"/gameList/game[normalize-space(path) = normalize-space('$old_path')]\" -t elem -n \"favorite\" -v \"true\""
          log_message "  - Scheduled favorite add (by path): $old_path"
        fi
        marked_favorite=true
      fi
    fi
    if ! "$marked_favorite" && [ -n "$old_name" ]; then
      if xmlstarlet sel -t -v "count(/gameList/game[normalize-space(name) = normalize-space('$old_name')])" "$gamelist_source_temp" | grep -q "1"; then
        if xmlstarlet sel -t -v "count(/gameList/game[normalize-space(name) = normalize-space('$old_name')]/favorite)" "$gamelist_source_temp" | grep -q "1"; then
          xmlstarlet_commands+=" -u \"/gameList/game[normalize-space(name) = normalize-space('$old_name')]/favorite\" -v \"true\""
          log_message "  - Scheduled favorite update (by name): $old_name"
        else
          xmlstarlet_commands+=" -s \"/gameList/game[normalize-space(name) = normalize-space('$old_name')]\" -t elem -n \"favorite\" -v \"true\""
          log_message "  - Scheduled favorite add (by name): $old_name"
        fi
        marked_favorite=true
      fi
    fi
    if "$marked_favorite"; then
      updates=$((updates + 1))
    fi
  done <<< "$favorite_games_data"

  # Merge hidden status
  local hidden_games_data=$(xmlstarlet sel -t -m "/gameList/game[hidden='true']" \
    -v "path" -o "|" -v "name" -n "$gamelist_target_existing" 2>/dev/null)
  while IFS='|' read -r old_path old_name; do
    if [ -z "$old_path" ] && [ -z "$old_name" ]; then
      continue
    fi
    local marked_hidden=false
    if [ -n "$old_path" ]; then
      if xmlstarlet sel -t -v "count(/gameList/game[normalize-space(path) = normalize-space('$old_path')])" "$gamelist_source_temp" | grep -q "1"; then
        if xmlstarlet sel -t -v "count(/gameList/game[normalize-space(path) = normalize-space('$old_path')]/hidden)" "$gamelist_source_temp" | grep -q "1"; then
          xmlstarlet_commands+=" -u \"/gameList/game[normalize-space(path) = normalize-space('$old_path')]/hidden\" -v \"true\""
          log_message "  - Scheduled hidden update (by path): $old_path"
        else
          xmlstarlet_commands+=" -s \"/gameList/game[normalize-space(path) = normalize-space('$old_path')]\" -t elem -n \"hidden\" -v \"true\""
          log_message "  - Scheduled hidden add (by path): $old_path"
        fi
        marked_hidden=true
      fi
    fi
    if ! "$marked_hidden" && [ -n "$old_name" ]; then
      if xmlstarlet sel -t -v "count(/gameList/game[normalize-space(name) = normalize-space('$old_name')])" "$gamelist_source_temp" | grep -q "1"; then
        if xmlstarlet sel -t -v "count(/gameList/game[normalize-space(name) = normalize-space('$old_name')]/hidden)" "$gamelist_source_temp" | grep -q "1"; then
          xmlstarlet_commands+=" -u \"/gameList/game[normalize-space(name) = normalize-space('$old_name')]/hidden\" -v \"true\""
          log_message "  - Scheduled hidden update (by name): $old_name"
        else
          xmlstarlet_commands+=" -s \"/gameList/game[normalize-space(name) = normalize-space('$old_name')]\" -t elem -n \"hidden\" -v \"true\""
          log_message "  - Scheduled hidden add (by name): $old_name"
        fi
        marked_hidden=true
      fi
    fi
    if "$marked_hidden"; then
      updates=$((updates + 1))
    fi
  done <<< "$hidden_games_data"

  if [ $updates -gt 0 ]; then
    log_message "  - Applying $updates favorite/hidden updates/additions to $system_name..."
    eval "xmlstarlet ed -L $xmlstarlet_commands \"$gamelist_source_temp\"" || {
      log_message "Error: Failed to apply xmlstarlet edits for favorites/hidden." >&2
      rm -f "$gamelist_source_temp"
      return 1
    }
    mv "$gamelist_source_temp" "$gamelist_source" || {
      log_message "Error: Failed to replace original gamelist file." >&2
      return 1
    }
  else
    log_message "  - No favorites/hidden updated for $system_name"
    rm -f "$gamelist_source_temp"
  fi
  return 0
}

unrename_target_directories() {
  local new_name original_name target_new_dir target_original_dir should_process sys
  log_message "Attempting to unrename target directories on $device (pre-rsync)..."
  for new_name in "${!reverse_rename_folders[@]}"; do
    original_name="${reverse_rename_folders[$new_name]}"
    target_new_dir="${target_dir}/${new_name}"
    target_original_dir="${target_dir}/${original_name}"
    should_process=false
    if [ ${#targeted_systems[@]} -eq 0 ]; then
      should_process=true
    else
      for sys in "${targeted_systems[@]}"; do
        if [ "$sys" = "$original_name" ]; then
          should_process=true
          break
        fi
      done
    fi
    if "$should_process"; then
      if [ -d "$target_new_dir" ]; then
        log_message "  - Renaming '$target_new_dir' back to '$target_original_dir' for rsync."
        mv "$target_new_dir" "$target_original_dir" || log_message "Warning: Failed to rename '$target_new_dir'."
      fi
    fi
  done
}

rename_target_directories() {
  local original_name new_name target_original_dir target_new_dir should_process sys
  log_message "Attempting to rename target directories on $device (post-rsync)..."
  for original_name in "${!rename_folders[@]}"; do
    new_name="${rename_folders[$original_name]}"
    target_original_dir="${target_dir}/${original_name}"
    target_new_dir="${target_dir}/${new_name}"
    should_process=false
    if [ ${#targeted_systems[@]} -eq 0 ]; then
      should_process=true
    else
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

process_gamelist_for_system() {
  local system_name="$1"
  log_message "BEGIN parallel gamelist processing for $system_name"
  merge_preserved_fields "$system_name"
  merge_favorites "$system_name"
  log_message "END parallel gamelist processing for $system_name"
}

export -f log_message check_dir_exists check_free_space merge_preserved_fields merge_favorites process_gamelist_for_system
export GLOBAL_SOURCE_BASE target_dir log_file silent_mode fields_to_preserve exclude_dirs rename_folders reverse_rename_folders

copy_bios() {
  local system_name="$1"
  local bios_dest="$2"
  local source_bios_dir="${GLOBAL_SOURCE_BASE}/${system_name}/bios"

  if [ -d "$source_bios_dir" ]; then
    log_message "Copying BIOS files for $system_name to $bios_dest"
    mkdir -p "$bios_dest"
    rsync -avhr --progress "$source_bios_dir/" "$bios_dest"
    find "$source_bios_dir/" -depth -type d -empty -delete
  else
    log_message "No BIOS directory found for $system_name at $source_bios_dir. Skipping."
  fi
}

main() {
  # Device-specific pre-sync hooks
  if [[ "$device" == "steamdeck" ]]; then
    log_message "Checking for tools directory: $tools_dir"
    check_dir_exists "$tools_dir"
    log_message "Checking for media target base directory: $media_target_base"
    mkdir -p "$media_target_base"
    if [ ! -d "$media_target_base" ]; then
      log_message "Error: Failed to create or find media target base directory: $media_target_base" >&2
      exit 1
    fi
    log_message "Reversing media folder moves (before rsync)..."
    for system in "${targeted_systems[@]}"; do
      if [[ -n "${media_folders[*]:-}" && -n "${miximages_name:-}" ]]; then
        local target_system_dir="${target_dir}/${system}"
        local media_target_dir="${media_target_base}/${system}"
        log_message "  - Reversing media folder moves for $system..."
        for folder in "${media_folders[@]}"; do
          local source_folder="${media_target_dir}/${folder}"
          local dest_folder="${target_system_dir}/${folder}"
          if [ "$folder" == "Imgs" ]; then
            source_folder="${media_target_dir}/${miximages_name}"
          fi
          if [ -d "$source_folder" ]; then
            log_message "    - Moving '$source_folder' back to '$dest_folder'"
            mkdir -p "$(dirname "$dest_folder")"
            mv "$source_folder" "$dest_folder" || log_message "    - Warning: Failed to move '$source_folder'."
          fi
        done
      fi
    done
    sync
  fi
    declare -a targeted_systems=()
  local dry_run_mode=false
  local copy_bios_enabled=false # <-- Initialize the new variable

  for arg in "$@"; do
    case "$arg" in
      -h|--help)
        show_help
        exit 0
        ;;
      -s|--silent)
        silent_mode=true
        ;;
      --skip-gamelist-sync)
        skip_gamelist_sync=true
        ;;
      -n|--dry-run)
        dry_run_mode=true
        log_message "Dry run mode enabled: rsync will not make changes."
        ;;
      --purge)
        purge_target=true
        ;;
      --bios) # <-- Add this new case
        copy_bios_enabled=true
        log_message "BIOS copying enabled via command line flag."
        ;;
      *)
        targeted_systems+=("$arg")
        ;;
    esac
  done
  if [ ${#targeted_systems[@]} -gt 0 ]; then
    log_message "Targeted update for: ${targeted_systems[@]}"
  else
    log_message "Full sync from: ${GLOBAL_SOURCE_BASE}"
    while IFS= read -r -d $'\0' full_path; do
      local system_name=$(basename "$full_path")
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
  fi
  log_message "Targeted systems for this run: ${targeted_systems[@]}"
  log_message "Checking for source directory: $GLOBAL_SOURCE_BASE"
  check_dir_exists "$GLOBAL_SOURCE_BASE"
  log_message "Checking for target directory: $target_dir"
  check_dir_exists "$target_dir"
  unrename_target_directories
  if [ ${#rename_folders[@]} -gt 0 ]; then
    log_message "Executing sync after pre-rsync directory renames."
    sync
  fi
  check_free_space "$target_dir" "$min_free_space_gb"
  if ! "$skip_gamelist_sync"; then
    log_message "Starting parallel gamelist.xml metadata synchronization for ${#targeted_systems[@]} systems."
    printf '%s\n' "${targeted_systems[@]}" | xargs -P "$(nproc --all)" -I {} bash -c 'process_gamelist_for_system "{}"'
    if [ ${#targeted_systems[@]} -gt 0 ]; then
      log_message "Executing sync after all gamelist operations."
      sync
    fi
  else
    log_message "Skipping gamelist.xml metadata synchronization as --skip-gamelist-sync flag is present."
  fi
  log_message "Calculating number of files and directories in the logical romset..."
  total_items_to_copy=0
  for system in "${targeted_systems[@]}"; do
      local source_path="${GLOBAL_SOURCE_BASE}/${system}"
      find_command="find \"$source_path\" -mindepth 1"
      for exclude_dir_name in "${exclude_dirs[@]}"; do
          local is_targeted_exclude=false
          for targeted_sys in "${targeted_systems[@]}"; do
              if [ "$exclude_dir_name" = "$targeted_sys" ]; then
                  is_targeted_exclude=true
                  break
              fi
          done
          if [ "$exclude_dir_name" != "$system" ] && ! "$is_targeted_exclude"; then
              find_command+=" -not -path \"$source_path/$exclude_dir_name/*\" -not -path \"$source_path/$exclude_dir_name\""
          fi
      done
      current_system_items=$(eval "$find_command" 2>/dev/null | wc -l)
      total_items_to_copy=$((total_items_to_copy + current_system_items))
      log_message "  - System '$system': $current_system_items items."
  done
  log_message "Total items (files and directories) in logical romset to copy: $total_items_to_copy"
  log_message "Syncing systems..."
  local rsync_options_array=()
  read -r -a rsync_options_array <<< "$GLOBAL_RSYNC_OPTIONS"
  rsync_args=("${rsync_options_array[@]}")
  if "$purge_target"; then
    rsync_args+=(--delete-after)
    log_message "Purge mode enabled: rsync will delete extraneous files from target."
  fi
  for system in "${targeted_systems[@]}"; do
      rsync_args+=("${GLOBAL_SOURCE_BASE}/${system}")
  done
  rsync_args+=("${target_dir}/")
  for dir in "${exclude_dirs[@]}"; do
    should_exclude=true
    for targeted_sys in "${targeted_systems[@]}"; do
      if [ "$dir" = "$targeted_sys" ]; then
        should_exclude=false
        break
      fi
    done
    if "$should_exclude"; then
      rsync_args+=("--exclude=${dir}/")
    fi
  done
  log_message "Running rsync: ${rsync_args[*]}"
  # Add bios exclusion
  if [ "$copy_bios_enabled" = false ]; then
    log_message "Excluding 'bios' directories from the main rsync."
    rsync_args+=("--exclude=bios/")
  fi

  rsync "${rsync_args[@]}" 2>> "$log_file" || {
    rsync_exit_status=$?
    rsync_err=$(tail -n 5 "$log_file")
    log_message "Error: rsync operation failed with exit code $rsync_exit_status. Details: $rsync_err" >&2
    echo "rsync error: $rsync_err" >&2
    exit "$rsync_exit_status"
  }
  rename_target_directories

  # Loop through targeted systems and copy bios
  if "$copy_bios_enabled"; then # <-- Add this conditional
    log_message "Copying BIOS for targeted systems..."
    for system in "${targeted_systems[@]}"; do
      copy_bios "$system" "$bios_target"
    done
  else
    log_message "Skipping BIOS copy. Use --bios flag to enable."
  fi

  # Device-specific post-sync hooks
  if [[ "$device" == "steamdeck" ]]; then
    log_message "Moving media folders (after rsync)..."
    for system in "${targeted_systems[@]}"; do
      if [[ -n "${media_folders[*]:-}" && -n "${miximages_name:-}" ]]; then
        local target_system_dir="${target_dir}/${system}"
        local media_target_dir="${media_target_base}/${system}"
        log_message "  - Attempting to move media folders for $system..."
        log_message "    - Target system directory: $target_system_dir"
        log_message "    - Media target directory: $media_target_dir"
        mkdir -p "$media_target_dir" || log_message "    - Warning: Failed to create '$media_target_dir'."
        for folder in "${media_folders[@]}"; do
          local source_folder="${target_system_dir}/${folder}"
          local dest_folder="${media_target_dir}/${folder}"
          log_message "    - Processing folder: $folder"
          log_message "      - Source folder: $source_folder"
          if [ -d "$source_folder" ]; then
            if [ "$folder" == "Imgs" ]; then
              dest_folder="${media_target_dir}/${miximages_name}"
              log_message "      - Moving and renaming '$source_folder' to '$dest_folder'"
              mv "$source_folder" "$dest_folder" || log_message "      - Warning: Failed to move and rename '$source_folder'."
            else
              log_message "      - Moving '$source_folder' to '$dest_folder'"
              mv "$source_folder" "$dest_folder" || log_message "      - Warning: Failed to move '$source_folder'."
            fi
          else
            log_message "      - Source folder '$source_folder' does not exist."
          fi
        done
      fi
    done
  fi

  if [[ "$onionOS" == "true" ]]; then
    log_message "Processing gamelist.xml files for OnionOS..."
    find "${target_dir}" -type f -name "gamelist.xml" -print0 | while IFS= read -r -d $'\0' file; do
      target_system=$(basename "$(dirname "$file")")
      if [ ${#targeted_systems[@]} -eq 0 ] || [[ " ${targeted_systems[@]} " =~ " ${target_system} " ]]; then
        new_file="$(dirname "$file")/miyoogamelist.xml"
        log_message "Processing '$file'..."
        log_message "Renaming '$file' to '$new_file'"
        mv "$file" "$new_file" || log_message "Warning: Failed to rename '$file'."
        log_message "Cleaning '$new_file' (removing entries with id=0)..."
        xmlstarlet ed -L -d "//game[@id='0']" "$new_file" || log_message "Warning: Failed to clean '$new_file'."
      fi
    done
  fi
  log_message "$device sync and modifications complete."
  log_message "Executing final sync command to flush write buffers."
  sync
}

main "$@"