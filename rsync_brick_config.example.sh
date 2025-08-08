# Example config for BRICK
# Copy to rsync_brick_config.sh and edit as needed

target_dir="/your/target/path/here"

# Add or adjust any system-specific excludes or renames as needed
exclude_dirs=(
  # Add system directories to exclude here
)

declare -A rename_folders=(
  # ["original_name"]="new_name"
)
