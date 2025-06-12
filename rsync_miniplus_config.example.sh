# where your files will go
target_dir="/your/target/path/here"

# directories you do not want to copy
exclude_dirs=("screenshots" "titlescreens" "videos" "box2dfront" "bios" "dreamcast" "psp" )

# Add your specific renames here. Example: ["snes"]="SFC"
declare -A rename_folders=(
  # ["original_system_name"]="new_rg35xxh_name"
  # Example: ["snes"]="SFC"
  ["snes"]="SFC"
  ["nes"]="FC"
  ["megadrive"]="MD"
  ["wonderswancolor"]="WS"
  ["mastersystem"]="MS"
  ["atari800"]="EIGHTHUNDRED"
  ["atari2600"]="ATARI"
  ["atari5200"]="FIFTYTWOHUNDRED"
  ["atari7800"]="SEVENTYEIGHTHUNDRED"
  ["gamegear"]="GG"
  ["pcengine"]="PCE"
  ["pcenginecd"]="PCECD"
  ["psx"]="PS"
  ["pokemini"]="POKE"
  ["amiga500"]="AMIGA"
  ["c64"]="COMMODORE"
  ["amstradcpc"]="CPC"
  ["neogeocd"]="NEOCD"
  ["sg1000"]="SEGASGONE"
  ["gameandwatch"]="GW"
)
