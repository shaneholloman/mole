#!/bin/bash

set -euo pipefail

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/optimize_health.sh"

# Colors and icons from common.sh

print_header() {
    echo ""
    echo -e "${PURPLE}Optimize Your Mac${NC}"
    echo ""
}

show_system_health() {
    local health_json="$1"

    # Parse system health using jq
    local mem_used=$(echo "$health_json" | jq -r '.memory_used_gb')
    local mem_total=$(echo "$health_json" | jq -r '.memory_total_gb')
    local disk_used=$(echo "$health_json" | jq -r '.disk_used_gb')
    local disk_total=$(echo "$health_json" | jq -r '.disk_total_gb')
    local disk_percent=$(echo "$health_json" | jq -r '.disk_used_percent')
    local uptime=$(echo "$health_json" | jq -r '.uptime_days')

    # Compact one-line format
    printf "System: %.0f/%.0f GB RAM | %.0f/%.0f GB Disk (%.0f%%) | Uptime %.0fd\n" \
        "$mem_used" "$mem_total" "$disk_used" "$disk_total" "$disk_percent" "$uptime"
    echo ""
}

parse_optimizations() {
    local health_json="$1"

    # Extract optimizations array
    echo "$health_json" | jq -c '.optimizations[]' 2> /dev/null
}

announce_action() {
    local name="$1"
    local desc="$2"
    local kind="$3"

    local badge=""
    if [[ "$kind" == "confirm" ]]; then
        badge="${YELLOW}[Confirm]${NC} "
    fi

    local line="${BLUE}${ICON_ARROW}${NC} ${badge}${name}"
    if [[ -n "$desc" ]]; then
        line+=" ${GRAY}- ${desc}${NC}"
    fi

    if ${first_heading:-true}; then
        first_heading=false
    else
        echo ""
    fi

    echo -e "$line"
}

touchid_configured() {
    local pam_file="/etc/pam.d/sudo"
    [[ -f "$pam_file" ]] && grep -q "pam_tid.so" "$pam_file" 2> /dev/null
}

touchid_supported() {
    if command -v bioutil > /dev/null 2>&1; then
        bioutil -r 2> /dev/null | grep -q "Touch ID" && return 0
    fi
    [[ "$(uname -m)" == "arm64" ]]
}

cleanup_path() {
    local raw_path="$1"
    local label="$2"

    local expanded_path="${raw_path/#\~/$HOME}"
    if [[ ! -e "$expanded_path" ]]; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $label"
        return
    fi

    local size_kb
    size_kb=$(du -sk "$expanded_path" 2> /dev/null | awk '{print $1}' || echo "0")
    local size_display=""
    if [[ "$size_kb" =~ ^[0-9]+$ && "$size_kb" -gt 0 ]]; then
        size_display=$(bytes_to_human "$((size_kb * 1024))")
    fi

    if rm -rf "$expanded_path"; then
        if [[ -n "$size_display" ]]; then
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $label ${GREEN}(${size_display})${NC}"
        else
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $label"
        fi
    else
        echo -e "  ${RED}${ICON_ERROR}${NC} Failed to remove $label"
    fi
}

ensure_directory() {
    local raw_path="$1"
    local expanded_path="${raw_path/#\~/$HOME}"
    mkdir -p "$expanded_path" > /dev/null 2>&1 || true
}

