#!/bin/bash
# Mole - UI Components
# Terminal UI utilities: cursor control, keyboard input, spinners, menus

set -euo pipefail

if [[ -n "${MOLE_UI_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_UI_LOADED=1

_MOLE_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -z "${MOLE_BASE_LOADED:-}" ]] && source "$_MOLE_CORE_DIR/base.sh"

# Cursor control
clear_screen() { printf '\033[2J\033[H'; }
hide_cursor() { [[ -t 1 ]] && printf '\033[?25l' >&2 || true; }
show_cursor() { [[ -t 1 ]] && printf '\033[?25h' >&2 || true; }

# Calculate display width of a string (CJK characters count as 2)
# Args: $1 - string to measure
# Returns: display width
# Note: Works correctly even when LC_ALL=C is set
get_display_width() {
    local str="$1"

    # Optimized pure bash implementation without forks
    local width

    # Save current locale
    local old_lc="${LC_ALL:-}"

    # Get Char Count (UTF-8)
    # We must export ensuring it applies to the expansion (though just assignment often works in newer bash, export is safer for all subshells/cmds)
    export LC_ALL=en_US.UTF-8
    local char_count=${#str}

    # Get Byte Count (C)
    export LC_ALL=C
    local byte_count=${#str}

    # Restore Locale immediately
    if [[ -n "$old_lc" ]]; then
        export LC_ALL="$old_lc"
    else
        unset LC_ALL
    fi

    if [[ $byte_count -eq $char_count ]]; then
        echo "$char_count"
        return
    fi

    # CJK Heuristic:
    # Most CJK chars are 3 bytes in UTF-8 and width 2.
    # ASCII chars are 1 byte and width 1.
    # Width ~= CharCount + (ByteCount - CharCount) / 2
    # "中" (1 char, 3 bytes) -> 1 + (2)/2 = 2.
    # "A" (1 char, 1 byte) -> 1 + 0 = 1.
    # This is an approximation but very fast and sufficient for App names.
    # Integer arithmetic in bash automatically handles floor.
    local extra_bytes=$((byte_count - char_count))
    local padding=$((extra_bytes / 2))
    width=$((char_count + padding))

    echo "$width"
}

# Truncate string by display width (handles CJK correctly)
# Args: $1 - string, $2 - max display width
truncate_by_display_width() {
    local str="$1"
    local max_width="$2"
    local current_width
    current_width=$(get_display_width "$str")

    if [[ $current_width -le $max_width ]]; then
        echo "$str"
        return
    fi

    # Fallback: Use pure bash character iteration
    # Since we need to know the width of *each* character to truncate at the right spot,
    # we cannot just use the total width formula on the whole string.
    # However, iterating char-by-char and calling the optimized get_display_width function
    # is now much faster because it doesn't fork 'wc'.

    # CRITICAL: Switch to UTF-8 for correct character iteration
    local old_lc="${LC_ALL:-}"
    export LC_ALL=en_US.UTF-8

    local truncated=""
    local width=0
    local i=0
    local char char_width
    local strlen=${#str} # Re-calculate in UTF-8

    # Optimization: If total width <= max_width, return original string (checked above)

    while [[ $i -lt $strlen ]]; do
        char="${str:$i:1}"

        # Inlined width calculation for minimal overhead to avoid recursion overhead
        # We are already in UTF-8, so ${#char} is char length (1).
        # We need byte length for the heuristic.
        # But switching locale inside loop is disastrous for perf.
        # Logic: If char is ASCII (1 byte), width 1.
        # If char is wide (3 bytes), width 2.
        # How to detect byte size without switching locale?
        # printf %s "$char" | wc -c ? Slow.
        # Check against ASCII range?
        # Fast ASCII check: if [[ "$char" < $'\x7f' ]]; then ...

        if [[ "$char" =~ [[:ascii:]] ]]; then
            char_width=1
        else
            # Assume wide for non-ascii in this context (simplified)
            # Or use LC_ALL=C inside? No.
            # Most non-ASCII in filenames are either CJK (width 2) or heavy symbols.
            # Let's assume 2 for simplicity in this fast loop as we know we are usually dealing with CJK.
            char_width=2
        fi

        if ((width + char_width + 3 > max_width)); then
            break
        fi

        truncated+="$char"
        ((width += char_width))
        ((i++))
    done

    # Restore locale
    if [[ -n "$old_lc" ]]; then
        export LC_ALL="$old_lc"
    else
        unset LC_ALL
    fi

    echo "${truncated}..."
}

# Keyboard input - read single keypress
read_key() {
    local key rest read_status
    IFS= read -r -s -n 1 key
    read_status=$?
    [[ $read_status -ne 0 ]] && {
        echo "QUIT"
        return 0
    }

    if [[ "${MOLE_READ_KEY_FORCE_CHAR:-}" == "1" ]]; then
        [[ -z "$key" ]] && {
            echo "ENTER"
            return 0
        }
        case "$key" in
            $'\n' | $'\r') echo "ENTER" ;;
            $'\x7f' | $'\x08') echo "DELETE" ;;
            $'\x1b') echo "QUIT" ;;
            [[:print:]]) echo "CHAR:$key" ;;
            *) echo "OTHER" ;;
        esac
        return 0
    fi

    [[ -z "$key" ]] && {
        echo "ENTER"
        return 0
    }
    case "$key" in
        $'\n' | $'\r') echo "ENTER" ;;
        ' ') echo "SPACE" ;;
        '/') echo "FILTER" ;;
        'q' | 'Q') echo "QUIT" ;;
        'R') echo "RETRY" ;;
        'm' | 'M') echo "MORE" ;;
        'u' | 'U') echo "UPDATE" ;;
        't' | 'T') echo "TOUCHID" ;;
        'j' | 'J') echo "DOWN" ;;
        'k' | 'K') echo "UP" ;;
        'h' | 'H') echo "LEFT" ;;
        'l' | 'L') echo "RIGHT" ;;
        $'\x03') echo "QUIT" ;;
        $'\x7f' | $'\x08') echo "DELETE" ;;
        $'\x1b')
            if IFS= read -r -s -n 1 -t 1 rest 2> /dev/null; then
                if [[ "$rest" == "[" ]]; then
                    if IFS= read -r -s -n 1 -t 1 rest2 2> /dev/null; then
                        case "$rest2" in
                            "A") echo "UP" ;; "B") echo "DOWN" ;;
                            "C") echo "RIGHT" ;; "D") echo "LEFT" ;;
                            "3")
                                IFS= read -r -s -n 1 -t 1 rest3 2> /dev/null
                                [[ "$rest3" == "~" ]] && echo "DELETE" || echo "OTHER"
                                ;;
                            *) echo "OTHER" ;;
                        esac
                    else echo "QUIT"; fi
                elif [[ "$rest" == "O" ]]; then
                    if IFS= read -r -s -n 1 -t 1 rest2 2> /dev/null; then
                        case "$rest2" in
                            "A") echo "UP" ;; "B") echo "DOWN" ;;
                            "C") echo "RIGHT" ;; "D") echo "LEFT" ;;
                            *) echo "OTHER" ;;
                        esac
                    else echo "OTHER"; fi
                else echo "OTHER"; fi
            else echo "QUIT"; fi
            ;;
        [[:print:]]) echo "CHAR:$key" ;;
        *) echo "OTHER" ;;
    esac
}

