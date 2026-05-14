# Global rsync options applicable to all sync scripts
# Using --inplace for local USB/microSD drives can significantly speed up transfers
# by directly modifying existing files.
GLOBAL_RSYNC_OPTIONS="-avh --progress --no-owner --no-group --inplace"

# Source directory where your curated ROMS are located (default)
GLOBAL_SOURCE_BASE="/your/source/dir/here"

# Safety check: script will error if target drive has less than this much space
min_free_space_gb=1

# List of specific file names or patterns that rsync should always exclude from sync 
# AND deletion checks (e.g., system-generated files that shouldn't be in your source).
declare -a GLOBAL_RSYNC_EXCLUDE_FILES=(
  "systeminfo.txt"
  ".DS_Store"
  "Thumbs.db"
  "gamelist.backup.xml"
  "_info.txt"
  "*.srm"
  "*.state"
)
