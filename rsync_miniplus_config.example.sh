# where your files will go
target_dir="/your/target/path/here"

onionOS="true"

# User-defined BIOS destination
bios_target="/media/mbb/RGCUBEXX/bios"

# Add or adjust any system-specific excludes or renames as needed
# If it is commented out, it will be synced
exclude_dirs=(
  # Media and assets
  "screenshots"
  "titlescreens"
  #"videos"
  #"box2dfront"
  "bios"

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
  "gc"
  "wii"
  "wiiu"
  "switch"

  #"gameandwatch"
  #"pokemini"
  #"gb"
  #"gbc"
  #"gba"
  #"ds"
  "3ds"
  #"sufami"

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
  "cdtv"
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
  "thompson" #
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

)
