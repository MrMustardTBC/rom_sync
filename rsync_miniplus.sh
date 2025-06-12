#!/bin/bash

set -euo pipefail # Exit on error, unset variables, and pipe failures
IFS=$' \n\t' 

# Source common parameters
if [ -f "./common_config.sh" ]; then
  source "./common_config.sh"
else
  echo "Error: common_config.sh not found."
  exit 1
fi

# Source script-specific parameters
if [ -f "./rsync_miniplus_config.sh" ]; then
  source "./rsync_miniplus_config.sh"
else
  echo "Error: rsync_miniplus_config.sh not found."
  exit 1
fi

declare -A reverse_rename_folders
for original in "${!rename_folders[@]}"; do
  new="${rename_folders[$original]}"
  reverse_rename_folders["$new"]="$original"
done

check_dir_exists() {
  local dir="$1"
  if [ ! -d "$dir" ]; then
    echo "Error: Directory '$dir' not found."
    exit 1
  fi
}

if [ $# -gt 0 ]; then
  echo "Targeted update for: $@"
  targeted_systems=("$@")
  involved_renames=false
  for item in "${targeted_systems[@]}"; do
    # If the targeted system is in our rename list, we need to do renaming/XML work
    if [[ "${!rename_folders[@]}" =~ "$item" ]]; then
      involved_renames=true
      break # No need to check further if we found one
    fi
    # We also consider it involved if the target system might have a gamelist.xml
    # that needs processing. For simplicity, we'll assume
    # if we're targeting something, and it's not excluded, it's involved.
    # A more refined check could be added here if needed.
    involved_renames=true
    break
  done
else
  echo "Full sync from: ${GLOBAL_SOURCE_BASE}"
  involved_renames=true
  find "${target_dir}" -maxdepth 1 -type d -print0 | while IFS= read -r -d $'\0' system_path; do
    system_name=$(basename "$system_path")
    targeted_systems+=("$system_name")
  done
fi

echo "Checking source directory: $GLOBAL_SOURCE_BASE"
check_dir_exists "$GLOBAL_SOURCE_BASE"
echo "Checking target directory: $target_dir"
check_dir_exists "$target_dir"

if "$involved_renames"; then
  echo "Reverse renaming system folders on SD card..."
  for new_name in "${!reverse_rename_folders[@]}"; do
    original_name="${reverse_rename_folders[$new_name]}"
    # Only rename if we are doing a full sync OR this system is targeted
    if [ $# -eq 0 ] || [[ " ${targeted_systems[@]} " =~ " ${original_name} " ]]; then
      target_new_dir="${target_dir}/${new_name}"
      target_original_dir="${target_dir}/${original_name}"
      if [ -d "$target_new_dir" ]; then
        echo "Renaming '$target_new_dir' back to '$target_original_dir'"
        mv "$target_new_dir" "$target_original_dir" || echo "Warning: Failed to rename '$target_new_dir'."
      fi
    fi
  done

  echo "Syncing files to Miyoo Mini Plus..."
  sync
  rsync_command="rsync $GLOBAL_RSYNC_OPTIONS"

  if [ $# -gt 0 ]; then
    for system in "${targeted_systems[@]}"; do
      rsync_command+=" \"${GLOBAL_SOURCE_BASE}/${system}\""
    done
  else
    rsync_command+=" \"${GLOBAL_SOURCE_BASE}/\""
  fi

  rsync_command+=" \"${target_dir}/\""

  for dir in "${exclude_dirs[@]}"; do
    rsync_command+=" --exclude=\"$dir\""
  done

  eval "$rsync_command" || echo "Error: rsync operation failed."

  echo "Processing gamelist.xml files..."
  find "${target_dir}" -type f -name "gamelist.xml" -print0 | while IFS= read -r -d $'\0' file; do
    # Only process gamelist.xml if its directory is targeted (or full sync)
    target_system=$(basename "$(dirname "$file")")
    if [ $# -eq 0 ] || [[ " ${targeted_systems[@]} " =~ " ${target_system} " ]]; then
      new_file="$(dirname "$file")/miyoogamelist.xml"
      echo "Processing '$file'..."

      echo "Renaming '$file' to '$new_file'"
      mv "$file" "$new_file" || echo "Warning: Failed to rename '$file'."

      # Clean the new miyoogamelist.xml by removing entries with id="0"
      echo "Cleaning '$new_file'..."
      xmlstarlet ed -L -d "//game[@id='0']" "$new_file" || echo "Warning: Failed to clean '$new_file'."
    fi
  done
  
  echo "Renaming specific folders..."
  for original_name in "${!rename_folders[@]}"; do
    new_name="${rename_folders[$original_name]}"
    # Only rename system folders if targeted (or full sync)
    if [ $# -eq 0 ] || [[ " ${targeted_systems[@]} " =~ " ${original_name} " ]]; then
      target_original_dir="${target_dir}/${original_name}"
      target_new_dir="${target_dir}/${new_name}"
      echo "Checking if '$target_original_dir' exists..."
      if [ -d "$target_original_dir" ]; then
        echo "Renaming '$target_original_dir' to '$target_new_dir'"
        mv "$target_original_dir" "$target_new_dir" || echo "Warning: Failed to rename '$target_original_dir'."
      else
        echo "Warning: Directory '$target_original_dir' not found, skipping rename to '$target_new_dir'."
      fi
    fi
  done
fi

echo "Miyoo Mini Plus sync and modifications complete."
