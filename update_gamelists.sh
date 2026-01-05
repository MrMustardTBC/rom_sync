#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -euo pipefail
IFS=$'\n\t'

# --- CONFIGURATION ADJUSTMENTS ---

# Set to 750: Increased chunk size for better performance (v12) 
# while remaining well below the stability limits of the eval command.
CHUNK_SIZE_GAMES=750 

# --- DEBUG SETTING ---
# Keeping this false for production speed.
DEBUG_MODE=false
# ---------------------

# --- Configuration Loading ---
script_dir="$(dirname "$(readlink -f "$0")")"
config_common_file="${script_dir}/common_config.sh"

if [ -f "$config_common_file" ]; then
    echo "Loading common configuration from $config_common_file..."
    set +u
    source "$config_common_file"
    set -u
else
    echo "Fatal Error: Common configuration file not found: $config_common_file" >&2
    exit 1
fi

: "${GLOBAL_SOURCE_BASE:?Error: GLOBAL_SOURCE_BASE is not set in common_config.sh}"

MEDIA_BASE="images"   
VIDEO_BASE="videos"   
MANUAL_BASE="manuals" 

declare -a MEDIA_DEFINITIONS=(
    "image:${MEDIA_BASE}:.png,.jpg,.jpeg,.PNG,.JPG,.JPEG"
    "video:${VIDEO_BASE}:.mp4"
    "thumbnail:${MEDIA_BASE}/box2dfront:.png,.jpg,.jpeg,.PNG,.JPG,.JPEG" 
    "marquee:${MEDIA_BASE}/marquee:.png,.jpg,.jpeg,.PNG,.JPG,.JPEG"
    "fanart:${MEDIA_BASE}/fanart:.png,.jpg,.jpeg,.PNG,.JPG,.JPEG"
    "titleshot:${MEDIA_BASE}/titleshot:.png,.jpg,.jpeg,.PNG,.JPG,.JPEG"
    "manual:${MANUAL_BASE}:.pdf"
)

# --- Core Processing Function ---

