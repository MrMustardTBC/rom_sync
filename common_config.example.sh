# Global rsync options applicable to all sync scripts
# Using --inplace for local USB/microSD drives can significantly speed up transfers
# by directly modifying existing files.
GLOBAL_RSYNC_OPTIONS="-avh --progress --no-owner --no-group --checksum --delete-after --inplace"

# Source directory where your curated ROMs are located (default)
GLOBAL_SOURCE_BASE="/your/source/dir/here"
