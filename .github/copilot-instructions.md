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

## Technical Environment

- **Language**: SourcePawn (`.sp` files)
- **Platform**: SourceMod 1.11+ (builds against 1.11.0-git6934)
- **Build System**: SourceKnight 0.2 (declarative build tool for SourceMod)
- **Dependencies**: 
  - SourceMod core
  - MultiColors (chat colors)
  - MapChooser Extended (optional, for nextmap integration)
- **Output**: Compiled `.smx` plugin files

## Build System

### Using SourceKnight
This project uses SourceKnight for dependency management and building:

```bash
# Install SourceKnight (if not using CI)
pip install sourceknight

# Build the plugin
sourceknight build

# Output will be in .sourceknight/package/addons/sourcemod/plugins/
```

### Manual Compilation
If SourceKnight is unavailable, you can compile manually with spcomp:
```bash
# Ensure SourceMod includes are available
spcomp -i"path/to/sourcemod/scripting/include" addons/sourcemod/scripting/FixMemoryLeak.sp
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
├── sourceknight.yaml                # Build configuration
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
    
    "info"          // Runtime state tracking
    {
        "nextrestart"   "timestamp"
        "nextmap"       "mapname"
        "restarted"     "0/1"
        "changed"       "0/1"
    }
    
    "restart"       // Scheduled restart times
    {
        "0"
        {
            "day"       "1"     // 1=Sunday, 7=Saturday
            "hour"      "6"     // 24-hour format
            "minute"    "0"
        }
    }
}
```

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
# Build using SourceKnight
sourceknight build

# Copy to test server
cp .sourceknight/package/addons/sourcemod/plugins/FixMemoryLeak.smx /path/to/server/addons/sourcemod/plugins/

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
// Safe KeyValues pattern
KeyValues kv;
GetConfigKv(kv);  // Creates and loads
if (kv.JumpToKey("section"))
{
    // Work with values
    kv.GetString("key", buffer, sizeof(buffer));
}
delete kv;  // Always cleanup
```

## CI/CD Pipeline

The repository uses GitHub Actions for automated building:

- **Trigger**: Push, PR, or manual dispatch
- **Build**: Uses SourceKnight action (`maxime1907/action-sourceknight@v1`)
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