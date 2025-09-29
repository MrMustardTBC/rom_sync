#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
# Treat unset variables as an error.
set -euo pipefail
IFS=$'\n\t' # Required to correctly handle filenames with spaces/special characters

if [ $# -lt 1 ]; then
  echo "Usage: $0 <device> [options...] [SYSTEM_NAME1 SYSTEM_NAME2 ...]"
  exit 1
fi

# --- Global Variables ---
script_dir="$(dirname "$(readlink -f "$0")")"
# Generate log file path early
log_file="/tmp/rsync_device_$(date +%Y%m%d_%H%M%S).log"

# --- Argument Parsing ---
device="$1"
shift

show_help() {
  echo "Usage: $(basename "$0") <device> [options] [SYSTEM_NAME1 SYSTEM_NAME2 ...]
"
  echo "Synchronizes ROMs from a source directory to a target device."
  echo "If no SYSTEM_NAMEs are provided, performs a full sync of all non-excluded systems."
  echo ""
  echo "Options:"
  echo "  -h, --help                 Show this help message and exit."
  echo "  -s, --silent               Run in silent mode (no console output, only logs)."
  echo "  -n, --dry-run              Perform a dry run (simulate rsync, still merges gamelist.xml fields into source)."
  echo "  --skip-gamelist-sync       Skip gamelist.xml metadata synchronization (favorites, preserved fields)."
  echo "  --purge                    Enable purge mode: rsync will delete extraneous files from target that are not in source."
  echo "  --bios                     Enable BIOS copying from source to target (merges system-local bios/ into \$bios_target)."
  echo ""
  echo "Configuration is loaded from:"
  echo "  - common_config.sh (global settings)"
  echo "  - rsync_<device>_config.sh (script-specific settings)"
  echo "Please ensure these files exist and are configured correctly."
}

# Default flags
dry_run_mode=false
copy_bios_enabled=false
purge_target=false
skip_gamelist_sync=false
silent_mode=false
targeted_systems=()

# Process flags and arguments
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      show_help
      exit 0
      ;;
    -s|--silent)
      silent_mode=true
      ;;
    -n|--dry-run)
      dry_run_mode=true
      ;;
    --skip-gamelist-sync)
      skip_gamelist_sync=true
      ;;
    --purge)
      purge_target=true
      ;;
    --bios)
      copy_bios_enabled=true
      ;;
    -*)
      echo "Error: Unknown option '$1'" >&2
      exit 1
      ;;
    *)
      targeted_systems+=("$1")
      ;;
  esac
  shift
done

# --- Logging Functions ---

log_message() {
  local message="$1"
  # Try to log the message
  echo "$(date +'%Y-%m-%d %H:%M:%S') - $message" >> "$log_file" 2>/dev/null || true
  if [ "$silent_mode" = false ]; then
    echo -e "$message"
  fi
}

error_exit() {
  local message="$1"
  # Log the failure before exiting
  echo "$(date +'%Y-%m-%d %H:%M:%S') - FATAL ERROR: $message" >> "$log_file" 2>/dev/null || true

  echo "" >&2
  echo "--------------------------------------------------------" >&2
  echo "!!! SCRIPT CRASHED. CHECK LOG FILE FOR DETAILS !!!" >&2
  echo "Log file: $log_file" >&2
  echo "Error: $message" >&2
  echo "--------------------------------------------------------" >&2
  exit 1
}

# --- Configuration Loading and Initialization ---

# Initialize ALL optional configuration variables and arrays to prevent 'set -u' failure 
# if they are not defined in the sourced files.
declare -a EXCLUDE_SUBDIRS=()
declare -a EXCLUDE_DIRS=() # Renamed to EXCLUDE_DIRS
declare -A rename_folders=()
declare -a media_folders=()
bios_target=""
media_target_base=""
miximages_name=""
onionOS="false"
min_free_space_gb=0 # Set to 0 initially to avoid errors if not set in config

# Temporarily disable 'set -u' to prevent crashes during sourcing due to unset variables
# within config files (e.g., in commented-out lines like # echo $optional_var)
set +u

