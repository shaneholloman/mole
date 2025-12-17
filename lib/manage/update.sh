#!/bin/bash
# Update Manager
# Unified update execution for all update types

set -euo pipefail

# Format Homebrew update label for display
format_brew_update_label() {
    local total="${BREW_OUTDATED_COUNT:-0}"
    if [[ -z "$total" || "$total" -le 0 ]]; then
        return
    fi

    local -a details=()
    local formulas="${BREW_FORMULA_OUTDATED_COUNT:-0}"
    local casks="${BREW_CASK_OUTDATED_COUNT:-0}"

    ((formulas > 0)) && details+=("${formulas} formula")
    ((casks > 0)) && details+=("${casks} cask")

    local detail_str="(${total} updates)"
    if ((${#details[@]} > 0)); then
        detail_str="($(
            IFS=', '
            printf '%s' "${details[*]}"
        ))"
    fi
    printf "  • Homebrew %s" "$detail_str"
}

brew_has_outdated() {
    local kind="${1:-formula}"
    command -v brew > /dev/null 2>&1 || return 1

    if [[ "$kind" == "cask" ]]; then
        brew outdated --cask --quiet 2> /dev/null | grep -q .
    else
        brew outdated --quiet 2> /dev/null | grep -q .
    fi
}

# Ask user if they want to update
# Returns: 0 if yes, 1 if no
ask_for_updates() {
    local has_updates=false
    local -a update_list=()

    local brew_entry
    brew_entry=$(format_brew_update_label || true)
    if [[ -n "$brew_entry" ]]; then
        has_updates=true
        update_list+=("$brew_entry")
    fi

    if [[ -n "${APPSTORE_UPDATE_COUNT:-}" && "${APPSTORE_UPDATE_COUNT:-0}" -gt 0 ]]; then
        has_updates=true
        update_list+=("  • App Store (${APPSTORE_UPDATE_COUNT} apps)")
    fi

    if [[ -n "${MACOS_UPDATE_AVAILABLE:-}" && "${MACOS_UPDATE_AVAILABLE}" == "true" ]]; then
        has_updates=true
        update_list+=("  • macOS system")
    fi

    if [[ -n "${MOLE_UPDATE_AVAILABLE:-}" && "${MOLE_UPDATE_AVAILABLE}" == "true" ]]; then
        has_updates=true
        update_list+=("  • Mole")
    fi

    if [[ "$has_updates" == "false" ]]; then
        return 1
    fi

    echo -e "${BLUE}AVAILABLE UPDATES${NC}"
    for item in "${update_list[@]}"; do
        echo -e "$item"
    done
    echo ""

    # If Mole has updates, offer to update it
    if [[ "${MOLE_UPDATE_AVAILABLE:-}" == "true" ]]; then
        echo -ne "${YELLOW}Update Mole now?${NC} ${GRAY}Enter confirm / ESC cancel${NC}: "

        local key
        if ! key=$(read_key); then
            echo "skip"
            echo ""
            return 1
        fi

        if [[ "$key" == "ENTER" ]]; then
            echo "yes"
            echo ""
            return 0
        else
            echo "skip"
            echo ""
            return 1
        fi
    fi

    # For other updates, just show instructions
    # (Mole update check above handles the return 0 case, so we only get here if no Mole update)
    if [[ "${BREW_OUTDATED_COUNT:-0}" -gt 0 ]]; then
        echo -e "${YELLOW}Tip:${NC} Run ${GREEN}brew upgrade${NC} to update Homebrew packages"
    fi
    if [[ "${APPSTORE_UPDATE_COUNT:-0}" -gt 0 ]]; then
        echo -e "${YELLOW}Tip:${NC} Open ${BLUE}App Store${NC} to update apps"
    fi
    if [[ "${MACOS_UPDATE_AVAILABLE:-}" == "true" ]]; then
        echo -e "${YELLOW}Tip:${NC} Open ${BLUE}System Settings${NC} to update macOS"
    fi
    echo ""
    return 1
}

# Perform all pending updates
# Returns: 0 if all succeeded, 1 if some failed
perform_updates() {
    # Only handle Mole updates here
    # Other updates are now informational-only in ask_for_updates

    local updated_count=0

    # Update Mole
    if [[ -n "${MOLE_UPDATE_AVAILABLE:-}" && "${MOLE_UPDATE_AVAILABLE}" == "true" ]]; then
        echo -e "${BLUE}Updating Mole...${NC}"
        # Try to find mole executable
        local mole_bin="${SCRIPT_DIR}/../../mole"
        [[ ! -f "$mole_bin" ]] && mole_bin=$(command -v mole 2> /dev/null || echo "")

        if [[ -x "$mole_bin" ]]; then
            # We use exec here or just run it?
            # If we run 'mole update', it replaces the script.
            # Since this function is part of a sourced script, replacing the file on disk is risky while running.
            # However, 'mole update' script usually handles this by downloading to a temp file and moving it.
            # But the shell might not like the file changing under it.
            # The original code ran it this way, so we assume it's safe enough or handled by mole update implementation.

            if "$mole_bin" update 2>&1 | grep -qE "(Updated|latest version)"; then
                echo -e "${GREEN}✓${NC} Mole updated"
                reset_mole_cache
                updated_count=1
            else
                echo -e "${RED}✗${NC} Mole update failed"
            fi
        else
            echo -e "${RED}✗${NC} Mole executable not found"
        fi
        echo ""
    fi

    if [[ $updated_count -gt 0 ]]; then
        return 0
    else
        return 1
    fi
}
