# where your files will go
target_dir="/your/target/path/here"

onionOS="false"

# directories you do not want to copy
exclude_dirs=("screenshots" "titlescreens" "gc" )

# Add your specific renames here. Example: ["snes"]="SFC"
declare -A rename_folders=(
  # ["original_system_name"]="new_rg35xxh_name"
  # Example: ["snes"]="SFC"
  ["mame2003plus"]="mame"
  ["mame2010"]="arcade"
)
