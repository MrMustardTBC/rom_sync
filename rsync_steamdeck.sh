#!/bin/bash

# Source common parameters
if [ -f "./common_config.sh" ]; then
  source "./common_config.sh"
else
  echo "Error: common_config.sh not found."
  exit 1
fi

# Source script-specific parameters
if [ -f "./rsync_steamdeck_config.sh" ]; then
  source "./rsync_steamdeck_config.sh"
else
  echo "Error: rsync_steamdeck_config.sh not found."
  exit 1
fi

check_dir_exists() {
  local dir="$1"
  if [ ! -d "$dir" ]; then
    echo "Error: Directory '$dir' not found."
    exit 1
  fi
}

merge_favorites() {
  local system_name="$1"
  local source_rom_dir="${GLOBAL_SOURCE_BASE}/${system_name}"
  local target_rom_dir="${target_dir}/${system_name}"
  local gamelist_source="${source_rom_dir}/gamelist.xml"
  local gamelist_target_existing="${target_dir}/${system_name}/gamelist.xml"

  echo "Attempting to merge favorites for $system_name (pre-rsync)..."

  if [ ! -f "$gamelist_source" ]; then
    # Only log a debug message, not a warning, in this case
    echo "  - Debug: Source gamelist.xml not found: '$gamelist_source'. Skipping favorite merge for this system."
    return 0 # Return success (0) as it's not an error we need to act on
  fi

  if [ -f "$gamelist_target_existing" ] && command -v xmlstarlet &> /dev/null; then
    favorites=$(xmlstarlet sel -t -m "/data/game[favorite='true']" -c "." "$gamelist_target_existing")

    if [ -n "$favorites" ]; then
      local gamelist_source_temp="${gamelist_source}.temp"
      cp "$gamelist_source" "$gamelist_source_temp" || {
        echo "Error: Failed to create temporary gamelist file."
        return 1
      }

      while IFS= read -r favorite_game_xml; do
        local old_path=$(echo "$favorite_game_xml" | xmlstarlet sel -t -v "path")
        local old_name=$(echo "$favorite_game_xml" | xmlstarlet sel -t -v "name")

        if xmlstarlet ed -L -u "/data/game[path='$old_path']/favorite" -v "true" "$gamelist_source_temp"; then
          echo "  - Favorite marked (by path): $old_path"
        elif [ -n "$old_name" ]; then
          if xmlstarlet ed -L -u "/data/game[name='$old_name']/favorite" -v "true" "$gamelist_source_temp"; then
            echo "  - Favorite marked (by name): $old_name"
          fi
        fi
      done <<< "$favorites"

      mv "$gamelist_source_temp" "$gamelist_source" || {
        echo "Error: Failed to replace original gamelist file."
        rm -f "$gamelist_source_temp"
        return 1
      }
      sync
    else
      echo "  - No favorites found in old gamelist."
    fi
  else
    echo "  - Old gamelist.xml not found or xmlstarlet not installed for $system_name."
  fi
  return 0
}

reverse_move_media_folders() {
  local system_name="$1"
  local target_system_dir="${target_dir}/${system_name}"
  local media_target_dir="${media_target_base}/${system_name}"

  echo "  - Reversing media folder moves for $system_name..."

  for folder in "${media_folders[@]}"; do
    local source_folder="${media_target_dir}/${folder}"
    local dest_folder="${target_system_dir}/${folder}"

    if [ "$folder" == "Imgs" ]; then
      source_folder="${media_target_dir}/${miximages_name}"
    fi

    if [ -d "$source_folder" ]; then
      echo "    - Moving '$source_folder' back to '$dest_folder'"
      mkdir -p "$(dirname "$dest_folder")" # Ensure parent dir exists before mv
      mv "$source_folder" "$dest_folder" || echo "    - Warning: Failed to move '$source_folder'."
    fi
  done
}

move_media_folders() {
  local system_name="$1"
  local target_system_dir="${target_dir}/${system_name}"
  local media_target_dir="${media_target_base}/${system_name}"

  echo "  - Attempting to move media folders for $system_name..."
  echo "    - Target system directory: $target_system_dir"
  echo "    - Media target directory: $media_target_dir"
  mkdir -p "$media_target_dir" || echo "    - Warning: Failed to create '$media_target_dir'."

  for folder in "${media_folders[@]}"; do
    local source_folder="${target_system_dir}/${folder}"
    local dest_folder="${media_target_dir}/${folder}"

    echo "    - Processing folder: $folder"
    echo "      - Source folder: $source_folder"

    if [ -d "$source_folder" ]; then
      if [ "$folder" == "Imgs" ]; then
        dest_folder="${media_target_dir}/${miximages_name}"
        echo "      - Moving and renaming '$source_folder' to '$dest_folder'"
        mv "$source_folder" "$dest_folder" || echo "      - Warning: Failed to move and rename '$source_folder'."
      else
        echo "      - Moving '$source_folder' to '$dest_folder'"
        mv "$source_folder" "$dest_folder" || echo "      - Warning: Failed to move '$source_folder'."
      fi
    else
      echo "      - Source folder '$source_folder' does not exist."
    fi
  done
}

# --- Check for targeted update arguments ---
if [ $# -gt 0 ]; then
  echo "Targeted update for: $@"
  targeted_systems=("$@") # Directly assign $@ to the array
else
  echo "Full sync from: ${GLOBAL_SOURCE_BASE}"
  # Use a more robust find command and process each result individually
  while IFS= read -r -d $'\0' system_path; do
    system_name=$(basename "$system_path")
    if [[ "$system_name" != "roms" ]] && [[ "$system_name" != "." ]] && [[ "$system_name" != ".." ]]; then
      targeted_systems+=("$system_name")
    fi
  done < <(find "${target_dir}" -maxdepth 1 -type d ! -path "${target_dir}" -print0)
fi

# Debugging: Print the contents of targeted_systems
#echo "Debugging: targeted_systems: ${targeted_systems[@]}"

# --- Check if source and target base directories exist ---
echo "Checking for source directory: $GLOBAL_SOURCE_BASE"
check_dir_exists "$GLOBAL_SOURCE_BASE"
echo "Checking for target directory: $target_dir"
check_dir_exists "$target_dir"
echo "Checking for tools directory: $tools_dir"
check_dir_exists "$tools_dir"
echo "Checking for media target base directory: $media_target_base"
mkdir -p "$media_target_base"  # Create if it doesn't exist (and check result)
if [ ! -d "$media_target_base" ]; then
    echo "Error: Failed to create or find media target base directory: $media_target_base"
    exit 1
fi

# --- Reverse Move Media Folders (before rsync) ---
echo "Reversing media folder moves (before rsync)..."
for system in "${targeted_systems[@]}"; do
  reverse_move_media_folders "$system"
done
sync

# --- Merge Favorites (before rsync) ---
echo "Merging favorites (before rsync)..."
for system in "${targeted_systems[@]}"; do
  merge_favorites "$system"
done
sync

# --- Perform the rsync operation ---
echo "Syncing files to Steam Deck..."

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

# --- Move Media Folders (after rsync) ---
echo "Moving media folders (after rsync)..."
for system in "${targeted_systems[@]}"; do
  move_media_folders "$system"
done

echo "Steam Deck sync and modifications complete."
