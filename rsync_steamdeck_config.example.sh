# where your files will go
target_dir="/your/target/path/here"

onionOS="false"

# directories you do not want to copy
exclude_dirs=("savestates" "switch" "wii" )

# media files are handled differently in ES on steam deck, so this sets up some folder moving and renaming 
tools_dir="/your/target/path/Emulation/tools"
media_target_base="${tools_dir}/downloaded_media"
media_folders=("screenshots" "titlescreens" "videos" "Imgs" "box2dfront")
miximages_name="miximages"