# Load global configuration
config_common_file="${script_dir}/common_config.sh"
if [ -f "$config_common_file" ]; then
  log_message "Loading common configuration from $config_common_file"
  source "$config_common_file" || error_exit "Failed to source $config_common_file. Check config syntax."
else
  set -u # Re-enable set -u before erroring out
  error_exit "Common configuration file not found: $config_common_file"
fi

# Load device-specific configuration
config_device_file="${script_dir}/rsync_${device}_config.sh"
if [ -f "$config_device_file" ]; then
  log_message "Loading device configuration from $config_device_file"
  source "$config_device_file" || error_exit "Failed to source $config_device_file for device '$device'. Check config syntax."
else
  set -u # Re-enable set -u before erroring out
  error_exit "Device configuration file not found: $config_device_file"
fi

# Re-enable 'set -u' for the rest of the script
set -u

# Check for required variables from config (these MUST be defined in one of the config files)
: "${target_dir:?Error: target_dir is not set in config}"
: "${GLOBAL_SOURCE_BASE:?Error: GLOBAL_SOURCE_BASE is not set in config}"
: "${GLOBAL_RSYNC_OPTIONS:?Error: GLOBAL_RSYNC_OPTIONS is not set in config}"
: "${min_free_space_gb:?Error: min_free_space_gb is not set in config (must be explicitly set to 0 or higher)}"

# --- Helper Functions ---

check_dir_exists() {
  local dir_path="$1"
  if [ ! -d "$dir_path" ]; then
    error_exit "Directory not found: $dir_path"
  fi
}

