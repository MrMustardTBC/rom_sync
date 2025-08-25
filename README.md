# rom_sync
bash scripts to sync ROM files to SD cards using rsync and some xml file magic so that some gamelist.xml settings are saved from the target and added to the source

depends on:
xmlstarlet
???

To use, create a config script named rsync_<yourdevice>_config.sh and populate it with a target path and additional information as needed.  At a minumum you will want to change target_dir to your target folder location. e.g. SD Card path

Then modify common_config.sh to reflect your source folder and any changes you want to make to rsync options globally.  At a minimum, you need to set GLOBAL_SOURCE_BASE to point to your source folder. e.g. your curated ROMs folder.

When run, the first parameter is the device name, this must match the string in your config script.  Then there are a number of optional parameters, followed by a space delimited list of folder/system names. If none are provided, all folders not excluded by your device config will be synced.  If names are specified, then those specific folders will be synced, even if they are excluded in the device config.  This is helpful if there are systems that you want to sync only once, for example. 

The script will look at the config options and reverse the renaming of any of the target folders.

Then it will attempt to sync some of the metadata from the target folder's gamelist.xml to the source folder's gamelist.xml.  This can be avoided with --skip-gamelist-sync which will skip this step entirely.  Metadata synced includes favorites, crc32, cheevosId, and cheeveosHash.  This is intended to try to preserve any changes made to those fields by updating your source folder to reflect those changes.  This does require xmlstarlet.

It will then take a moment to calculate how many files will be copied for each system.

Then it will run the rsync command for the folder(s) as specified.  If --purge is provided as a parameter, this will delete anything that does not match the source folder which is useful for cleaning up if you have made a lot of changes, but is not necessary for smaller updates.

If the device config specifies that media folders should be moved, then the script will move them accordingly.

If the device config specifies that folders should be renamed, they will be renamed.

There is some janky code I had forgotten about at the end if the device name is "miniplus".  It needs to be more generalized and put in the config script to indicate if the device is running OnionOS, in which case it does some changes to the gamelist to make it compatible with OnionOS...
