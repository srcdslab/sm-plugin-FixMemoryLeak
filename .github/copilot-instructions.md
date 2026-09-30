# FixMemoryLeak - SourceMod Plugin Development Guidelines

## Repository Overview

This repository contains the **FixMemoryLeak** SourceMod plugin, designed to prevent server crashes by implementing automatic server restarts at configured intervals. The plugin addresses memory leak issues in Source engine game servers by providing intelligent restart scheduling with player-count awareness and multi-language support.

### Key Features
- Configurable restart modes (delay-based, scheduled times, or hybrid)
- Player count-based restart postponement 
- Early restart when server is empty
- Multi-language support (English, Chinese, French, Russian)
- Post-restart command execution
- Integration with MapChooser Extended
- Restart-loop circuit breakers (`sm_restart_min_uptime`, `sm_restart_cooldown`): the plugin can
  never fire two automatic restarts closer together than the cooldown, regardless of what the
  scheduling/persisted state says - this is what guarantees it can't restart on every map change.
- Live countdown warnings that always show the actual remaining time ("restart in 23 minutes",
  then 22, 21, ...) instead of snapping to fixed checkpoints. Spacing is just a minimum interval:
  a long one (`sm_restart_warn_interval`) while far from the restart so it doesn't fire on every
  map, and a short one (`sm_restart_warn_close_interval`) once inside `sm_restart_warn_close`
  minutes so it effectively fires on every map.
- Config file is self-healing: a missing or corrupted `configs/fixmemoryleak.cfg` is backed up
  (`.corrupt-<timestamp>`) and regenerated with safe defaults, and all writes are atomic
  (temp file + re-parse validation + rename) to survive a crash mid-write.
- `sm_restart_selftest` runs a battery of assertions on the pure scheduling/safety functions with
  synthetic inputs (no need to wait for a real restart to verify the logic).

## Technical Environment

- **Language**: SourcePawn (`.sp` files)
- **Platform**: SourceMod 1.12 (builds against 1.12.0-git7165)
- **Build System**: Native GitHub Actions workflow (`.github/workflows/ci.yml`) using `rumblefrog/setup-sp` and `spcomp`
- **Dependencies**: 
  - SourceMod core
  - MultiColors (chat colors)
  - MapChooser Extended (optional, for nextmap integration)
- **Output**: Compiled `.smx` plugin files

## Build System

### Using GitHub Actions (CI)
This project builds via a native GitHub Actions workflow that installs `spcomp` (via `rumblefrog/setup-sp`), clones the git-based dependencies (MultiColors, MapChooser Extended) into a local `include` folder, and compiles the plugin. See `.github/workflows/ci.yml` for the exact steps.

### Manual Compilation
You can compile locally with spcomp once the dependency includes are in place:
```bash
# Fetch dependency includes into addons/sourcemod/scripting/include (see ci.yml "Install dependencies" step)
# Then compile:
cd addons/sourcemod/scripting
spcomp -i include -o ../plugins/FixMemoryLeak.smx FixMemoryLeak.sp
```

## Project Structure

```
.
├── addons/sourcemod/
│   ├── scripting/
│   │   └── FixMemoryLeak.sp          # Main plugin source
│   └── translations/
│       └── FixMemoryLeak.phrases.txt # Translation strings
├── .github/
│   └── workflows/
│       └── ci.yml                    # Automated build and release
└── .gitignore                       # Excludes build artifacts
```

## Code Style & Standards

### SourcePawn Conventions
- Use `#pragma semicolon 1` and `#pragma newdecls required`
- Indentation: 4 spaces (configured as tabs in editor)
- Variables: `camelCase` for locals, `PascalCase` for functions
- Global variables: Prefix with `g_` (e.g., `g_cRestartMode`)
- Constants: Use `#define` for configuration paths and keys

### Memory Management
- **Critical**: Use `delete` for Handle cleanup, never check for null first
- **Never** use `.Clear()` on StringMap/ArrayList - causes memory leaks
- Always use `delete` and recreate containers instead of clearing
- Use methodmap for modern SourcePawn APIs

### Example Patterns
```sourcepawn
// ✅ Correct memory management
if (g_iConfiguredRestarts != null)
    delete g_iConfiguredRestarts;
g_iConfiguredRestarts = new ArrayList(sizeof(ConfiguredRestart));

// ❌ Wrong - creates memory leak
g_iConfiguredRestarts.Clear();

// ✅ Correct Handle deletion
delete kv;  // No null check needed

// ✅ Modern ConVar usage
g_cRestartMode = CreateConVar("sm_restart_mode", "2", "Description...");
g_iMode = g_cRestartMode.IntValue;
```

## Configuration System

The plugin uses KeyValues configuration files stored in `configs/fixmemoryleak.cfg`:

### Configuration Structure
```
"server"
{
    "commands"      // Post-restart commands to execute
    {
        "cmd"   "sm exts load CSSFixes"
        "cmd"   "sm plugins reload adminmenu"
    }
    
    "info"          // Runtime state tracking - plugin-owned, only ever written via
                    // WriteRuntimeState() (atomic: temp file + reimport + rename)
    {
        "nextrestart"   "timestamp"
        "nextmap"       "mapname"
        "restarted"     "0/1"
        "changed"       "0/1"
        "lastrestart"   "timestamp"  // last actual restart, used by sm_restart_cooldown
    }
    
    "restart"       // Scheduled restart times
    {
        "0"
        {
            "day"       "1"     // ISO-8601 weekday: 1=Monday .. 7=Sunday (matches FormatTime's %u)
            "hour"      "6"     // 24-hour format, 0-23
            "minute"    "0"     // 0-59
        }
    }
}
```