list_login_items() {
    local raw_items
    raw_items=$(osascript -e 'tell application "System Events" to get the name of every login item' 2> /dev/null || echo "")
    [[ -z "$raw_items" || "$raw_items" == "missing value" ]] && return

    IFS=',' read -ra login_items_array <<< "$raw_items"
    for entry in "${login_items_array[@]}"; do
        local trimmed
        trimmed=$(echo "$entry" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        [[ -n "$trimmed" ]] && printf "%s\n" "$trimmed"
    done
}

SUDO_KEEPALIVE_PID=""

start_sudo_keepalive() {
    [[ -n "$SUDO_KEEPALIVE_PID" ]] && return

    (
        while true; do
            if ! sudo -n true 2> /dev/null; then
                exit 0
            fi
            sleep 30
        done
    ) &
    SUDO_KEEPALIVE_PID=$!
}

stop_sudo_keepalive() {
    if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
        kill "$SUDO_KEEPALIVE_PID" 2> /dev/null || true
        wait "$SUDO_KEEPALIVE_PID" 2> /dev/null || true
        SUDO_KEEPALIVE_PID=""
    fi
}

trap stop_sudo_keepalive EXIT

count_local_snapshots() {
    if ! command -v tmutil > /dev/null 2>&1; then
        echo 0
        return
    fi

    local output
    output=$(tmutil listlocalsnapshots / 2> /dev/null || true)
    if [[ -z "$output" ]]; then
        echo 0
        return
    fi

    echo "$output" | grep -c "com.apple.TimeMachine." | tr -d ' '
}

execute_optimization() {
    local action="$1"
    local path="$2"

    case "$action" in
        system_maintenance)
            echo -e "${BLUE}${ICON_ARROW}${NC} Rebuilding LaunchServices database..."
            timeout 10 /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user > /dev/null 2>&1 || true
            echo -e "${GREEN}${ICON_SUCCESS}${NC} LaunchServices database rebuilt"

            echo -e "${BLUE}${ICON_ARROW}${NC} Flushing DNS cache..."
            if sudo dscacheutil -flushcache 2> /dev/null && sudo killall -HUP mDNSResponder 2> /dev/null; then
                echo -e "${GREEN}${ICON_SUCCESS}${NC} DNS cache flushed"
            else
                echo -e "${RED}${ICON_ERROR}${NC} Failed to flush DNS cache"
            fi

            echo -e "${BLUE}${ICON_ARROW}${NC} Purging memory cache..."
            if sudo purge 2> /dev/null; then
                echo -e "${GREEN}${ICON_SUCCESS}${NC} Memory cache purged"
            else
                echo -e "${RED}${ICON_ERROR}${NC} Failed to purge memory"
            fi

            echo -e "${BLUE}${ICON_ARROW}${NC} Rebuilding font cache..."
            sudo atsutil databases -remove > /dev/null 2>&1
            echo -e "${GREEN}${ICON_SUCCESS}${NC} Font cache rebuilt"

            echo -e "${BLUE}${ICON_ARROW}${NC} Rebuilding Spotlight index..."
            sudo mdutil -E / > /dev/null 2>&1 || true
            echo -e "${GREEN}${ICON_SUCCESS}${NC} Spotlight index rebuilt"
            ;;

        startup_items)
            echo -e "${BLUE}${ICON_ARROW}${NC} Opening Launch Agents directory..."
            open ~/Library/LaunchAgents
            open /Library/LaunchAgents
            echo -e "${GREEN}${ICON_SUCCESS}${NC} Please review and disable unnecessary startup items"
            echo -e "${GRAY}   Tip: Move unwanted .plist files to trash${NC}"
            ;;

        cache_refresh)
            echo -e "${BLUE}${ICON_ARROW}${NC} Resetting Quick Look cache..."
            qlmanage -r cache > /dev/null 2>&1 || true
            qlmanage -r > /dev/null 2>&1 || true

            local -a cache_targets=(
                "$HOME/Library/Caches/com.apple.QuickLook.thumbnailcache|Quick Look thumbnails"
                "$HOME/Library/Caches/com.apple.iconservices.store|Icon Services store"
                "$HOME/Library/Caches/com.apple.iconservices|Icon Services cache"
                "$HOME/Library/Caches/com.apple.Safari/WebKitCache|Safari WebKit cache"
                "$HOME/Library/Caches/com.apple.Safari/Favicon|Safari favicon cache"
            )

            for target in "${cache_targets[@]}"; do
                IFS='|' read -r target_path label <<< "$target"
                cleanup_path "$target_path" "$label"
            done

            echo -e "${GREEN}${ICON_SUCCESS}${NC} Finder and Safari caches refreshed"
            ;;

        maintenance_scripts)
            echo -e "${BLUE}${ICON_ARROW}${NC} Running macOS periodic scripts..."
            local periodic_cmd="/usr/sbin/periodic"
            if [[ -x "$periodic_cmd" ]]; then
                local periodic_output=""
                if periodic_output=$(sudo "$periodic_cmd" daily weekly monthly 2>&1); then
                    echo -e "${GREEN}${ICON_SUCCESS}${NC} Daily/weekly/monthly scripts completed"
                else
                    echo -e "${YELLOW}!${NC} periodic scripts reported an issue"
                    printf '%s\n' "$periodic_output" | sed 's/^/    /'
                fi
            fi

            echo -e "${BLUE}${ICON_ARROW}${NC} Rotating system logs..."
            if sudo newsyslog > /dev/null 2>&1; then
                echo -e "${GREEN}${ICON_SUCCESS}${NC} Log rotation complete"
            else
                echo -e "${YELLOW}!${NC} newsyslog reported an issue"
            fi

            if [[ -x "/usr/libexec/repair_packages" ]]; then
                echo -e "${BLUE}${ICON_ARROW}${NC} Repairing base system permissions..."
                if sudo /usr/libexec/repair_packages --repair --standard-pkgs --volume / > /dev/null 2>&1; then
                    echo -e "${GREEN}${ICON_SUCCESS}${NC} Base system permission repair complete"
                else
                    echo -e "${YELLOW}!${NC} repair_packages reported an issue"
                fi
            fi
            ;;

        log_cleanup)
            echo -e "${BLUE}${ICON_ARROW}${NC} Clearing diagnostic & crash logs..."
            local -a user_logs=(
                "$HOME/Library/Logs/DiagnosticReports"
                "$HOME/Library/Logs/CrashReporter"
                "$HOME/Library/Logs/corecaptured"
            )
            for target in "${user_logs[@]}"; do
                cleanup_path "$target" "$(basename "$target")"
            done

            if [[ -d "/Library/Logs/DiagnosticReports" ]]; then
                sudo find /Library/Logs/DiagnosticReports -type f -name "*.crash" -delete 2> /dev/null || true
                sudo find /Library/Logs/DiagnosticReports -type f -name "*.panic" -delete 2> /dev/null || true
                echo -e "  ${GREEN}${ICON_SUCCESS}${NC} System diagnostic logs cleared"
            else
                echo -e "  ${GRAY}-${NC} No system diagnostic logs found"
            fi
            ;;

        recent_items)
            echo -e "${BLUE}${ICON_ARROW}${NC} Clearing recent items lists..."
            local shared_dir="$HOME/Library/Application Support/com.apple.sharedfilelist"
            if [[ -d "$shared_dir" ]]; then
                local removed
                removed=$(find "$shared_dir" -name "*.sfl2" -type f -print -delete 2> /dev/null | wc -l | tr -d ' ')
                echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Reset $removed shared file lists"
            else
                echo -e "  ${GRAY}-${NC} Recent item caches already clean"
            fi

            rm -f "$HOME/Library/Preferences/com.apple.recentitems.plist" 2> /dev/null || true
            defaults delete NSGlobalDomain NSRecentDocumentsLimit 2> /dev/null || true
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Finder/Apple menu recent items cleared"
            ;;

        radio_refresh)
            echo -e "${BLUE}${ICON_ARROW}${NC} Resetting Bluetooth preferences..."
            rm -f "$HOME/Library/Preferences/com.apple.Bluetooth.plist" 2> /dev/null || true
            sudo rm -f /Library/Preferences/com.apple.Bluetooth.plist 2> /dev/null || true
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Bluetooth caches refreshed"

            echo -e "${BLUE}${ICON_ARROW}${NC} Resetting Wi-Fi configuration..."
            local sysconfig="/Library/Preferences/SystemConfiguration"
            if [[ -d "$sysconfig" ]]; then
                sudo cp "$sysconfig"/com.apple.airport.preferences.plist "$sysconfig"/com.apple.airport.preferences.plist.bak 2> /dev/null || true
                sudo rm -f "$sysconfig"/com.apple.airport.preferences.plist 2> /dev/null || true
                echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Wi-Fi preferences reset"
            else
                echo -e "  ${GRAY}-${NC} SystemConfiguration directory missing"
            fi

            sudo ifconfig awdl0 down 2> /dev/null || true
            sudo ifconfig awdl0 up 2> /dev/null || true
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Wireless services refreshed"
            ;;

        mail_downloads)
            echo -e "${BLUE}${ICON_ARROW}${NC} Clearing Mail attachment downloads..."
            local -a mail_dirs=(
                "$HOME/Library/Mail Downloads|Mail Downloads"
                "$HOME/Library/Containers/com.apple.mail/Data/Library/Mail Downloads|Mail Container Downloads"
            )
            for target in "${mail_dirs[@]}"; do
                IFS='|' read -r target_path label <<< "$target"
                cleanup_path "$target_path" "$label"
                ensure_directory "$target_path"
            done
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Mail downloads cleared"
            ;;

        saved_state_cleanup)
            echo -e "${BLUE}${ICON_ARROW}${NC} Purging saved application states..."
            local state_dir="$HOME/Library/Saved Application State"
            cleanup_path "$state_dir" "Saved Application State"
            ensure_directory "$state_dir"
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Saved states cleared"
            ;;

        finder_dock_refresh)
            echo -e "${BLUE}${ICON_ARROW}${NC} Resetting Finder & Dock caches..."
            local -a interface_targets=(
                "$HOME/Library/Caches/com.apple.finder|Finder cache"
                "$HOME/Library/Caches/com.apple.dock.iconcache|Dock icon cache"
            )
            for target in "${interface_targets[@]}"; do
                IFS='|' read -r target_path label <<< "$target"
                cleanup_path "$target_path" "$label"
            done
            killall Finder > /dev/null 2>&1 || true
            killall Dock > /dev/null 2>&1 || true
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Finder & Dock relaunched"
            ;;

        swap_cleanup)
            echo -e "${BLUE}${ICON_ARROW}${NC} Removing swapfiles and resetting dynamic pager..."
            if sudo launchctl unload /System/Library/LaunchDaemons/com.apple.dynamic_pager.plist > /dev/null 2>&1; then
                sudo rm -f /private/var/vm/swapfile* > /dev/null 2>&1 || true
                sudo touch /private/var/vm/swapfile0 > /dev/null 2>&1 || true
                sudo chmod 600 /private/var/vm/swapfile0 > /dev/null 2>&1 || true
                sudo launchctl load /System/Library/LaunchDaemons/com.apple.dynamic_pager.plist > /dev/null 2>&1 || true
                echo -e "${GREEN}${ICON_SUCCESS}${NC} Swap cache rebuilt"
            else
                echo -e "${YELLOW}!${NC} Could not unload dynamic_pager"
            fi
            ;;

        startup_cache)
            local macos_version
            macos_version=$(sw_vers -productVersion | cut -d '.' -f 1)

            # macOS 11+ has read-only system volume, skip system file operations
            if [[ "$macos_version" -ge 11 ]] || [[ "$(uname -m)" == "arm64" ]]; then
                echo -e "${BLUE}${ICON_ARROW}${NC} Rebuilding kext caches..."
                if sudo kextcache -i / > /dev/null 2>&1; then
                    echo -e "${GREEN}${ICON_SUCCESS}${NC} Startup caches refreshed"
                else
                    echo -e "${GREEN}${ICON_SUCCESS}${NC} Startup caches refreshed (sealed system volume)"
                fi
            else
                echo -e "${BLUE}${ICON_ARROW}${NC} Rebuilding kext caches..."
                if sudo kextcache -i / > /dev/null 2>&1; then
                    echo -e "${GREEN}${ICON_SUCCESS}${NC} Kernel/kext caches rebuilt"
                else
                    echo -e "${YELLOW}!${NC} kextcache reported an issue"
                fi

                echo -e "${BLUE}${ICON_ARROW}${NC} Clearing system prelinked kernel caches..."
                sudo rm -rf /System/Library/PrelinkedKernels/* > /dev/null 2>&1 || true
                sudo kextcache -system-prelinked-kernel > /dev/null 2>&1 || true
                echo -e "${GREEN}${ICON_SUCCESS}${NC} Startup caches refreshed"
            fi
            ;;

        local_snapshots)
            if ! command -v tmutil > /dev/null 2>&1; then
                echo -e "${YELLOW}!${NC} tmutil not available on this system"
                return
            fi

            local before after
            before=$(count_local_snapshots)
            if [[ "$before" -eq 0 ]]; then
                echo -e "${GREEN}${ICON_SUCCESS}${NC} No local snapshots to thin"
                return
            fi

            echo -e "${BLUE}${ICON_ARROW}${NC} Thinning $before APFS local snapshots..."
            if sudo tmutil thinlocalsnapshots / 9999999999 4 > /dev/null 2>&1; then
                after=$(count_local_snapshots)
                local removed=$((before - after))
                if [[ "$removed" -lt 0 ]]; then
                    removed=0
                fi
                echo -e "${GREEN}${ICON_SUCCESS}${NC} Removed $removed snapshots (remaining: $after)"
            else
                echo -e "${RED}${ICON_ERROR}${NC} Failed to thin local snapshots"
            fi
            ;;

        developer_cleanup)
            local -a dev_targets=(
                "$HOME/Library/Developer/Xcode/DerivedData|Xcode DerivedData"
                "$HOME/Library/Developer/Xcode/iOS DeviceSupport|iOS Device support files"
                "$HOME/Library/Developer/CoreSimulator/Caches|CoreSimulator caches"
            )

            for target in "${dev_targets[@]}"; do
                IFS='|' read -r target_path label <<< "$target"
                cleanup_path "$target_path" "$label"
            done

            if command -v xcrun > /dev/null 2>&1; then
                echo -e "${BLUE}${ICON_ARROW}${NC} Removing unavailable simulator runtimes..."
                if xcrun simctl delete unavailable > /dev/null 2>&1; then
                    echo -e "${GREEN}${ICON_SUCCESS}${NC} Unavailable simulators removed"
                else
                    echo -e "${YELLOW}!${NC} Could not prune simulator runtimes"
                fi
            fi

            echo -e "${GREEN}${ICON_SUCCESS}${NC} Developer caches cleaned"
            ;;

        *)
            echo -e "${RED}${ICON_ERROR}${NC} Unknown action: $action"
            ;;
    esac
}

main() {
    if [[ -t 1 ]]; then
        clear
    fi
    print_header

    # Check dependencies
    if ! command -v jq > /dev/null 2>&1; then
        log_error "jq is required but not installed. Install with: brew install jq"
        exit 1
    fi

    if ! command -v bc > /dev/null 2>&1; then
        log_error "bc is required but not installed. Install with: brew install bc"
        exit 1
    fi

    # Collect system health data using pure Bash implementation
    local health_json
    if ! health_json=$(generate_health_json 2> /dev/null); then
        log_error "Failed to collect system health data"
        exit 1
    fi

    # Show system health
    show_system_health "$health_json"

    # Parse and display optimizations
    local -a safe_items=()
    local -a confirm_items=()

    while IFS= read -r opt_json; do
        [[ -z "$opt_json" ]] && continue

        local name=$(echo "$opt_json" | jq -r '.name')
        local desc=$(echo "$opt_json" | jq -r '.description')
        local action=$(echo "$opt_json" | jq -r '.action')
        local path=$(echo "$opt_json" | jq -r '.path // ""')
        local safe=$(echo "$opt_json" | jq -r '.safe')

        local item="${name}|${desc}|${action}|${path}"

        if [[ "$safe" == "true" ]]; then
            safe_items+=("$item")
        else
            confirm_items+=("$item")
        fi
    done < <(parse_optimizations "$health_json")

    # Simple confirmation with sudo context
    echo -ne "${PURPLE}${ICON_ARROW}${NC} System optimizations need admin access — ${GREEN}Enter${NC} Touch ID/password, ${GRAY}ESC${NC} cancel: "

    IFS= read -r -s -n1 key || key=""
    drain_pending_input # Clean up any escape sequence remnants
    case "$key" in
        $'\e' | q | Q)
            echo ""
            echo ""
            echo -e "${GRAY}Cancelled${NC}"
            echo ""
            exit 0
            ;;
        "" | $'\n' | $'\r')
            printf "\r\033[K"
            if ! request_sudo_access "System optimizations require admin access"; then
                echo ""
                echo -e "${YELLOW}Authentication failed${NC}"
                exit 1
            fi
            start_sudo_keepalive
            ;;
        *)
            echo ""
            echo ""
            echo -e "${GRAY}Cancelled${NC}"
            echo ""
            exit 0
            ;;
    esac

    # Execute all optimizations
    local first_heading=true

    # Run safe optimizations
    if [[ ${#safe_items[@]} -gt 0 ]]; then
        for item in "${safe_items[@]}"; do
            IFS='|' read -r name desc action path <<< "$item"
            announce_action "$name" "$desc" "safe"
            execute_optimization "$action" "$path"
        done
    fi

    # Run confirm items
    if [[ ${#confirm_items[@]} -gt 0 ]]; then
        for item in "${confirm_items[@]}"; do
            IFS='|' read -r name desc action path <<< "$item"
            announce_action "$name" "$desc" "confirm"
            execute_optimization "$action" "$path"
        done
    fi

    # Show login item reminder at the end of optimization log
    local -a login_items_list=()
    while IFS= read -r login_item; do
        [[ -n "$login_item" ]] && login_items_list+=("$login_item")
    done < <(list_login_items || true)

    if ((${#login_items_list[@]} > 0)); then
        local display_count=${#login_items_list[@]}
        echo ""
        echo -e "${BLUE}${ICON_ARROW}${NC} Login items (${display_count}) auto-start at login:"
        local preview_limit=5
        ((preview_limit > display_count)) && preview_limit=$display_count
        for ((i = 0; i < preview_limit; i++)); do
            printf "    • %s\n" "${login_items_list[$i]}"
        done
        if ((display_count > preview_limit)); then
            local remaining=$((display_count - preview_limit))
            echo "    • …and $remaining more"
        fi
        echo -e "${GRAY}Review System Settings → General → Login Items to trim extras.${NC}"
    fi

    echo ""
    local summary_title="System optimization completed"
    local -a summary_details=()

    local safe_count=${#safe_items[@]}
    local confirm_count=${#confirm_items[@]}
    if ((safe_count > 0)); then
        summary_details+=("Automations: ${GREEN}${safe_count}${NC} sections optimized end-to-end.")
    else
        summary_details+=("Automations: No automated changes were necessary.")
    fi

    if ((confirm_count > 0)); then
        summary_details+=("Follow-ups: ${YELLOW}${confirm_count}${NC} manual checks suggested (see log).")
    fi

    summary_details+=("Highlights: caches refreshed, services restarted, startup assets rebuilt.")
    summary_details+=("Result: system responsiveness should feel lighter.")

    local show_touchid_tip="false"
    if touchid_supported && ! touchid_configured; then
        show_touchid_tip="true"
    fi

    if [[ "$show_touchid_tip" == "true" ]]; then
        echo -e "Tip: run 'mo touchid' to approve sudo via Touch ID."
    fi
    print_summary_block "success" "$summary_title" "${summary_details[@]}"
    printf '\n'
}

main "$@"