drain_pending_input() {
    local drained=0
    while IFS= read -r -s -n 1 -t 0.01 _ 2> /dev/null; do
        ((drained++))
        [[ $drained -gt 100 ]] && break
    done
}

# Menu display
show_menu_option() {
    local number="$1"
    local text="$2"
    local selected="$3"

    if [[ "$selected" == "true" ]]; then
        echo -e "${CYAN}${ICON_ARROW} $number. $text${NC}"
    else
        echo "  $number. $text"
    fi
}

# Inline spinner
INLINE_SPINNER_PID=""
start_inline_spinner() {
    stop_inline_spinner 2> /dev/null || true
    local message="$1"

    if [[ -t 1 ]]; then
        (
            trap 'exit 0' TERM INT EXIT
            local chars
            chars="$(mo_spinner_chars)"
            [[ -z "$chars" ]] && chars="|/-\\"
            local i=0
            while true; do
                local c="${chars:$((i % ${#chars})):1}"
                # Output to stderr to avoid interfering with stdout
                printf "\r${MOLE_SPINNER_PREFIX:-}${BLUE}%s${NC} %s" "$c" "$message" >&2 || exit 0
                ((i++))
                sleep 0.1
            done
        ) &
        INLINE_SPINNER_PID=$!
        disown 2> /dev/null || true
    else
        echo -n "  ${BLUE}|${NC} $message" >&2
    fi
}