Reads of `info` are served from an in-memory cache (`g_iNextRestartTime`, `g_sNextRestartMap`,
`g_bStateRestarted`, `g_bStateChanged`, `g_iLastRestartTime`), loaded once via
`LoadRuntimeState()` per map start - never re-read from disk on every check. `commands` and
`restart` stay admin-authored and are only read, never written by the plugin.

### Anti restart-loop safety nets

Two independent, mode-agnostic checks guarantee the plugin can never restart the server on every
map change, even if the schedule/persisted state is wrong:

- `sm_restart_min_uptime` (minutes): `GetNextRestartTime()` always clamps its result to at least
  `now + min_uptime`, so a stale/misconfigured schedule can never compute "restart immediately".
- `sm_restart_cooldown` (minutes): `IsRestartNeeded()` refuses to fire if less than `cooldown`
  minutes have passed since `lastrestart`, regardless of what the scheduling math says.

Both are pure functions (`ClampToMinUptime`, `IsCooldownActive`) covered by `sm_restart_selftest`.

## Translation System

All user-facing messages use translation files. Key principles:

- Store all strings in `FixMemoryLeak.phrases.txt`
- Use `%t` format in chat functions: `CPrintToChat(client, "%t %t", "Prefix", "Message")`
- Support multiple languages (currently EN, ZH, CHI, FR, RU)
- Use proper formatting tokens: `#format "{1:i},{2:s}"`

## Development Workflow

### 1. Making Changes
- Modify `.sp` files in `addons/sourcemod/scripting/`
- Update translations in `addons/sourcemod/translations/` if adding user messages
- Test locally on a SourceMod development server

### 2. Building & Testing
```bash
# Build via CI (push/PR/workflow_dispatch triggers .github/workflows/ci.yml),
# or compile locally as described above.

# Copy to test server
cp addons/sourcemod/plugins/FixMemoryLeak.smx /path/to/server/addons/sourcemod/plugins/

# Test plugin loading
sm plugins load FixMemoryLeak
```

### 3. Validation Checklist
- [ ] Plugin compiles without warnings
- [ ] No memory leaks (use proper delete patterns)
- [ ] All ConVars have proper bounds and descriptions
- [ ] Error handling for all API calls
- [ ] Translation strings for user-facing messages
- [ ] Admin commands have proper permission flags

## Common Operations

### Adding New Commands
```sourcepawn
// In OnPluginStart()
RegAdminCmd("sm_newcommd", Command_NewCommand, ADMFLAG_RCON, "Description");

// Command handler
public Action Command_NewCommand(int client, int args)
{
    // Validate client
    // Process command
    // Use translations for responses
    CReplyToCommand(client, "%t %t", "Prefix", "Success Message");
    return Plugin_Handled;
}
```

### Adding Configuration Options
```sourcepawn
// Create ConVar
ConVar g_cNewSetting;

// In OnPluginStart()
g_cNewSetting = CreateConVar("sm_new_setting", "default", "Description", 
                            FCVAR_NOTIFY, true, 0.0, true, 100.0);
HookConVarChange(g_cNewSetting, OnCvarChanged);

// Auto-generate config
AutoExecConfig(true);
```

### Working with KeyValues
```sourcepawn
// Safe KeyValues pattern - GetConfigKv() self-heals a missing/corrupted file and
// returns false only if it truly could not produce a usable config.
KeyValues kv;
if (GetConfigKv(kv) && kv.JumpToKey("section"))
{
    // Work with values
    kv.GetString("key", buffer, sizeof(buffer));
}
delete kv;  // Always cleanup, even on failure
```

## CI/CD Pipeline

The repository uses GitHub Actions for automated building:

- **Trigger**: Push, PR, or manual dispatch
- **Build**: Native workflow using `rumblefrog/setup-sp` + `spcomp` (no external build tool)
- **Package**: Creates distributable tar.gz with compiled plugin
- **Release**: Automatic releases on tags and main branch updates

## Performance Considerations

- Minimize operations in frequently called functions (OnGameFrame, etc.)
- Cache expensive calculations (time conversions, player counts)
- Use efficient data structures (ArrayList over arrays when size varies)
- Avoid unnecessary string operations in hot paths
- Consider server tick rate impact for timer intervals

## Debugging & Troubleshooting

### Common Issues
1. **Memory leaks**: Check all Handle deletions use `delete` without null checks
2. **Translation errors**: Verify phrase keys exist and format tokens match
3. **ConVar issues**: Ensure bounds are set and change hooks are registered
4. **File operations**: Always check FileExists() before operations

### Debug Mode
The plugin includes debug output via `sm_reloadrestartcfg debug`:
```sourcepawn
if (g_bDebug)
{
    CPrintToChat(client, "{red}[Debug] Information here");
}
```

## Security Considerations

- Admin commands use appropriate permission flags (ADMFLAG_RCON, ADMFLAG_ROOT)
- File paths are validated and use SM's BuildPath()
- No SQL in this plugin, but if added, must be async with proper escaping
- Input validation on all command arguments

## Version Management

- Plugin version defined in `myinfo` structure
- Semantic versioning (MAJOR.MINOR.PATCH)
- Version should match repository tags for releases
- Update version when making significant changes

---

**Note**: This is a production plugin handling server restarts. Always test changes thoroughly on development servers before deploying to live environments.