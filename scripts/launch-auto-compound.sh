#!/usr/bin/env bash
# launch-auto-compound.sh
# The ONLY correct way to launch the build pipeline on macOS.
# Opens a new Terminal.app window with the required env var.
#
# Usage:
#   ./launch-auto-compound.sh --project-path "./your-project" --verbose
#   ./launch-auto-compound.sh --project-path "./your-project" --dry-run

set -euo pipefail

# --- Argument parsing ---
project_path=""
inner_args=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project-path)
            project_path="$2"
            inner_args+=" --project-path \"$2\""
            shift 2 ;;
        *)
            inner_args+=" $1"
            shift ;;
    esac
done

if [[ -z "$project_path" ]]; then
    echo "ERROR: --project-path is required" >&2
    echo "Usage: $0 --project-path \"./your-project\" [--verbose] [--dry-run] [--resume]" >&2
    exit 1
fi

# Resolve to absolute path
project_path=$(cd "$project_path" && pwd)
script_dir="$(cd "$(dirname "$0")" && pwd)"

# Update inner_args with resolved path
inner_args=$(echo "$inner_args" | sed "s|--project-path \"[^\"]*\"|--project-path \"$project_path\"|")

# Create a temp wrapper script
wrapper=$(mktemp /tmp/agent-relay-XXXXXXXX.sh)
cat > "$wrapper" << WRAPPER_EOF
#!/usr/bin/env bash
export AGENT_RELAY_VISIBLE_LAUNCH=1
cd "$script_dir"
./auto-compound.sh $inner_args
echo ""
echo "Pipeline finished. Press Enter to close."
read -r
WRAPPER_EOF
chmod +x "$wrapper"

# Detect terminal emulator and open in a new visible window
if pgrep -x "iTerm2" > /dev/null 2>&1; then
    # iTerm2 is running - use it
    osascript -e "
        tell application \"iTerm\"
            create window with default profile command \"bash '$wrapper'\"
        end tell
    " 2>/dev/null
elif [[ -d "/Applications/iTerm.app" ]]; then
    # iTerm2 is installed but not running
    osascript -e "
        tell application \"iTerm\"
            activate
            create window with default profile command \"bash '$wrapper'\"
        end tell
    " 2>/dev/null
else
    # Default: use Terminal.app
    osascript -e "
        tell application \"Terminal\"
            activate
            do script \"bash '$wrapper'\"
        end tell
    " 2>/dev/null
fi

echo "Pipeline launched in visible terminal window for: $project_path"
