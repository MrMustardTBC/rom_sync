#!/bin/bash

# --- CONFIGURATION ---
ROM_DIR="${1:-.}"
INTERNAL_IFS="~" 

ROM_EXTENSIONS=(
    "d88" 
    "dsk" 
    "hdm" 
    "mdf"
    "iso" 
    "cue" 
    "chd"
    "ccd" 
    "img"
    "bin"
    "zip"
)

# Destination folder name
PROCESSED_DIR=".hidden" 

# 🚨 FINAL ROBUST PATTERN: Combines all requirements: Disk/Disc, 01/10, optional 'of X', and allows trailing tags.
# This pattern is slightly stricter than v34.0 around the disk number to ensure capture is non-empty.
# Group 1: Media Type (Disc|Disk|Tape)
# Group 2: Disk Number (01, 10, etc.)
DISK_PATTERN_CORE='[[:space:]]*[([[:space:]]*(Disc|Disk|Tape)[[:space:]]*([0-9]+)([[:space:]]*of[[:space:]]*[0-9]+)?)?.*'

# --- FUNCTIONS ---

# Function to move files specified in a file list
move_files_from_list() {
    local FILE_LIST="$1"
    local DESTINATION="${ROM_DIR}/${PROCESSED_DIR}"
    
    mkdir -p "$DESTINATION"
    
    if [ ! -s "$FILE_LIST" ]; then
        echo "  - File list is empty. No files to move."
        return 0
    fi
    
    local TOTAL_FILES=$(wc -l < "$FILE_LIST")
    echo "  - Moving **$TOTAL_FILES** disk files (including Disk 1) to **$PROCESSED_DIR**"
    
    local MOVED_COUNT=0
    
    # Read the list of full file paths from the temporary file line by line
    while IFS= read -r FILE_PATH; do
        
        if [ -f "$FILE_PATH" ]; then
            
            # Use -t (target directory) and -- for maximum safety
            mv -f -- "$FILE_PATH" -t "$DESTINATION" 2>/dev/null
            
            if [ ! -f "$FILE_PATH" ]; then
                MOVED_COUNT=$((MOVED_COUNT + 1))
            else
                local FILENAME=$(basename "$FILE_PATH")
                echo "  🚨 ERROR: Failed to move Disk file **$FILENAME**. Path attempted: '$FILE_PATH'. Check permissions or file corruption." > /dev/stderr
            fi
        fi
    done < "$FILE_LIST"
    
    echo "  - Successfully moved **$MOVED_COUNT** files."
}

# ----------------------------------------------------------------------------------
## Core Logic: File Scanning and Data Extraction 

echo "Scanning folder: **$ROM_DIR** for multi-disk/tape files..."
TEMP_FILE=$(mktemp) 

