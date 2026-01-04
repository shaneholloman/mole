# Mole AI Agent Guide

Quick reference for AI assistants working on Mole (Mac system cleaner).
**Last updated**: 2026-01-04

## Safety Checklist

Before any operation:

- Use `safe_*` helpers (never raw `rm -rf` or `find -delete`)
- Check protection: `is_protected()`, `is_whitelisted()`
- Test first: `MO_DRY_RUN=1 ./mole clean`
- Validate syntax: `bash -n <file>`
- Run tests: `./scripts/test.sh`

## Never Do

- Raw deletions without `safe_*` helpers
- Remove `--prefix`/`--config` flags from install.sh
- Commit code unless explicitly requested
- Mix languages: Python in shell, shell in Go
- Delete without checking protection lists

## Architecture Quick Map

```
mole                   # CLI entrypoint (menu + routing)
├── bin/              # Commands: clean, uninstall, optimize, analyze, status
├── lib/              # Shell logic: core/, clean/, ui/
├── cmd/              # Go apps: analyze/, status/
├── tests/            # BATS integration tests
└── scripts/          # Build and test automation
```

**Decision Tree**:

- User cleanup logic → `lib/clean/<module>.sh`
- Command entry → `bin/<command>.sh`
- Core utils → `lib/core/<util>.sh`
- Performance tool → `cmd/<tool>/*.go`
- Tests → `tests/<test>.bats`

## Common Commands

```bash
# Validation (run before suggesting changes)
bash -n <file>                    # Syntax check
./scripts/test.sh                 # Full test suite
MO_DRY_RUN=1 ./mole clean         # Safe dry-run test

# Development
make build                        # Build Go binaries
go run ./cmd/analyze              # Test without building
bats tests/clean.bats -f "name"   # Specific test

# Debugging
MO_DEBUG=1 ./mole clean           # Verbose output
```

## Code Style Rules

**Shell** (Bash 3.2 compatible):

- 2-space indent, quote variables: `"$var"`
- Use `[[` not `[`, prefer `$(cmd)` over backticks
- Comments: English, intent-focused, for safety boundaries only
- Entry scripts: 2-3 line header describing purpose

**Go**:

- Standard conventions: `gofmt`, `go vet`
- Never ignore errors

## Key Helpers

- `safe_rm <path>` - Protected deletion
- `safe_find_delete <base> <pattern> <days> <type>` - Safe find+delete
- `is_protected <path>` - Check system protection
- `is_whitelisted <name>` - Check user whitelist
- `log_info/success/warn/error <msg>` - Logging

## Workflow

1. **Read first**: Never propose changes to unread code
2. **Shell work**: Logic in `lib/`, called from `bin/`
3. **Go work**: Edit `cmd/<app>/*.go`
4. **Test**: Dry-run → BATS → full test suite
5. **Style**: Match existing file conventions (Bash 3.2)

## Example: Add New Cleanup

```bash
# 1. Create lib/clean/my_module.sh
clean_my_cache() {
  local dir="$HOME/Library/Caches/MyApp"
  [[ -d "$dir" ]] && ! is_whitelisted "my_app" || return
  safe_find_delete "$dir" "*" "30" "f"
  log_success "Cleaned MyApp cache"
}

# 2. Call from bin/clean.sh
source "${LIB_DIR}/clean/my_module.sh"
clean_my_cache

# 3. Test
bats tests/clean.bats -f "my_cache"
```

## Troubleshooting

- Tests fail → `bats tests/<file>.bats -f "test name"`
- Syntax error → `bash -n <file>`
- Permission denied → `./mole touchid`
- Cleanup not working → Check `is_protected()` or `~/.config/mole/whitelist`