check_free_space() {
  local target="$1"
  local required_gb="$2"
  local free_space_gb
  # Get free space in 1GB blocks, suppress error if target not found (handled by check_dir_exists)
  free_space_gb=$(df -BG "$target" 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G')

  if [ -z "$free_space_gb" ] || [ "$free_space_gb" -lt "$required_gb" ]; then
    error_exit "Insufficient free space on $target. Required: ${required_gb}GB, Available: ${free_space_gb}GB."
  fi
  log_message "Free space check passed. Available: ${free_space_gb}GB."
}

# --- UNIFIED AND OPTIMIZED GAMELIST PROCESSING ---

process_gamelist_for_system() {
  local system_name="$1"
  local source_file="${GLOBAL_SOURCE_BASE}/${system_name}/gamelist.xml"
  local target_file="${target_dir}/${system_name}/gamelist.xml"
  local tmp_file="${source_file}.tmp"

  if [ ! -f "$source_file" ]; then
    log_message "  - Gamelist sync skipped: Source file not found: $source_file"
    return 0
  fi
  if [ ! -f "$target_file" ]; then
    log_message "  - Gamelist sync skipped: Target file not found: $target_file"
    return 0
  fi

  log_message "  - Starting unified gamelist processing for $system_name..."

  local target_data
  target_data=$(xmlstarlet sel -t -m "//game" \
    -v "normalize-space(name)" -o "|" \
    -v "hidden" -o "|" \
    -v "favorite" -o "|" \
    -v "playcount" -o $'\n' \
    "$target_file" 2>/dev/null)

  if [ -z "$target_data" ]; then
    log_message "  - Warning: Could not extract data from target gamelist. Skipping updates."
    return 0
  fi

  local xmlstarlet_commands=""
  local update_count=0
  
  cp "$source_file" "$tmp_file"

  while IFS='|' read -r name hidden favorite playcount; do
    if [ -z "$name" ]; then continue; fi
    
    local escaped_name
    escaped_name=$(echo "$name" | sed "s/'/&apos;/g")
    local xpath_base="//game[normalize-space(name)='${escaped_name}']"
    
    if [ "$favorite" = "true" ]; then
      xmlstarlet_commands="$xmlstarlet_commands -u \"${xpath_base}/favorite\" -v \"true\""
      xmlstarlet_commands="$xmlstarlet_commands -s \"${xpath_base}[not(favorite)]\" -t elem -n favorite -v \"true\""
      update_count=$((update_count + 2))
    fi
    if [ "$hidden" = "true" ]; then
      xmlstarlet_commands="$xmlstarlet_commands -u \"${xpath_base}/hidden\" -v \"true\""
      xmlstarlet_commands="$xmlstarlet_commands -s \"${xpath_base}[not(hidden)]\" -t elem -n hidden -v \"true\""
      update_count=$((update_count + 2))
    fi
    
    if [[ "$playcount" =~ ^[0-9]+$ ]] && [ "$playcount" -gt 0 ]; then
      xmlstarlet_commands="$xmlstarlet_commands -u \"${xpath_base}/playcount\" -v \"$playcount\""
      xmlstarlet_commands="$xmlstarlet_commands -s \"${xpath_base}[not(playcount)]\" -t elem -n playcount -v \"$playcount\""
      update_count=$((update_count + 2))
    fi

  done <<< "$target_data"

  if [ -n "$xmlstarlet_commands" ]; then
    log_message "  - Executing $update_count XMLStarlet operations in one pass."
    
    # Use eval to execute the long command string with XMLStarlet
    eval "xmlstarlet ed -L $xmlstarlet_commands \"$tmp_file\"" 2>> "$log_file" || {
      log_message "  - CRITICAL ERROR: XMLStarlet command failed. Aborting gamelist sync for $system_name." >&2
      rm -f "$tmp_file"
      return 1
    }
    
    mv "$tmp_file" "$source_file"
    log_message "  - Source gamelist.xml successfully updated."
  else
    log_message "  - No favorites or preserved fields found to merge."
    rm -f "$tmp_file"
  fi
  
  return 0
}


# --- Core System Processing Loop Function ---

process_system() {
  local system_name="$1"
  local dry_run="$2"
  local copy_bios="$3"
  local purge="$4"
  local skip_gamelist="$5"
  local target_system_dir="${target_dir}/${system_name}"
  local source_system_dir="${GLOBAL_SOURCE_BASE}/${system_name}"
  local rsync_exit_status=0

  # 1. PRE-RSYNC PREPARATION (Renames/Reversals)
  # NOTE: Steam Deck media handling removed as it was device-specific and confusing sync flow.
  
  if [ -n "${rename_folders[$system_name]:-}" ]; then
    local new_name="${rename_folders[$system_name]}"
    local target_new_dir="${target_dir}/${new_name}"
    local target_original_dir="${target_dir}/${system_name}"
    
    if [ -d "$target_new_dir" ] && [ ! -d "$target_original_dir" ]; then
      log_message "  - Renaming target folder '$target_new_dir' back to source name '$target_original_dir' for rsync."
      mv "$target_new_dir" "$target_original_dir" || log_message "Warning: Failed to rename '$target_new_dir'."
    fi
  fi
  
  # 2. GAMELIST SYNC
  if ! "$skip_gamelist"; then
    log_message "  - Synchronizing gamelist.xml metadata into source for $system_name (Pre-rsync)."
    process_gamelist_for_system "$system_name" || {
      log_message "Warning: Unified Gamelist sync failed for $system_name. Continuing to rsync."
    }
    sync
  fi

  # 3. RSYNC EXECUTION
  local rsync_args=()
  local old_IFS="$IFS"
  IFS=$' \t\n'
  read -r -a rsync_args <<< "$GLOBAL_RSYNC_OPTIONS"
  IFS="$old_IFS"

  if "$dry_run"; then
    rsync_args+=(-n)
  fi
  if "$purge"; then
    rsync_args+=(--delete-after)
    log_message "  - Purge mode enabled for this system."
  fi
  
  if [ "$copy_bios" = false ]; then
    rsync_args+=("--exclude=bios/")
    log_message "  - Excluding 'bios' directory from this system sync (Use --bios to include)."
  else
    log_message "  - Including system-local 'bios/' directory for post-sync merge."
  fi
  
  if [ ${#EXCLUDE_SUBDIRS[@]} -gt 0 ]; then
    log_message "  - Applying EXCLUDE_SUBDIRS: ${EXCLUDE_SUBDIRS[*]}"
    for subdir in "${EXCLUDE_SUBDIRS[@]}"; do
      if [[ "$subdir" =~ / ]]; then
        rsync_args+=("--exclude=${subdir}")
      else
        rsync_args+=("--exclude=${subdir}/")
      fi
    done
  fi

  local rsync_source_path="${GLOBAL_SOURCE_BASE}/${system_name}/"
  local rsync_target_path="${target_system_dir}/"

  log_message "  - Running rsync (checksum, inplace) for $system_name..."
  # Log the full command for debugging (with quotes added for clarity)
  # log_message "  - Full Rsync Command: rsync ${rsync_args[*]} \"$rsync_source_path\" \"$rsync_target_path\""

  local rsync_output
  rsync_output=$(rsync "${rsync_args[@]}" "$rsync_source_path" "$rsync_target_path" 2>&1) || rsync_exit_status=$?
  
  log_message "  - Rsync Output/Errors:\n$rsync_output"
  
  if [ "$rsync_exit_status" -gt 1 ]; then
    log_message "Error: rsync for $system_name failed critically with exit code $rsync_exit_status. Skipping post-sync." >&2
    return "$rsync_exit_status"
  fi

  # 4. POST-RSYNC CLEANUP

  # 4a. BIOS Merge
  if "$copy_bios" && [ -n "${bios_target}" ]; then
    local source_bios_dir="${target_system_dir}/bios"
    local dest_bios_dir="${bios_target}"
    
    if [ -d "$source_bios_dir" ] && [ -d "$dest_bios_dir" ]; then
      log_message "  - Merging system-local BIOS from temporary target path '$source_bios_dir' to global target '$dest_bios_dir'."
      
      # Use rsync to move files and remove source files after copy
      rsync -a --remove-source-files "$source_bios_dir/" "$dest_bios_dir/" 2>> "$log_file" || {
        log_message "Warning: Failed to merge BIOS contents from system folder." >&2
      }
      
      if [ -d "$source_bios_dir" ]; then
        log_message "  - Removing empty system-local BIOS directory '$source_bios_dir'."
        rmdir "$source_bios_dir" 2>> "$log_file" || rm -rf "$source_bios_dir" 2>> "$log_file"
      fi
    elif [ -d "$source_bios_dir" ]; then
        log_message "Warning: BIOS merge skipped. Global BIOS target directory not found: $dest_bios_dir (Check \$bios_target in config)."
    else
      # FIX: Corrected message to show the temporary target path
      log_message "  - BIOS merge skipped. No 'bios/' directory was copied to the temporary target path: $source_bios_dir."
    fi
  fi

  # 4b. System Folder Rename
  if [ -n "${rename_folders[$system_name]:-}" ]; then
    local new_name="${rename_folders[$system_name]}"
    local target_original_dir="${target_dir}/${system_name}"
    local target_new_dir="${target_dir}/${new_name}"

    if [ -d "$target_new_dir" ]; then
      log_message "  - Destination target folder '$target_new_dir' already exists. Merging contents from temporary '$target_original_dir'."
      rsync -a --remove-source-files "$target_original_dir/" "$target_new_dir/" 2>> "$log_file" || log_message "Warning: Failed to merge contents from '$target_original_dir' to '$target_new_dir'."
      
      if [ -d "$target_original_dir" ]; then
        log_message "  - Removing temporary folder '$target_original_dir' after merge."
        rmdir "$target_original_dir" 2>> "$log_file" || rm -rf "$target_original_dir" 2>> "$log_file"
      fi
      
    elif [ -d "$target_original_dir" ]; then
      log_message "  - Renaming target folder '$target_original_dir' to final name '$target_new_dir'."
      mv "$target_original_dir" "$target_new_dir" || log_message "Warning: Failed to rename '$target_original_dir'."
    else
      log_message "  - Warning: Directory '$target_original_dir' not found, skipping rename to '$target_new_dir'. (Normal if rsync copied no files.)"
    fi
  fi
  
  # 4c. OnionOS Gamelist Rename/Clean
  if [[ "$onionOS" == "true" ]]; then
    local final_system_name="$system_name"
    if [ -n "${rename_folders[$system_name]:-}" ]; then
      final_system_name="${rename_folders[$system_name]}"
    fi
    local file="${target_dir}/${final_system_name}/gamelist.xml"
    
    if [ -f "$file" ]; then
      local new_file="$(dirname "$file")/miyoogamelist.xml"
      log_message "  - OnionOS: Renaming '$file' to '$new_file'"
      mv "$file" "$new_file" || log_message "Warning: Failed to rename '$file'."
      log_message "  - OnionOS: Cleaning '$new_file' (removing entries with id=0)..."
      xmlstarlet ed -L -d "//game[@id='0']" "$new_file" 2>> "$log_file" || log_message "Warning: Failed to clean '$new_file'."
    fi
  fi

  return 0
}

# --- Main Logic ---

main() {
  log_message "--- Starting rsync_device.sh for device: $device ---"
  
  if [ ${#targeted_systems[@]} -gt 0 ]; then
    SYSTEMS_TO_PROCESS=("${targeted_systems[@]}")
  else
    log_message "No specific systems targeted. Running full sync of non-excluded systems."
    
    declare -a all_source_dirs=()
    while IFS= read -r -d $'\0' full_path; do
      all_source_dirs+=("$(basename "$full_path")")
    done < <(find "${GLOBAL_SOURCE_BASE}" -maxdepth 1 -mindepth 1 -type d -print0)

    SYSTEMS_TO_PROCESS=()
    for dir in "${all_source_dirs[@]}"; do
      local is_excluded=false
      
      # Use the new variable name EXCLUDE_DIRS
      for exclude in "${EXCLUDE_DIRS[@]}"; do
        if [ "$dir" = "$exclude" ]; then
          is_excluded=true
          log_message "  - Skipping excluded system: $dir"
          break
        fi
      done
      
      if ! "$is_excluded"; then
        SYSTEMS_TO_PROCESS+=("$dir")
      fi
    done
  fi

  if [ ${#SYSTEMS_TO_PROCESS[@]} -eq 0 ]; then
    log_message "No systems to process based on targets and exclusions. Exiting."
    exit 0
  fi

  log_message "Identified ${#SYSTEMS_TO_PROCESS[@]} systems for processing: ${SYSTEMS_TO_PROCESS[*]}"

  declare -a FAILED_SYSTEMS=()
  declare -a SUCCESSFUL_SYSTEMS=()
  
  log_message "Checking for source directory: $GLOBAL_SOURCE_BASE"
  check_dir_exists "$GLOBAL_SOURCE_BASE"
  log_message "Checking for target directory: $target_dir"
  check_dir_exists "$target_dir"
  check_free_space "$target_dir" "$min_free_space_gb"

  log_message "Starting system-by-system sync loop for ${#SYSTEMS_TO_PROCESS[@]} systems."

  for system in "${SYSTEMS_TO_PROCESS[@]}"; do
    log_message "\n--- Starting process for system: $system ---"
    
    process_system "$system" "$dry_run_mode" "$copy_bios_enabled" "$purge_target" "$skip_gamelist_sync"
    local system_exit_status=$?

    if [ "$system_exit_status" -eq 0 ] || [ "$system_exit_status" -eq 1 ]; then
      SUCCESSFUL_SYSTEMS+=("$system")
    else
      FAILED_SYSTEMS+=("$system (Exit $system_exit_status)")
      log_message "--- System $system failed (Exit $system_exit_status). Continuing to next system. ---"
    fi
  done

  log_message "\n==================== SYNC SUMMARY ====================="
  if [ ${#SUCCESSFUL_SYSTEMS[@]} -gt 0 ]; then
    log_message "Successful systems: ${SUCCESSFUL_SYSTEMS[*]}"
  else
    log_message "Successful systems: None"
  fi
  if [ ${#FAILED_SYSTEMS[@]} -gt 0 ]; then
    log_message "FAILED systems: ${FAILED_SYSTEMS[*]}"
  else
    log_message "FAILED systems: None"
  fi
  log_message "========================================================"

  if [ ${#FAILED_SYSTEMS[@]} -eq 0 ]; then
    log_message "Executing final sync command to flush write buffers."
    sync
    log_message "$device sync and modifications complete."
    exit 0
  else
    log_message "Script finished with failures in ${#FAILED_SYSTEMS[@]} systems."
    log_message "$device sync and modifications complete (with errors)."
    exit 1
  fi
}

main
