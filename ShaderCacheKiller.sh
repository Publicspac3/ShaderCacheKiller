
#!/usr/bin/env bash
#
# Steam Deck Shader Cache Killer
# Fixed and safety-improved version
#
# Usage:
#   ./SDCacheKiller.sh
#   ./SDCacheKiller.sh dry-run
#
# Requires: bash, zenity, du, grep, sed
#

set -o pipefail

# --------------------------------------------------
# Configuration
# --------------------------------------------------

LIVE=1

if [[ "${1:-}" == "dry-run" || "${1:-}" == "--dry-run" ]]; then
    LIVE=0
fi

STEAM_DIR="${HOME}/.local/share/Steam"
STEAMAPPS_DIR="${STEAM_DIR}/steamapps"

# Support alternative Steam symlink location
if [[ ! -d "$STEAMAPPS_DIR" && -d "${HOME}/.steam/steam/steamapps" ]]; then
    STEAM_DIR="${HOME}/.steam/steam"
    STEAMAPPS_DIR="${STEAM_DIR}/steamapps"
fi

# Temporary directory
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/SDCacheKiller.XXXXXX")" || exit 1

cleanup() {
    rm -rf -- "$TMP_DIR"
}

trap cleanup EXIT
trap 'exit 130' INT TERM

# --------------------------------------------------
# Dependencies
# --------------------------------------------------

if ! command -v zenity >/dev/null 2>&1; then
    echo "Error: Zenity is not installed."
    exit 1
fi

if [[ ! -d "$STEAMAPPS_DIR" ]]; then
    zenity --error --width=400 \
        --text="Cannot find Steam directory:\n$STEAMAPPS_DIR"
    exit 1
fi

# --------------------------------------------------
# Functions
# --------------------------------------------------

# Read a value from a Steam VDF manifest
vdf_value() {
    local file="$1"
    local key="$2"

    sed -nE \
        "s/^[[:space:]]*\"${key}\"[[:space:]]*\"(.*)\"[[:space:]]*$/\1/p" \
        "$file" | head -n 1
}

# Remove tabs/newlines from GUI fields
clean_field() {
    printf '%s' "$1" | tr '\t\r\n' '   '
}

# --------------------------------------------------
# Find Steam libraries
# --------------------------------------------------

declare -a STEAM_LIBRARIES=()
declare -A SEEN_LIBRARIES=()

add_library() {
    local path="$1"

    [[ -d "$path" ]] || return

    if [[ -z "${SEEN_LIBRARIES["$path"]+yes}" ]]; then
        STEAM_LIBRARIES+=("$path")
        SEEN_LIBRARIES["$path"]=1
    fi
}

# Always include the primary library
add_library "$STEAMAPPS_DIR"

# Read additional libraries
LIBRARY_FILE="$STEAMAPPS_DIR/libraryfolders.vdf"

if [[ -f "$LIBRARY_FILE" ]]; then

    while IFS= read -r library_path; do
        [[ -n "$library_path" ]] || continue
        add_library "$library_path/steamapps"
    done < <(
        grep -Eo '"path"[[:space:]]*"[^"]+"' "$LIBRARY_FILE" |
        sed -E 's/^"path"[[:space:]]*"//; s/"$//'
    )

fi

echo "Found ${#STEAM_LIBRARIES[@]} Steam libraries:"
printf '  %s\n' "${STEAM_LIBRARIES[@]}"

# --------------------------------------------------
# Choose cache type
# --------------------------------------------------

CACHE_TYPE=$(zenity --list \
    --title="Steam Deck Shader Cache Killer" \
    --width=450 \
    --height=250 \
    --radiolist \
    --column="Select" \
    --column="Cache Type" \
    --print-column=2 \
    TRUE shadercache \
    FALSE compatdata)

if [[ $? -ne 0 || -z "$CACHE_TYPE" ]]; then
    exit 0
fi

# --------------------------------------------------
# Compatdata warning
# --------------------------------------------------

if [[ "$CACHE_TYPE" == "compatdata" ]]; then

    zenity --question \
        --width=450 \
        --title="Warning!" \
        --text="WARNING!\n\nDeleting compatdata removes Proton prefixes.\n\nThis can remove game settings, installed mods and potentially local save data.\n\nSome games may need to rebuild their prefixes.\n\nAre you sure you want to continue?"

    if [[ $? -ne 0 ]]; then
        exit 0
    fi

fi

# --------------------------------------------------
# Build GUI list
# --------------------------------------------------

declare -a GUI_ROWS=()
declare -A ALLOWED_PATHS=()

