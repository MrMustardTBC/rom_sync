# where your files will go
target_dir="/your/target/path/here/roms"

onionOS="true"

# User-defined BIOS destination
bios_target="/your/target/path/here/bios"

# Folders to exclude from syncing entirely (media and assets)
EXCLUDE_SUBDIRS=(
  # Media and assets
  "screenshot"
  "titleshot"
  "videos"
  "box2dfront"
  #"Imgs"
)

# Add or adjust any system-specific excludes or renames as needed
EXCLUDE_DIRS=(
  # Arcade and emulation
  #"mame2003plus"
  "mame2010"
  "mame2003" 
  "arcade"
  "mame"
  "fbneo"
  #"cps1"
  #"cps2"
  #"cps3"
  "naomi"
  "naomi2"
  "atomiswave"

  # Sega systems
  #"sg1000"
  #"mastersystem"
  #"megadrive"
  #"segacd"
  #"sega32x"
  "saturn"
  "dreamcast"

  #"gamegear"

  # Nintendo systems
  #"nes"
  #"fds"
  #"snes"
  "n64"
  "gamecube"
  "wii"
  "wiiu"
  "switch"
  #"satellaview"
  #"virtualboy"
  #"sufami"

  #"gameandwatch"
  #"pokemini"
  #"gb"
  #"gbc"
  #"gba"
  #"nds"
  "3ds"

  # PlayStation systems
  #"psx"
  "psp"
  "ps2"
  "ps3"

  # Atari systems
  #"atari2600"
  #"atari5200"

  #"atari7800"

  "jaguar" ##
  "jaguarcd"
  
  #"lynx"

  # other gen 1/2 consoles
  #"channelf"
  #"o2em" 
  "astrocde"
  #"intellivision"
  #"colecovision"
  "advision"
  #"vectrex"
  "crvision"
  "arcadia"
  "apfm1000"
  "vc4000"

  # other gen 3 consoles 
  "multivision"
  #"videopacplus"
  "pv1000"
  "scv"
  
  # other gen 4 consoles
  "amigacdtv"
  #"pcengine"
  #"pcenginecd"
  #"supergrafx"
  #"neogeo"
  "cdi"
  "gx4000"
  "supracan"

  # other gen 5 consoles
  "3do" ##
  "amigacd32" ##
  "pcfx" ##
  "neogeocd"

  # portable consoles
  "gamate"
  "gmaster"
  #"supervision"
  #"megaduck" 

  "gamecom"
  "ngp"
  #"ngpc"
  "wswan"
  #"wswanc"
 
  "gp32"

  # Fantasy consoles/computers
  #"arduboy"
  "lowresnx" ##
  "lutro" ##
  "pico8"
  #"tic80"
  "uzebox" ##
  "vircon32"
  "wasm4"
  #"scummvm"
  "openbor" ##
  "vpinball" #
  "zmachine"
  "thextech"
  "zc210"
  "ports"
  
  # Home computers
  "pdp1" #
  "apple2"
  "pet" ##
  "atari800" ##
  "atom" #
  "ti99"
  #"c20"
  "coco"
  "dragon32"
  "pc88" ##
  "zx81" ##
  "bbc"
  "x1"
  #"zxspectrum"
  #"c64"
  "pc98" ##
  "fm7"
  "tutor" #
  "electron" #
  "camplynx" #
  #"msx1"
  "adam" #
  "spectravideo" 
  #"amstradcpc"
  "macintosh" #
  "thomson" #
  "cplus4"
  "laser310" #
  "oric" # Oric Atmos
  "atarist" ##
  #"msx2"
  "c128"
  "apple2gs"
  "archimedes"
  "xegs" # Atari XE Game System 
  #"amiga500"
  "amiga1200"
  "x68000" ##
  "fmtowns"
  "samcoupe"
)

declare -A rename_folders=(
  ["snes"]="SFC"
  ["nes"]="FC"
  ["megadrive"]="MD"
  ["wswanc"]="WS"
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
  ["colecovision"]="COLECO"
  ["videopacplus"]="VIDEOPAC"
  ["channelf"]="FAIRCHILD"
  ["tic80"]="TIC"
  ["pico8"]="PICO"
  ["ngpc"]="NGP"  
  ["msx2"]="MSX"
  ["supergrafx"]="SGFX"
  ["zxspectrum"]="ZXS"
  ["mame2003plus"]="ARCADE"
  ["o2em"]="ODYSSEY"
  ["virtualboy"]="VB"
  ["3do"]="PANASONIC"
  ["c20"]="VIC20"
  ["sega32x"]="THIRTYTWOX"
)