stop_inline_spinner() {
    if [[ -n "$INLINE_SPINNER_PID" ]]; then
        # Try graceful TERM first, then force KILL if needed
        if kill -0 "$INLINE_SPINNER_PID" 2> /dev/null; then
            kill -TERM "$INLINE_SPINNER_PID" 2> /dev/null || true
            sleep 0.05 2> /dev/null || true
            # Force kill if still running
            if kill -0 "$INLINE_SPINNER_PID" 2> /dev/null; then
                kill -KILL "$INLINE_SPINNER_PID" 2> /dev/null || true
            fi
        fi
        wait "$INLINE_SPINNER_PID" 2> /dev/null || true
        INLINE_SPINNER_PID=""
        # Clear the line - use \033[2K to clear entire line, not just to end
        [[ -t 1 ]] && printf "\r\033[2K" >&2
    fi
}

# Wrapper for running commands with spinner
with_spinner() {
    local msg="$1"
    shift || true
    local timeout="${MOLE_CMD_TIMEOUT:-180}"
    start_inline_spinner "$msg"
    local exit_code=0
    if [[ -n "${MOLE_TIMEOUT_BIN:-}" ]]; then
        "$MOLE_TIMEOUT_BIN" "$timeout" "$@" > /dev/null 2>&1 || exit_code=$?
    else "$@" > /dev/null 2>&1 || exit_code=$?; fi
    stop_inline_spinner "$msg"
    return $exit_code
}

# Get spinner characters
mo_spinner_chars() {
    local chars="${MO_SPINNER_CHARS:-|/-\\}"
    [[ -z "$chars" ]] && chars="|/-\\"
    printf "%s" "$chars"
}

# Format last used time for display
# Args: $1 = last used string (e.g., "3 days ago", "Today", "Never")
# Returns: Compact version (e.g., "3d ago", "Today", "Never")
format_last_used_summary() {
    local value="$1"

    case "$value" in
        "" | "Unknown")
            echo "Unknown"
            return 0
            ;;
        "Never" | "Recent" | "Today" | "Yesterday" | "This year" | "Old")
            echo "$value"
            return 0
            ;;
    esac

    if [[ $value =~ ^([0-9]+)[[:space:]]+days?\ ago$ ]]; then
        echo "${BASH_REMATCH[1]}d ago"
        return 0
    fi
    if [[ $value =~ ^([0-9]+)[[:space:]]+weeks?\ ago$ ]]; then
        echo "${BASH_REMATCH[1]}w ago"
        return 0
    fi
    if [[ $value =~ ^([0-9]+)[[:space:]]+months?\ ago$ ]]; then
        echo "${BASH_REMATCH[1]}m ago"
        return 0
    fi
    if [[ $value =~ ^([0-9]+)[[:space:]]+month\(s\)\ ago$ ]]; then
        echo "${BASH_REMATCH[1]}m ago"
        return 0
    fi
    if [[ $value =~ ^([0-9]+)[[:space:]]+years?\ ago$ ]]; then
        echo "${BASH_REMATCH[1]}y ago"
        return 0
    fi
    echo "$value"
}