process_gamelist() {
    local system_name="$1"
    local system_dir="${GLOBAL_SOURCE_BASE}/${system_name}"
    local gamelist_file="${system_dir}/gamelist.xml"
    
    echo -e "\n--- Processing system: **$system_name** ---"

    if [ ! -d "$system_dir" ]; then
        echo "  - Error: System directory does not exist: $system_dir. Skipping." >&2
        return 1
    fi

    if [ ! -f "$gamelist_file" ]; then
        echo "  - Gamelist file not found: $gamelist_file. Skipping."
        return 0
    fi
    
    # NEW CHECK (v18): Ensure write permission before starting
    # This correctly anticipates the 'Permission denied' error
    if [ ! -w "$gamelist_file" ] || [ ! -w "$system_dir" ]; then
        echo "  - FATAL ERROR: Permission denied. Cannot write to $gamelist_file or directory $system_dir." >&2
        return 2 # Return a unique error code for permissions
    fi

    # Create a backup before modification
    cp "$gamelist_file" "${gamelist_file}.bak"
    echo "  - Backup created at ${gamelist_file}.bak"
    
    if ! command -v xmlstarlet &> /dev/null; then
        echo "Fatal Error: xmlstarlet could not be found. Please install it." >&2
        exit 1
    fi

    # 1. Extract all game entries
    local games_data
    games_data=$(xmlstarlet sel -t -m "//game" -v "path" -o "|" -v "path" -o $'\n' "$gamelist_file" 2>/dev/null)

    local total_tag_updates=0 
    # v18: Change from string to array for safe execution
    declare -a xmlstarlet_args=()
    local games_in_chunk=0
    
    # 2. Iterate over each game
    while IFS='|' read -r full_path rom_path; do
        if [ -z "$full_path" ]; then continue; fi

        # v18: Simplified escaping. We only need to escape double quotes for the XPath string literal.
        # Array execution handles spaces, dollar signs, and apostrophes safely.
        local safe_full_path
        safe_full_path=$(echo "$full_path" | sed 's/"/\\"/g') 
        
        # Use the safest XPath key with internal escaping for XMLStarlet
        local xpath_base="//game[normalize-space(path)=\"${safe_full_path}\"]"

        # -----------------------------------------------------------------------------

        local rom_filename
        rom_filename=$(basename "$rom_path")
        local base_name="${rom_filename%.*}"
        
        base_name=$(echo "$base_name" | tr -d '\r')

        # v18: No escaping needed for the media path base name.
        local escaped_for_xml_base_name="${base_name}"
        
        local game_updates=0
        
        # 3. Check for existence of each media type and build commands
        for def in "${MEDIA_DEFINITIONS[@]}"; do
            IFS=':' read -r tag_name rel_dir extensions <<< "$def"
            
            local file_found=false
            local found_ext=""
            
            # Check for file existence on disk (uses original, unescaped base_name)
            IFS=',' read -r -a ext_array <<< "$extensions"
            for ext in "${ext_array[@]}"; do
                local check_file="${system_dir}/${rel_dir}/${base_name}${ext}"
                if [ -f "$check_file" ]; then
                    file_found=true
                    found_ext="$ext"
                    break
                fi
            done

            if "$file_found"; then
                # Build final path using the unescaped base name
                local xml_rel_path="./${rel_dir}/${escaped_for_xml_base_name}"
                local final_xml_path="${xml_rel_path}${found_ext}"

                # v18: Add arguments to the array (safe execution)
                
                # Command to UPDATE the tag if it already exists
                xmlstarlet_args+=("-u" "${xpath_base}/${tag_name}" "-v" "${final_xml_path}")
                
                # Command to INSERT the tag if it does NOT exist
                xmlstarlet_args+=("-s" "${xpath_base}[not(${tag_name})]" "-t" "elem" "-n" "${tag_name}" "-v" "${final_xml_path}")
                
                game_updates=$((game_updates + 1))
            fi
        done
        
        if [ "$game_updates" -gt 0 ]; then
            total_tag_updates=$((total_tag_updates + game_updates))
            games_in_chunk=$((games_in_chunk + 1))
        fi
        
        # --- CHUNKING LOGIC: Execute commands if the batch size is reached ---
        if [ "$games_in_chunk" -ge "$CHUNK_SIZE_GAMES" ]; then
            echo -n "." 
            
            # v18: Execute command array directly (SAFE)
            if xmlstarlet ed -L "${xmlstarlet_args[@]}" "$gamelist_file"; then 
                xmlstarlet_args=()
                games_in_chunk=0
            else
                echo -e "\n\n!!! XMLSTARLET ERROR OCCURRED !!!" >&2
                echo "  - CRITICAL ERROR: XMLStarlet batch sync failed for $system_name. Restoring backup." >&2
                mv "${gamelist_file}.bak" "$gamelist_file" 2>/dev/null || true # Ignore error if backup restore fails
                return 1
            fi
        fi
        # --- END CHUNKING LOGIC ---
        
    done <<< "$games_data"

    # 4. Execute final remaining XMLStarlet commands
    if [ ${#xmlstarlet_args[@]} -gt 0 ]; then
        echo -n "."
        
        # v18: Execute command array directly (SAFE)
        if xmlstarlet ed -L "${xmlstarlet_args[@]}" "$gamelist_file"; then
            echo # Print newline after dots
            : # Success
        else
            echo -e "\n\n!!! XMLSTARLET ERROR OCCURRED !!!" >&2
            echo "  - CRITICAL ERROR: XMLStarlet final batch failed for $system_name. Restoring backup." >&2
            mv "${gamelist_file}.bak" "$gamelist_file" 2>/dev/null || true # Ignore error if backup restore fails
            return 1
        fi
    fi
    
    # 5. Final summary
    if [ "$total_tag_updates" -gt 0 ]; then
        echo "  - Successfully updated **$total_tag_updates** media tags in gamelist.xml."
        rm -f "${gamelist_file}.bak" 2>/dev/null || true # Ignore error if backup removal fails
    else
        echo "  - No new media tags required updating for this system."
        rm -f "${gamelist_file}.bak" 2>/dev/null || true
    fi

    return 0
}

# --- Main Logic (Subshell Isolation Retained) ---

main() {
    echo "--- Starting Gamelist Media Update Script ---"
    
    local systems_to_process=()
    
    if [ $# -gt 0 ]; then
        systems_to_process=("$@")
        echo "Mode: **Targeted Update** - Processing **$#** specified system(s)."
    else
        while IFS= read -r -d $'\0' full_path; do
          systems_to_process+=("$(basename "$full_path")")
        done < <(find "${GLOBAL_SOURCE_BASE}" -maxdepth 1 -mindepth 1 -type d -print0)

        if [ ${#systems_to_process[@]} -eq 0 ]; then
            echo "Warning: No system directories found under $GLOBAL_SOURCE_BASE. Exiting."
            exit 0
        fi
        echo "Mode: **Full Scan** - Found **${#systems_to_process[@]}** system directories under GLOBAL_SOURCE_BASE."
    fi
    
    local failed_systems=0

    # Retain subshell '()' for system processing to ensure environmental isolation
    for system in "${systems_to_process[@]}"; do
        if ! ( process_gamelist "$system" ); then
            failed_systems=$((failed_systems + 1))
        fi
    done

    echo -e "\n==================== SYNC SUMMARY ====================="
    if [ "$failed_systems" -eq 0 ]; then
        echo "All systems processed successfully. Your metadata is pristine."
        exit 0
    else
        echo "**$failed_systems** systems encountered a critical XML processing error."
        echo "Please inspect the respective gamelist.xml.bak file and logs for details."
        exit 1
    fi
}

main "$@"