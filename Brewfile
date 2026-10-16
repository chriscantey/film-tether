# Homebrew dependencies for Film Tether.
# Installed by `brew bundle` (and by `scripts/bootstrap.sh` on first run).

brew "libgphoto2"
brew "pkg-config"

# Useful at the CLI when debugging the camera connection independently of the app:
#   gphoto2 --auto-detect      list cameras the system sees
#   gphoto2 --list-config      dump the connected camera's config tree
#   gphoto2 --get-config X     read a property
brew "gphoto2"

# Used by scripts/fetch-compat-libs.sh to read a bottle's URL and checksum
# from Homebrew's API.
brew "jq"

# Optional: source-code formatting.
# brew "swift-format"
