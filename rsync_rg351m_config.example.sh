# where your files will go
target_dir="/your/target/path/here"

onionOS="false"

# directories you do not want to copy
exclude_dirs=("screenshots" "titlescreens" "box2dfront" "gc" )

# Add your specific renames here. Example: ["snes"]="SFC"
declare -A rename_folders=(
  # ["original_system_name"]="new_rg35xxh_name"
  # Example: ["snes"]="SFC"
  ["msx1"]="msx"
  ["amiga500"]="amiga"
  ["jaguar"]="atarijaguar"
  ["lynx"]="atarilynx"
  ["neogeocd"]="neocd"
  ["sg1000"]="sg-1000"
  ["pico8"]="pico-8"
  ["mame2003plus"]="arcade"
  ["mame2010"]="mame"
)