for EXT in "${ROM_EXTENSIONS[@]}"; do
    find "$ROM_DIR" -maxdepth 1 -type f -iname "*.$EXT" -print0 | while IFS= read -r -d $'\0' FULL_PATH; do
        FILENAME=$(basename "$FULL_PATH")
        BASE_NAME="${FILENAME%.*}" 
        
        echo "DEBUG: Processing file: **$FILENAME**" > /dev/stderr
        echo "DEBUG: Base name is: **$BASE_NAME**" > /dev/stderr

        AWK_OUTPUT=$(echo "$BASE_NAME" | awk -v pattern="$DISK_PATTERN_CORE" -v filename="$FILENAME" -v IFS_CHAR="$INTERNAL_IFS" '
            {
                # Match the pattern against the base name
                if (match($0, pattern, arr)) {
                    
                    # Group 2 is the disk number capture (the [0-9]+ part)
                    DISK_NUM = arr[2] 
                    
                    # Everything before the match is the potential game name
                    GAME_NAME_TEMP = substr($0, 1, RSTART - 1)
                    
                    # 1. Aggressive cleanup: strips leading/trailing space, dots, underscores, and dashes
                    gsub(/^[[:space:]._-]+|[[:space:]._-]+$/, "", GAME_NAME_TEMP)
                    
                    # 2. Skip if the result is only whitespace or if disk number is empty
                    if (GAME_NAME_TEMP ~ /^[[:space:]]*$/ || DISK_NUM == "") {
                        # The pattern matched (arr[1] and arr[2] are set), but the captured groups are empty
                        system("echo \"DEBUG FAILED: Extracted GameName='\047" GAME_NAME_TEMP "\047', DiskNum='\047" DISK_NUM "\047'\" > /dev/stderr")
                    } else {
                        print DISK_NUM IFS_CHAR GAME_NAME_TEMP IFS_CHAR filename
                        system("echo \"DEBUG: SUCCESS: AWK Output: " DISK_NUM IFS_CHAR GAME_NAME_TEMP IFS_CHAR filename "\" > /dev/stderr")
                    }
                } else {
                    # The pattern failed to match the Disk/Disc/Tape indicator altogether (e.g., Sichuan)
                    system("echo \"DEBUG FAILED: Pattern did not match: " $0 "\" > /dev/stderr")
                }
            }
        ')

        if [[ -n "$AWK_OUTPUT" ]]; then
            # The pattern is successful, write to temp file
            echo "$AWK_OUTPUT" >> "$TEMP_FILE"
        fi
        
    done
done

# --- Check for Multi-Disk Games Before Proceeding ---
if [ ! -s "$TEMP_FILE" ]; then
    echo -e "\nNo multi-disk/tape games found based on the expected naming pattern."
    rm -f "$TEMP_FILE"
    exit 0
fi

# ----------------------------------------------------------------------------------
## Final Processing: Sorting, M3U Creation, and File Moving

echo -e "\nProcessing found games and creating .m3u files..."

# Temporary file to hold the list of files to move for safe processing
MOVE_LIST_TEMP=$(mktemp) 

# --- AWK EXECUTION ---
AWK_OUTPUT=$(
    # Sort numerically (-k1,1n) by disk number, preventing string sorting errors (01 > 10).
    sort -t "$INTERNAL_IFS" -k2,2 -k1,1n "$TEMP_FILE" | \
    LC_ALL=C awk -F "$INTERNAL_IFS" -v DIR_PATH="$ROM_DIR" -v PROCESSED_DIR="$PROCESSED_DIR" '
    
    function escape_regex(str) {
        gsub(/\\/,"\\&",str) 
        gsub(/([$^*+?()|.[\]])/, "\\\\&", str);
        return str;
    }

    {
        # Store the disk number (field 1) as a numeric key to avoid string comparisons.
        lines[$2, $1 + 0] = $0
        games[$2] = 1
    }

    END {
        for (game in games) {
            
            if (game == "") {
                print "FATAL ERROR: A record with an empty GameName field was detected. Skipping file creation." > "/dev/stderr"
                continue
            }
            
            M3U_FILE = DIR_PATH "/" game ".m3u"
            
            max_disk = 0
            
            escaped_game = escape_regex(game)
            game_pattern = "^" escaped_game SUBSEP 

            for (key in lines) {
                if (key ~ game_pattern) { 
                    split(key, arr, SUBSEP)
                    disk_num_numeric = arr[2]
                    
                    if (disk_num_numeric > max_disk) { max_disk = disk_num_numeric }
                }
            }

            if (max_disk > 1) {
                
                print "---M3U_CREATED--- " game " (" max_disk " media)"

                for (i = 1; i <= max_disk; i++) {
                    record = lines[game, i]
                    if (record != "") {
                        split(record, fields, "'"$INTERNAL_IFS"'")
                        
                        FILENAME = fields[3]
                        
                        print PROCESSED_DIR "/" FILENAME > M3U_FILE
                        
                        print "---FILE_TO_MOVE---" DIR_PATH "/" FILENAME
                    }
                }
            } else {
                print "Skipping \047" game "\047: Found only 1 media file." > "/dev/stderr"
            }
        }
    }
    ' 2>&1
)

# --- SHELL PROCESSING ---

# Filter out status messages from the file paths and write paths to the temporary move file
echo "$AWK_OUTPUT" | grep "^---FILE_TO_MOVE---" | sed 's/---FILE_TO_MOVE---//' > "$MOVE_LIST_TEMP"

# Display M3U creation status messages
echo "$AWK_OUTPUT" | grep -v "^---FILE_TO_MOVE---"

# Call the file move function only once after all M3U files are created
move_files_from_list "$MOVE_LIST_TEMP"

# --- FINAL SUMMARY ---

M3U_COUNT=$(echo "$AWK_OUTPUT" | grep "^---M3U_CREATED---" | wc -l)
M3U_COUNT="${M3U_COUNT:-0}" 

if [ "$M3U_COUNT" -gt 0 ]; then
    echo -e "\nSuccess! Created and moved files for **$M3U_COUNT** games."
else
    echo -e "\nNo M3U files were successfully created."
fi

# Clean up both temporary files
rm -f "$TEMP_FILE" "$MOVE_LIST_TEMP"