for library in "${STEAM_LIBRARIES[@]}"; do

    CACHE_DIR="$library/$CACHE_TYPE"

    [[ -d "$CACHE_DIR" ]] || continue

    for path in "$CACHE_DIR"/*; do

        # Ignore missing or inaccessible entries
        [[ -d "$path" ]] || continue

        APP_ID="${path##*/}"

        # Find game name
        MANIFEST="$library/appmanifest_${APP_ID}.acf"

        GAME_NAME="Unknown"

        if [[ -f "$MANIFEST" ]]; then
            GAME_NAME="$(vdf_value "$MANIFEST" "name")"
            [[ -n "$GAME_NAME" ]] || GAME_NAME="Unknown"
        fi

        # Preserve original behavior of excluding Proton tools
        if [[ "$GAME_NAME" == *Proton* ]]; then
            continue
        fi

        # Get folder size in MB
        SIZE=$(du -sm -- "$path" 2>/dev/null | awk 'NR==1 {print $1}')

        [[ -n "$SIZE" ]] || SIZE="0"

        GAME_NAME="$(clean_field "$GAME_NAME")"
        LIBRARY_NAME="$(clean_field "$library")"

        # Build Zenity row
        GUI_ROWS+=(
            FALSE
            "$SIZE"
            "$APP_ID"
            "$GAME_NAME"
            "$LIBRARY_NAME"
            "$path"
        )

        # Whitelist valid deletion paths
        ALLOWED_PATHS["$path"]=1

    done

done

if [[ ${#GUI_ROWS[@]} -eq 0 ]]; then
    zenity --info \
        --width=400 \
        --text="No $CACHE_TYPE folders found."

    exit 0
fi

# --------------------------------------------------
# Display selection GUI
# --------------------------------------------------

SELECTED_OUTPUT=$(zenity --list \
    --title="Select $CACHE_TYPE for deletion" \
    --width=1200 \
    --height=720 \
    --checklist \
    --column="Select" \
    --column="Size (MB)" \
    --column="App ID" \
    --column="Game Name" \
    --column="Steam Library" \
    --column="Real Path" \
    --print-column=6 \
    --separator=$'\n' \
    "${GUI_ROWS[@]}")

RET=$?

if [[ $RET -ne 0 ]]; then
    echo "User cancelled."
    exit 0
fi

if [[ -z "$SELECTED_OUTPUT" ]]; then
    zenity --error \
        --width=400 \
        --text="No $CACHE_TYPE selected!"

    exit 1
fi

# Convert selection into array
mapfile -t SELECTED_PATHS <<< "$SELECTED_OUTPUT"

# --------------------------------------------------
# Confirm deletion
# --------------------------------------------------

if [[ $LIVE -eq 1 ]]; then

    zenity --question \
        --width=450 \
        --title="Confirm deletion" \
        --text="You selected ${#SELECTED_PATHS[@]} folders.\n\nCache type: $CACHE_TYPE\n\nAre you sure you want to delete them?"

    if [[ $? -ne 0 ]]; then
        exit 0
    fi

fi

# --------------------------------------------------
# Delete selected folders
# --------------------------------------------------

TOTAL=${#SELECTED_PATHS[@]}
INDEX=0

(
    for path in "${SELECTED_PATHS[@]}"; do

        ((INDEX++))

        echo "# Processing: ${path##*/}"

        # Verify selected path is whitelisted
        if [[ -z "${ALLOWED_PATHS["$path"]+yes}" ]]; then
            echo "# Skipping invalid path!"
            touch "$TMP_DIR/failed"
            continue
        fi

        # Verify parent directory
        EXPECTED_PARENT="${STEAMAPPS_DIR}/$CACHE_TYPE"

        VALID_PARENT=0

        for library in "${STEAM_LIBRARIES[@]}"; do
            if [[ "$path" == "$library/$CACHE_TYPE/"* ]]; then
                VALID_PARENT=1
                break
            fi
        done

        if [[ $VALID_PARENT -ne 1 ]]; then
            echo "# Skipping unsafe path!"
            touch "$TMP_DIR/failed"
            continue
        fi

        if [[ $LIVE -eq 1 ]]; then

            # rm removes a symlink itself, not its target
            if ! rm -rf -- "$path"; then
                echo "# ERROR deleting $path"
                touch "$TMP_DIR/failed"
            fi

        else
            echo "# Dry-run: would delete $path"
        fi

        PERCENTAGE=$((INDEX * 100 / TOTAL))

        echo "$PERCENTAGE"

        sleep 0.2

    done

) | zenity --progress \
    --width=450 \
    --title="Processing $CACHE_TYPE" \
    --text="Starting..." \
    --percentage=0 \
    --auto-close \
    --no-cancel

# --------------------------------------------------
# Results
# --------------------------------------------------

if [[ -f "$TMP_DIR/failed" ]]; then

    zenity --warning \
        --width=450 \
        --text="Finished with some errors.\n\nSome folders could not be deleted."

elif [[ $LIVE -eq 1 ]]; then

    zenity --info \
        --width=400 \
        --text="$CACHE_TYPE successfully cleared!"

else

    zenity --info \
        --width=400 \
        --text="Dry-run completed!\n\nNothing was deleted."

fi

exit 0
