#pragma semicolon 1
#pragma newdecls required

#include <nextmap>
#include <multicolors>

#undef REQUIRE_PLUGIN
#tryinclude <mapchooser_extended>
#define REQUIRE_PLUGIN

#define CONFIG_PATH             "configs/fixmemoryleak.cfg"
#define CONFIG_KV_NAME          "server"
#define CONFIG_KV_INFO_NAME     "info"
#define CONFIG_KV_RESTART_NAME  "restart"
#define CONFIG_KV_COMMANDS_NAME "commands"

#define MAX_POST_RESTART_EXEC   30.0    // typical map loading times and plugin initialization delays
#define MIN_RESTART_INTERVAL    300     // 5 minutes minimum between restarts
#define MAX_RESTART_DELAY       100000  // Maximum delay in minutes

public Plugin myinfo =
{
	name = "FixMemoryLeak",
	author = "maxime1907, .Rushaway",
	description = "Fix memory leaks resulting in crashes by restarting the server at a given time.",
	version = "2.0.0",
	url = "https://github.com/srcdslab"
}

// ==========================================
// ENUMS & STRUCTS
// ==========================================
enum RestartMode
{
	RestartMode_Delay = 0,      // Only delay-based restart
	RestartMode_Scheduled = 1,  // Only scheduled times
	RestartMode_Hybrid = 2      // Earliest of delay or scheduled
}

enum LogLevel
{
	LogLevel_Debug = 0,
	LogLevel_Info = 1,
	LogLevel_Warning = 2,
	LogLevel_Error = 3
}

enum struct PluginConfig
{
	RestartMode mode;
	int delayMinutes;
	int maxPlayers;
	bool countBots;
	bool earlyRestart;
	bool enableSecurity;

	void Init()
	{
		this.mode = RestartMode_Hybrid;
		this.delayMinutes = 1440;
		this.maxPlayers = -1;
		this.countBots = false;
		this.earlyRestart = true;
		this.enableSecurity = true;
	}
}

enum struct ScheduledRestart
{
	int dayOfWeek;     // 1-7 where 1=Monday, 2=Tuesday, ..., 6=Saturday, 7=Sunday (ISO 8601)
	int hour;          // 0-23
	int minute;        // 0-59
	int timestamp;     // Pre-calculated UNIX timestamp
}

enum struct PluginState
{
	// Runtime only
	bool isRestarting;
	bool isPostponed;
	bool nextMapSet;
	bool commandsExecuted;
	bool isManualRestart;
	bool isScheduledEndOfMap;

	// Persisted
	int nextRestartTime;
	char nextMap[PLATFORM_MAX_PATH];
	bool restarted;
	bool changed;

	void Reset()
	{
		this.isRestarting = false;
		this.isPostponed = false;
		this.nextMapSet = false;
		this.commandsExecuted = false;
		this.isManualRestart = false;
		this.isScheduledEndOfMap = false;
		this.nextRestartTime = 0;
		this.nextMap[0] = '\0';
		this.restarted = false;
		this.changed = false;
	}
}

// ==========================================
// GLOBAL VARIABLES
// ==========================================
PluginConfig g_Config;
PluginState g_State;
ArrayList g_ScheduledRestarts = null;

bool g_bLate = false;

ConVar g_cRestartMode, g_cRestartDelay;
ConVar g_cMaxPlayers, g_cMaxPlayersCountBots;
ConVar g_cvEarlySvRestart, g_cEnableSecurity;
ConVar g_cHostIP, g_cHostPort;

int g_iServerIP;
int g_iServerPort;

// ==========================================
// PLUGIN INITIALIZATION
// ==========================================
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	g_bLate = late;
	g_State.Reset();
	return APLRes_Success;
}

public void OnPluginStart()
{
	// Load translations
	LoadTranslations("FixMemoryLeak.phrases");

	// Initialize cvars with improved defaults and descriptions
	g_cRestartMode = CreateConVar("sm_restart_mode", "2", "Restart mode: 0 = Delay only, 1 = Scheduled only, 2 = Hybrid (earliest of both)", FCVAR_NOTIFY, true, 0.0, true, 2.0);
	g_cRestartDelay = CreateConVar("sm_restart_delay", "1440", "Delay before restart in minutes (1-100000)", FCVAR_NOTIFY, true, 1.0, true, 100000.0);
	g_cMaxPlayers = CreateConVar("sm_restart_maxplayers", "-1", "Cancel restart if more players than this (-1 = disabled, 0-64)", FCVAR_NOTIFY, true, -1.0, true, float(MAXPLAYERS));
	g_cMaxPlayersCountBots = CreateConVar("sm_restart_maxplayers_count_bots", "0", "Include bots in player count for max players check", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvEarlySvRestart = CreateConVar("sm_fixmemoryleak_early_restart", "1", "Reduce restart delay by half when no human players online (works in delay and hybrid modes)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cEnableSecurity = CreateConVar("sm_fixmemoryleak_security", "1", "Enable security features (restart loop prevention)", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	// Hook CVARs
	HookConVarChange(g_cRestartMode, OnCvarChanged);
	HookConVarChange(g_cRestartDelay, OnCvarChanged);
	HookConVarChange(g_cMaxPlayers, OnCvarChanged);
	HookConVarChange(g_cMaxPlayersCountBots, OnCvarChanged);
	HookConVarChange(g_cvEarlySvRestart, OnCvarChanged);
	HookConVarChange(g_cEnableSecurity, OnCvarChanged);

	AutoExecConfig(true);

	g_cHostIP    = FindConVar("hostip");
	g_cHostPort = FindConVar("hostport");

	g_iServerIP   = g_cHostIP .IntValue;
	g_iServerPort = g_cHostPort.IntValue;

	// Register commands
	RegAdminCmd("sm_restartsv", Command_RestartServer, ADMFLAG_RCON, "Force a server restart to the next map");
	RegAdminCmd("sm_cancelrestart", Command_AdminCancel, ADMFLAG_RCON, "Cancel or postpone the scheduled restart");
	RegAdminCmd("sm_svnextrestart", Command_SvNextRestart, ADMFLAG_RCON, "Display time until next scheduled restart");
	RegAdminCmd("sm_reloadrestartcfg", Command_DebugConfig, ADMFLAG_ROOT, "Reload restart configuration from file");
	RegAdminCmd("sm_forcerestartcmds", Command_ForceRestartCommands, ADMFLAG_ROOT, "Force execution of post-restart commands");
	RegAdminCmd("sm_schedulerestart", Command_ScheduleEndOfMapRestart, ADMFLAG_ROOT, "Schedule a server restart at the end of the current map (toggle)");

	// Register server command hooks
	RegServerCmd("changelevel", Hook_OnMapChange);
	RegServerCmd("quit", Hook_OnServerQuit);
	RegServerCmd("_restart", Hook_OnServerRestart);

	// Hook events
	HookEvent("round_end", OnRoundEnd, EventHookMode_Pre);

	// Initialize the plugin using the new modular architecture
	InitializePlugin();
}

public void OnPluginEnd()
{
	UnhookEvent("round_end", OnRoundEnd, EventHookMode_Pre);

	if (g_ScheduledRestarts != null)
		delete g_ScheduledRestarts;
}

public void OnMapStart()
{
	LogPluginMessage(LogLevel_Debug, "Map start - resetting state and scheduling next restart");

	g_State.isRestarting = false;
	g_State.isPostponed = false;
	g_State.nextMapSet = false;
	g_State.isScheduledEndOfMap = false;

	ConfigManager_LoadScheduledRestarts();

	PluginState_Load();

	RestartScheduler_RestoreStateFromConfig();

	if (g_State.restarted && !g_State.changed && g_State.nextMap[0] != '\0')
	{
		g_State.changed = true;
		PluginState_Save();

		DataPack dp;
		CreateDataTimer(1.0, Timer_ChangeToNextMap, dp, TIMER_FLAG_NO_MAPCHANGE);
		dp.WriteString(g_State.nextMap);
	}

	RestartScheduler_ScheduleNextRestart("");
}

// ==========================================
// CALLBACKS & HOOKS
// ==========================================
public void OnCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	char convarName[64];
	GetConVarName(convar, convarName, sizeof(convarName));
	LogPluginMessage(LogLevel_Debug, "ConVar changed: %s from '%s' to '%s'", convarName, oldValue, newValue);

	// Reload configuration with new values
	if (!ConfigManager_LoadConfiguration())
	{
		LogPluginMessage(LogLevel_Error, "Failed to reload configuration after ConVar change");
		return;
	}

	// Recalculate next restart time
	if (!g_State.nextMapSet)
	{
		RestartScheduler_ScheduleNextRestart("");
	}
}

#if defined _mapchooser_extended_included_
public void OnSetNextMap(const char[] map)
{
	// Only update the target map, don't recalculate restart time if already set
	if (g_State.nextMapSet)
	{
		strcopy(g_State.nextMap, sizeof(g_State.nextMap), map);
		PluginState_Save();
		LogPluginMessage(LogLevel_Debug, "Next map updated to '%s' (restart time unchanged)", map);
	}
	else
	{
		RestartScheduler_ScheduleNextRestart(map);
	}
}
#endif

public Action Hook_OnMapChange(int args)
{
	char nextMap[PLATFORM_MAX_PATH];
	strcopy(nextMap, sizeof(nextMap), g_State.nextMap);
	LogPluginMessage(LogLevel_Debug, "Map change hook triggered with next map: %s", nextMap);

	// End-of-map restart scheduled via sm_schedulerestart takes priority
	if (g_State.isScheduledEndOfMap)
	{
		LogPluginMessage(LogLevel_Info, "Triggering scheduled end-of-map server restart");
		g_State.isScheduledEndOfMap = false;
		g_State.nextMapSet = false;
		RestartScheduler_ScheduleNextRestart(nextMap);
		PerformManualRestart();
		return Plugin_Continue;
	}

	if (RestartScheduler_IsRestartDue() && !RestartScheduler_ShouldPostponeRestart())
	{
		LogPluginMessage(LogLevel_Info, "Initiating scheduled server restart");

		g_State.nextMapSet = false;
		RestartScheduler_ScheduleNextRestart(nextMap);
		PerformServerRestart();
	}
	else
	{
		g_State.isPostponed = false;
	}

	return Plugin_Continue;
}

Action Helper_OnServerShutdown(bool isRestart)
{
	char commandName[16];
	strcopy(commandName, sizeof(commandName), isRestart ? "_restart" : "quit");

	// Security check: prevent restart loops (skip if manual restart)
	if (!g_State.isManualRestart && g_State.isRestarting)
	{
		if (g_Config.enableSecurity)
		{
			LogPluginMessage(LogLevel_Error, "Server %s blocked: Already in restart process (potential restart loop detected)", commandName);
			return Plugin_Stop;
		}
		else
		{
			LogPluginMessage(LogLevel_Warning, "Server %s during restart process - allowing to proceed (security disabled)", commandName);
			return Plugin_Continue;
		}
	}

	LogPluginMessage(LogLevel_Info, "Server %s detected - saving restart state", commandName);

	g_State.isRestarting = true;

	// Don't overwrite nextmap if manual restart (already set by Command_RestartServer)
	if (!g_State.isManualRestart)
	{
		char currentMap[PLATFORM_MAX_PATH];
		GetCurrentMap(currentMap, sizeof(currentMap));
		strcopy(g_State.nextMap, sizeof(g_State.nextMap), currentMap);
	}

	g_State.restarted = true;
	PluginState_Save();
	ReconnectPlayers();

	LogPluginMessage(LogLevel_Info, "Restart state saved, allowing server %s to proceed", commandName);
	return Plugin_Continue;
}

public Action Hook_OnServerQuit(int args)
{
	return Helper_OnServerShutdown(false);
}

public Action Hook_OnServerRestart(int args)
{
	return Helper_OnServerShutdown(true);
}

public Action OnRoundEnd(Handle event, const char[] name, bool dontBroadcast)
{
	LogPluginMessage(LogLevel_Debug, "Round end - checking restart conditions");

	int timeleft;
	GetMapTimeLeft(timeleft);

	// Map still has time left - show "restart soon" warnings if applicable
	if (timeleft > 0)
	{
		// Should we warn players about an upcoming restart?
		if (g_State.isScheduledEndOfMap || (RestartScheduler_IsRestartDue() && !g_State.isPostponed))
		{
			LogPluginMessage(LogLevel_Debug, "Showing 'restart soon' warnings");
			PrintHintTextToAll("%t", "Restart Soon Other");
			CPrintToChatAll("%t %t", "Alert", "Restart Soon Chat", "Alert");
			ServerCommand("sm_csay %t", "Restart Soon Other");
			if (!IsVoteInProgress())
				ServerCommand("sm_msay %t", "Restart Soon Other");
		}

		return Plugin_Continue;
	}

	// Map has ended - handle end-of-map scheduled restart first
	if (g_State.isScheduledEndOfMap)
	{
		PerformManualRestart();
		return Plugin_Continue;
	}

	if (!RestartScheduler_IsRestartDue())
	{
		LogPluginMessage(LogLevel_Debug, "Restart not due yet");
		return Plugin_Continue;
	}

	// Check if restart should be postponed
	if (RestartScheduler_ShouldPostponeRestart())
	{
		g_State.isPostponed = true;
		int playerCount = RestartScheduler_GetPlayerCount();

		LogPluginMessage(LogLevel_Info, "Restart postponed due to player count (%d > %d)", playerCount, g_Config.maxPlayers);

		CPrintToChatAll("%t %t", "Prefix", "Restart Postponed Chat", playerCount, g_Config.maxPlayers);
		PrintHintTextToAll("%t", "Restart Postponed Other", playerCount, g_Config.maxPlayers);
		ServerCommand("sm_msay %t", "Restart Postponed Other", playerCount, g_Config.maxPlayers);
		ServerCommand("sm_csay %t", "Restart Postponed Other", playerCount, g_Config.maxPlayers);

		return Plugin_Continue;
	}

	// Show restart initiation messages
	if (!g_State.isPostponed)
	{
		LogPluginMessage(LogLevel_Info, "Showing restart initiation messages");

		ServerCommand("sm_csay %t", "Restart Start Other");
		ServerCommand("sm_msay %t", "Restart Start Other");
		PrintHintTextToAll("%t", "Restart Start Other");
		CPrintToChatAll("%t", "Alert", "Restart Start Chat");
	}

	return Plugin_Continue;
}

// ==========================================
// COMMANDS
// ==========================================
public Action Command_RestartServer(int client, int argc)
{
	LogPluginMessage(LogLevel_Info, "Manual restart requested by: %L", client);

	char nextMap[PLATFORM_MAX_PATH];
	if (!GetNextMap(nextMap, sizeof(nextMap)))
	{
		CReplyToCommand(client, "%t %t", "Prefix", "No Nextmap Set");
		LogPluginMessage(LogLevel_Warning, "Cannot restart server: no next map set");
		return Plugin_Handled;
	}

	PerformManualRestart();

	LogPluginMessage(LogLevel_Info, "Manual server restart initiated to map: %s", nextMap);
	return Plugin_Handled;
}

public Action Command_ScheduleEndOfMapRestart(int client, int argc)
{
	char clientName[64];
	if (client == 0)
		strcopy(clientName, sizeof(clientName), "Server Console");
	else if (!GetClientName(client, clientName, sizeof(clientName)))
		Format(clientName, sizeof(clientName), "Unknown (ID: %d)", client);

	// Toggle: if already scheduled, cancel it
	if (g_State.isScheduledEndOfMap)
	{
		g_State.isScheduledEndOfMap = false;

		LogPluginMessage(LogLevel_Info, "%s cancelled the end-of-map restart", clientName);

		CPrintToChatAll("%t %t", "Prefix", "EndOfMap Restart Cancelled", clientName);
		CReplyToCommand(client, "%t %t", "Prefix", "EndOfMap Restart Cancelled", clientName);
		return Plugin_Handled;
	}

	if (g_State.isRestarting)
	{
		CReplyToCommand(client, "%t %t", "Prefix", "Restart Already In Progress");
		LogPluginMessage(LogLevel_Warning, "%s tried to schedule end-of-map restart but a restart is already in progress", clientName);
		return Plugin_Handled;
	}

	g_State.isScheduledEndOfMap = true;

	// Capture next map now; OnSetNextMap will update g_State.nextMap if MCE changes it later
	char nextMap[PLATFORM_MAX_PATH];
	if (!GetNextMap(nextMap, sizeof(nextMap)))
	{
		GetCurrentMap(nextMap, sizeof(nextMap));
		LogPluginMessage(LogLevel_Warning, "No next map set at schedule time, using current map as fallback: %s", nextMap);
	}

	strcopy(g_State.nextMap, sizeof(g_State.nextMap), nextMap);
	PluginState_Save();

	LogPluginMessage(LogLevel_Info, "%s scheduled an end-of-map server restart (next map: %s)", clientName, nextMap);

	CPrintToChatAll("%t %t", "Prefix", "EndOfMap Restart Scheduled Chat", clientName);
	PrintHintTextToAll("%t", "EndOfMap Restart Scheduled Other", clientName);
	ServerCommand("sm_msay %t", "EndOfMap Restart Scheduled Other", clientName);

	CReplyToCommand(client, "%t %t", "Prefix", "EndOfMap Restart Confirm", nextMap);
	return Plugin_Handled;
}

public Action Command_SvNextRestart(int client, int argc)
{
	// Show end-of-map scheduled restart status if active
	if (g_State.isScheduledEndOfMap)
	{
		CReplyToCommand(client, "%t %t", "Prefix", "EndOfMap Restart Active");
		return Plugin_Handled;
	}

	int currentTime = GetTime();
	int timeUntilRestart = g_State.nextRestartTime - currentTime;

	if (timeUntilRestart <= 0)
	{
		CReplyToCommand(client, "%t %t", "Prefix", "Restart Due Now");
		return Plugin_Handled;
	}

	switch (g_Config.mode)
	{
		case RestartMode_Delay:
		{
			// Show delay-based information
			int minutes = timeUntilRestart / 60;
			int hours = minutes / 60;
			int days = hours / 24;
			hours = hours % 24;
			minutes = minutes % 60;

			CReplyToCommand(client, "%t %t", "Prefix", "Next Restart Delay", days, hours, minutes);
		}
		case RestartMode_Scheduled, RestartMode_Hybrid:
		{
			// Show scheduled time information
			char scheduledTime[128], remainingTime[128];

			FormatTime(scheduledTime, sizeof(scheduledTime), "%A %d %B %Y @ %H:%M:%S", g_State.nextRestartTime);

			int remainingHours = timeUntilRestart / 3600;
			int remainingMinutes = (timeUntilRestart % 3600) / 60;
			int remainingSeconds = timeUntilRestart % 60;

			Format(remainingTime, sizeof(remainingTime), "%02d:%02d:%02d", remainingHours, remainingMinutes, remainingSeconds);

			CReplyToCommand(client, "%t %t", "Prefix", "Next Restart Time", scheduledTime);
			CReplyToCommand(client, "%t %t", "Prefix", "Remaining Time", remainingTime);

			// Show restart mode
			char modeName[32] = "Hybrid";
			if (g_Config.mode == RestartMode_Scheduled)
				strcopy(modeName, sizeof(modeName), "Scheduled");

			CReplyToCommand(client, "%t %t", "Prefix", "Restart Mode Info", modeName);
		}
	}

	// Show additional status information
	if (g_State.isPostponed)
	{
		CReplyToCommand(client, "%t %t", "Prefix", "Restart Postponed Status");
	}

	int playerCount = RestartScheduler_GetPlayerCount();
	CReplyToCommand(client, "%t %t", "Prefix", "Current Players", playerCount);

	return Plugin_Handled;
}

public Action Command_DebugConfig(int client, int argc)
{
	bool enableDebug = (argc >= 1);

	LogPluginMessage(LogLevel_Info, "Configuration reload requested by client %d (debug: %s)", client, enableDebug ? "enabled" : "disabled");

	if (ConfigManager_LoadConfiguration() && ConfigManager_LoadScheduledRestarts())
	{
		CReplyToCommand(client, "%t %t", "Prefix", "Reload Config Success");

		if (enableDebug)
		{
			CReplyToCommand(client, "%t %t", "Prefix", "Debug Config Header");

			char modeName[32];
			switch (g_Config.mode)
			{
				case RestartMode_Delay: strcopy(modeName, sizeof(modeName), "Delay");
				case RestartMode_Scheduled: strcopy(modeName, sizeof(modeName), "Scheduled");
				case RestartMode_Hybrid: strcopy(modeName, sizeof(modeName), "Hybrid");
			}

			CReplyToCommand(client, "%t %t", "Prefix", "Debug Mode", g_Config.mode, modeName);
			CReplyToCommand(client, "%t %t", "Prefix", "Debug Delay", g_Config.delayMinutes);
			CReplyToCommand(client, "%t %t", "Prefix", "Debug Max Players", g_Config.maxPlayers);
			CReplyToCommand(client, "%t %t", "Prefix", "Debug Count Bots", g_Config.countBots ? "Yes" : "No");
			CReplyToCommand(client, "%t %t", "Prefix", "Debug Early Restart", g_Config.earlyRestart ? "Yes" : "No");
			CReplyToCommand(client, "%t %t", "Prefix", "Debug Security", g_Config.enableSecurity ? "Enabled" : "Disabled");

			// Show end-of-map restart status
			CReplyToCommand(client, "%t %t", "Prefix", "Debug EndOfMap Restart", g_State.isScheduledEndOfMap ? "Yes" : "No");

			// Show scheduled restarts
			if (g_ScheduledRestarts != null && g_ScheduledRestarts.Length > 0)
			{
				CReplyToCommand(client, "%t %t", "Prefix", "Debug Scheduled Restarts", g_ScheduledRestarts.Length);
				for (int i = 0; i < g_ScheduledRestarts.Length; i++)
				{
					ScheduledRestart restart;
					g_ScheduledRestarts.GetArray(i, restart, sizeof(restart));

					char dayName[16];
					GetDayName(restart.dayOfWeek, dayName, sizeof(dayName));

					CReplyToCommand(client, "%t  %s (day=%d) %02d:%02d", "Prefix", dayName, restart.dayOfWeek, restart.hour, restart.minute);
				}
			}

			CReplyToCommand(client, "%t %t", "Prefix", "Debug Timing Info");
		}
	}
	else
	{
		CReplyToCommand(client, "%t %t", "Prefix", "Reload Config Error");
		LogPluginMessage(LogLevel_Error, "Failed to reload configuration");
	}

	return Plugin_Handled;
}

public Action Command_AdminCancel(int client, int argc)
{
	char clientName[64];

	if (client == 0)
		strcopy(clientName, sizeof(clientName), "Server Console");
	else if (!GetClientName(client, clientName, sizeof(clientName)))
		Format(clientName, sizeof(clientName), "Unknown (ID: %d)", client);

	// If an end-of-map restart is active, cancel that too
	if (g_State.isScheduledEndOfMap)
	{
		g_State.isScheduledEndOfMap = false;
		LogPluginMessage(LogLevel_Info, "%s cancelled the end-of-map restart via sm_cancelrestart", clientName);
		CPrintToChatAll("%t %t", "Prefix", "EndOfMap Restart Cancelled", clientName);
		CReplyToCommand(client, "%t %t", "Prefix", "EndOfMap Restart Cancelled", clientName);
		return Plugin_Handled;
	}

	// Toggle postponement state
	g_State.isPostponed = !g_State.isPostponed;

	LogPluginMessage(LogLevel_Info, "%s has %s the server restart", clientName, g_State.isPostponed ? "postponed" : "resumed");

	char action[32];
	strcopy(action, sizeof(action), g_State.isPostponed ? "Postponed" : "Resumed");

	CPrintToChatAll("%t %t", "Prefix", "Server Restart", clientName, action);

	// Provide feedback about the change
	if (g_State.isPostponed)
	{
		CReplyToCommand(client, "%t %t", "Prefix", "Restart Postponed Info");
	}
	else
	{
		CReplyToCommand(client, "%t %t", "Prefix", "Restart Active Info", g_State.nextRestartTime);
	}

	return Plugin_Handled;
}

public Action Command_ForceRestartCommands(int client, int argc)
{
	char clientName[64];
	if (client == 0)
		strcopy(clientName, sizeof(clientName), "Server Console");
	else if (!GetClientName(client, clientName, sizeof(clientName)))
		Format(clientName, sizeof(clientName), "Unknown (ID: %d)", client);

	LogPluginMessage(LogLevel_Info, "%s forced execution of post-restart commands", clientName);

	// Reset execution flag to allow re-execution
	g_State.commandsExecuted = false;

	bool success = LoadCommandsAfterRestart(true);

	// Re-set the flag to prevent automatic execution
	g_State.commandsExecuted = true;

	if (success)
	{
		CReplyToCommand(client, "%t %t", "Prefix", "Reload Config Success");
		LogPluginMessage(LogLevel_Info, "Post-restart commands executed successfully by %s", clientName);
	}
	else
	{
		CReplyToCommand(client, "%t %t", "Prefix", "Reload Config Error");
		LogPluginMessage(LogLevel_Warning, "Failed to execute post-restart commands for %s", clientName);
	}

	return Plugin_Handled;
}

// ==========================================
// TIMERS & FRAMES
// ==========================================
public Action Timer_ChangeToNextMap(Handle timer, DataPack dp)
{
	if (g_bLate)
	{
		LogPluginMessage(LogLevel_Debug, "Avoiding map change during late plugin load");
		return Plugin_Stop;
	}

	char nextMap[PLATFORM_MAX_PATH];

	dp.Reset();
	dp.ReadString(nextMap, sizeof(nextMap));

	if (nextMap[0] == '\0')
	{
		LogPluginMessage(LogLevel_Warning, "No valid map name found in DataPack, aborting map change.");
		return Plugin_Stop;
	}

	LogPluginMessage(LogLevel_Info, "Changing to restart map: %s", nextMap);
	ForceChangeLevel(nextMap, "FixMemoryLeak");
	return Plugin_Stop;
}

void ExecuteServerQuit()
{
	LogPluginMessage(LogLevel_Info, "Executing server quit command");
	ServerCommand("quit");
}

// ==========================================
// MAIN PLUGIN FUNCTIONS
// ==========================================
void InitializePlugin()
{
	LogPluginMessage(LogLevel_Debug, "Initializing plugin modules...");

	// Load and validate configuration
	if (!ConfigManager_LoadConfiguration())
	{
		LogPluginMessage(LogLevel_Warning, "Failed to load configuration, using defaults");
	}

	// Load scheduled restarts
	ConfigManager_LoadScheduledRestarts();

	// Execute post-restart commands if needed
	LoadCommandsAfterRestart(false);

	LogPluginMessage(LogLevel_Debug, "Plugin initialization complete");
}

void PerformServerRestart()
{
	if (!Security_IsRestartSafe())
	{
		LogPluginMessage(LogLevel_Error, "Server restart blocked by security validation");
		return;
	}

	if (g_State.isRestarting)
	{
		LogPluginMessage(LogLevel_Warning, "Restart already in progress, ignoring duplicate request");
		return;
	}

	g_State.isRestarting = true;

	LogPluginMessage(LogLevel_Info, "Initiating server restart process");

	ReconnectPlayers();

	g_State.restarted = true;
	PluginState_Save();

	RequestFrame(ExecuteServerQuit);
}

void PerformManualRestart()
{
	char nextMap[PLATFORM_MAX_PATH];
	if (!GetNextMap(nextMap, sizeof(nextMap)))
	{
		LogPluginMessage(LogLevel_Warning, "Cannot restart server: no next map set");
		return;
	}

	strcopy(g_State.nextMap, sizeof(g_State.nextMap), nextMap);
	g_State.nextRestartTime = GetTime();
	g_State.restarted = false;
	g_State.changed = false;
	g_State.isManualRestart = true;
	PluginState_Save();
	PerformServerRestart();
}

stock void ReconnectPlayers()
{
	static char sAddress[128];
	FormatEx(sAddress, sizeof(sAddress), "%d.%d.%d.%d:%d", g_iServerIP >>> 24 & 255, g_iServerIP >>> 16 & 255, g_iServerIP >>> 8 & 255, g_iServerIP & 255, g_iServerPort);
	LogPluginMessage(LogLevel_Info, "Reconnecting players to address: %s", sAddress);

	// bug: Retry command does not work #25 - https://github.com/srcdslab/sm-plugin-FixMemoryLeak/issues/25
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientConnected(i) && !IsFakeClient(i))
			ClientCommand(i, "redirect %s", sAddress);
	}
}

stock bool LoadCommandsAfterRestart(bool bReload = false)
{
	// Prevent execution if conditions not met
	if (!bReload && (g_bLate || g_State.commandsExecuted || GetEngineTime() > MAX_POST_RESTART_EXEC))
		return false;

	LogPluginMessage(LogLevel_Debug, "Loading post-restart commands (reload: %s)", bReload ? "true" : "false");

	KeyValues kv = null;
	if (!ConfigManager_GetConfigKeyValues(kv))
		return false;

	if (!kv.JumpToKey(CONFIG_KV_COMMANDS_NAME))
	{
		LogPluginMessage(LogLevel_Warning, "No commands section found in configuration");
		g_State.commandsExecuted = true;
		delete kv;
		return false;
	}

	if (kv.GotoFirstSubKey(false))
	{
		int executedCount = 0;
		char command[PLATFORM_MAX_PATH];

		do
		{
			kv.GetString(NULL_STRING, command, sizeof(command));
			if (command[0] != '\0')
			{
				LogPluginMessage(LogLevel_Info, "Executing post-restart command: %s", command);
				ServerCommand(command);
				executedCount++;
			}
		} while (kv.GotoNextKey(false));

		kv.GoBack();

		if (executedCount > 0)
			LogPluginMessage(LogLevel_Info, "Successfully executed %d post-restart commands", executedCount);
		else
			LogPluginMessage(LogLevel_Warning, "No valid commands found to execute");

		g_State.commandsExecuted = true;
	}
	else
	{
		LogPluginMessage(LogLevel_Debug, "No commands configured for execution after restart");
		g_State.commandsExecuted = true;
		delete kv;
		return false;
	}

	delete kv;
	return true;
}

// ==========================================
// LOGGING
// ==========================================
void LogPluginMessage(LogLevel level, const char[] message, any ...)
{
	char formattedMessage[512];
	VFormat(formattedMessage, sizeof(formattedMessage), message, 3);

	static const char levelPrefixes[][] = { "[DEBUG]", "[INFO]", "[WARNING]", "[ERROR]" };

	char finalMessage[512];
	Format(finalMessage, sizeof(finalMessage), "[FixMemoryLeak] %s %s", levelPrefixes[level], formattedMessage);

	if (level == LogLevel_Error)
		LogError(finalMessage);
	else
		LogMessage(finalMessage);
}

// ==========================================
// SECURITY MANAGER
// ==========================================
bool PluginConfig_Validate(PluginConfig config)
{
	if (view_as<int>(config.mode) < 0 || view_as<int>(config.mode) > 2)
		return false;

	if (config.delayMinutes < 1 || config.delayMinutes > MAX_RESTART_DELAY)
		return false;

	if (config.maxPlayers < -1 || config.maxPlayers > MAXPLAYERS)
		return false;

	return true;
}

bool Security_IsRestartSafe()
{
	// Skip security checks if disabled
	if (!g_Config.enableSecurity)
		return true;

	// Check if we're already in a restart process
	if (g_State.isRestarting)
	{
		LogPluginMessage(LogLevel_Warning, "Restart blocked: Already restarting");
		return false;
	}

	// Validate configuration
	if (!PluginConfig_Validate(g_Config))
	{
		LogPluginMessage(LogLevel_Error, "Restart blocked: Invalid configuration");
		return false;
	}

	return true;
}

bool Security_ValidateScheduledRestart(ScheduledRestart restart)
{
	// Unified format: 1-7 (1=Monday, 7=Sunday)
	if (restart.dayOfWeek < 1 || restart.dayOfWeek > 7) return false;
	if (restart.hour < 0 || restart.hour > 23) return false;
	if (restart.minute < 0 || restart.minute > 59) return false;
	return true;
}

// ==========================================
// CONFIG MANAGER
// ==========================================
bool ConfigManager_LoadConfiguration()
{
	// Initialize defaults
	g_Config.Init();

	// Load from CVars with validation
	g_Config.mode = view_as<RestartMode>(g_cRestartMode.IntValue);
	g_Config.delayMinutes = g_cRestartDelay.IntValue;
	g_Config.maxPlayers = g_cMaxPlayers.IntValue;
	g_Config.countBots = g_cMaxPlayersCountBots.BoolValue;
	g_Config.earlyRestart = g_cvEarlySvRestart.BoolValue;
	g_Config.enableSecurity = g_cEnableSecurity.BoolValue;

	// Warn if early restart is enabled but not in delay or hybrid mode
	if (g_Config.earlyRestart && g_Config.mode == RestartMode_Scheduled)
	{
		LogPluginMessage(LogLevel_Warning, "Early restart is enabled but doesn't work in scheduled-only mode (sm_restart_mode = 1). Use delay mode (0) or hybrid mode (2).");
	}

	// Validate configuration
	if (!PluginConfig_Validate(g_Config))
	{
		LogPluginMessage(LogLevel_Error, "Invalid configuration detected, using defaults");
		g_Config.Init();
		return false;
	}

	LogPluginMessage(LogLevel_Debug, "Configuration loaded successfully");
	return true;
}

bool ConfigManager_LoadScheduledRestarts()
{
	if (g_ScheduledRestarts != null)
		delete g_ScheduledRestarts;

	g_ScheduledRestarts = new ArrayList(sizeof(ScheduledRestart));

	KeyValues kv = null;
	if (!ConfigManager_GetConfigKeyValues(kv))
		return false;

	if (!kv.JumpToKey(CONFIG_KV_RESTART_NAME))
	{
		delete kv;
		return false;
	}

	if (!kv.GotoFirstSubKey())
	{
		delete kv;
		return false;
	}

	int loadedCount = 0;
	do
	{
		char dayStr[8], hourStr[8], minuteStr[8];
		kv.GetString("day", dayStr, sizeof(dayStr), "");
		kv.GetString("hour", hourStr, sizeof(hourStr), "");
		kv.GetString("minute", minuteStr, sizeof(minuteStr), "");

		if (strlen(dayStr) == 0 || strlen(hourStr) == 0 || strlen(minuteStr) == 0)
			continue;

		ScheduledRestart restart;
		restart.dayOfWeek = StringToInt(dayStr);  // Keep 1-7 format directly
		restart.hour = StringToInt(hourStr);
		restart.minute = StringToInt(minuteStr);

		if (Security_ValidateScheduledRestart(restart))
		{
			restart.timestamp = ConfigManager_CalculateNextOccurrenceTimestamp(restart);
			g_ScheduledRestarts.PushArray(restart, sizeof(restart));
			loadedCount++;

			LogPluginMessage(LogLevel_Debug, "Loaded scheduled restart: Day=%d, %02d:%02d", restart.dayOfWeek, restart.hour, restart.minute);
		}
		else
		{
			LogPluginMessage(LogLevel_Warning, "Invalid scheduled restart configuration: Day=%s, Hour=%s, Minute=%s", dayStr, hourStr, minuteStr);
		}

	} while (kv.GotoNextKey());

	delete kv;

	LogPluginMessage(LogLevel_Info, "Loaded %d scheduled restart configurations", loadedCount);
	return (loadedCount > 0);
}

int ConfigManager_CalculateNextOccurrenceTimestamp(ScheduledRestart restart)
{
	int currentTime = GetTime();

	// Get current time components using FormatTime
	char timeStr[64];
	FormatTime(timeStr, sizeof(timeStr), "%w %H %M", currentTime);
	char timeParts[3][8];
	ExplodeString(timeStr, " ", timeParts, sizeof(timeParts), sizeof(timeParts[]));

	int currentDayFormatTime = StringToInt(timeParts[0]);  // 0-6 (0=Sunday from FormatTime)
	int currentHour = StringToInt(timeParts[1]);           // 0-23
	int currentMinute = StringToInt(timeParts[2]);         // 0-59

	// Convert FormatTime format (0=Sunday) to our unified format (1=Monday, 7=Sunday)
	int currentDay;
	if (currentDayFormatTime == 0)
		currentDay = 7;  // Sunday: FormatTime 0 → Our format 7
	else
		currentDay = currentDayFormatTime;  // Monday-Saturday: 1-6 stays the same

	// Convert our format (1=Monday, 7=Sunday) to "days since Monday"
	// Monday = 0, Tuesday = 1, ..., Sunday = 6
	int currentDaysSinceMonday = (currentDay == 7) ? 6 : (currentDay - 1);
	int targetDaysSinceMonday = (restart.dayOfWeek == 7) ? 6 : (restart.dayOfWeek - 1);

	// Calculate current time in minutes since Monday 00:00
	int currentWeekMinutes = (currentDaysSinceMonday * 24 * 60) + (currentHour * 60) + currentMinute;

	// Calculate target time in minutes since Monday 00:00
	int targetWeekMinutes = (targetDaysSinceMonday * 24 * 60) + (restart.hour * 60) + restart.minute;

	// Calculate difference in minutes
	int minutesDiff = targetWeekMinutes - currentWeekMinutes;

	// If target is in the past this week, schedule for next week
	if (minutesDiff <= 0)
		minutesDiff += 7 * 24 * 60; // Add one week in minutes

	// Calculate target timestamp
	int targetTime = currentTime + (minutesDiff * 60);

	char currentDayName[16];
	char targetDayName[16];
	GetDayName(currentDay, currentDayName, sizeof(currentDayName));
	GetDayName(restart.dayOfWeek, targetDayName, sizeof(targetDayName));

	LogPluginMessage(LogLevel_Debug, "Scheduled restart calculation: Current day=%d (%s), Target day=%d (%s) %02d:%02d, Minutes diff=%d, Target timestamp=%d",
		currentDay, currentDayName, restart.dayOfWeek, targetDayName, restart.hour, restart.minute, minutesDiff, targetTime);

	return targetTime;
}

bool ConfigManager_GetConfigKeyValues(KeyValues &kv)
{
	kv = new KeyValues(CONFIG_KV_NAME);

	char filePath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, filePath, sizeof(filePath), CONFIG_PATH);

	if (!FileExists(filePath))
	{
		LogPluginMessage(LogLevel_Warning, "Configuration file not found, creating default: %s", filePath);
		ConfigManager_CreateDefaultConfig(filePath);
	}

	if (!kv.ImportFromFile(filePath))
	{
		LogPluginMessage(LogLevel_Error, "Failed to parse configuration file: %s", filePath);
		delete kv;
		return false;
	}

	return true;
}

void ConfigManager_CreateDefaultConfig(const char[] filePath)
{
	File configFile = OpenFile(filePath, "w");
	if (configFile == null)
	{
		LogPluginMessage(LogLevel_Error, "Failed to create configuration file: %s", filePath);
		return;
	}

	// Write default configuration with detailed comments
	WriteFileLine(configFile, "\"%s\"", CONFIG_KV_NAME);
	WriteFileLine(configFile, "{");
	WriteFileLine(configFile, "\t// Commands to execute after server restart");
	WriteFileLine(configFile, "\t\"%s\"", CONFIG_KV_COMMANDS_NAME);
	WriteFileLine(configFile, "\t{");
	WriteFileLine(configFile, "\t\t\"cmd\"\t\"\"");
	WriteFileLine(configFile, "\t}");
	WriteFileLine(configFile, "");
	WriteFileLine(configFile, "\t// Internal plugin state - do not edit manually");
	WriteFileLine(configFile, "\t\"%s\"", CONFIG_KV_INFO_NAME);
	WriteFileLine(configFile, "\t{");
	WriteFileLine(configFile, "\t\t\"nextrestart\"\t\"\"");
	WriteFileLine(configFile, "\t\t\"nextmap\"\t\"\"");
	WriteFileLine(configFile, "\t\t\"restarted\"\t\"\"");
	WriteFileLine(configFile, "\t\t\"changed\"\t\"\"");
	WriteFileLine(configFile, "\t}");
	WriteFileLine(configFile, "");
	WriteFileLine(configFile, "\t// Scheduled restart times");
	WriteFileLine(configFile, "\t// CONFIG DAY FORMAT: 1-7 where:");
	WriteFileLine(configFile, "\t//   1 = Monday");
	WriteFileLine(configFile, "\t//   2 = Tuesday");
	WriteFileLine(configFile, "\t//   3 = Wednesday");
	WriteFileLine(configFile, "\t//   4 = Thursday");
	WriteFileLine(configFile, "\t//   5 = Friday");
	WriteFileLine(configFile, "\t//   6 = Saturday");
	WriteFileLine(configFile, "\t//   7 = Sunday");
	WriteFileLine(configFile, "\t// Hour format: 0-23 (24-hour format)");
	WriteFileLine(configFile, "\t// Minute format: 0-59");
	WriteFileLine(configFile, "\t// You can add multiple restart schedules by adding more numbered sections");
	WriteFileLine(configFile, "\t\"%s\"", CONFIG_KV_RESTART_NAME);
	WriteFileLine(configFile, "\t{");
	WriteFileLine(configFile, "\t\t// Example: Monday at 06:00 AM");
	WriteFileLine(configFile, "\t\t\"0\"");
	WriteFileLine(configFile, "\t\t{");
	WriteFileLine(configFile, "\t\t\t\"day\"\t\t\"1\"");
	WriteFileLine(configFile, "\t\t\t\"hour\"\t\t\"6\"");
	WriteFileLine(configFile, "\t\t\t\"minute\"\t\"0\"");
	WriteFileLine(configFile, "\t\t}");
	WriteFileLine(configFile, "\t\t// Example: Friday at 06:30 PM");
	WriteFileLine(configFile, "\t\t\"1\"");
	WriteFileLine(configFile, "\t\t{");
	WriteFileLine(configFile, "\t\t\t\"day\"\t\t\"5\"");
	WriteFileLine(configFile, "\t\t\t\"hour\"\t\t\"18\"");
	WriteFileLine(configFile, "\t\t\t\"minute\"\t\"30\"");
	WriteFileLine(configFile, "\t\t}");
	WriteFileLine(configFile, "\t\t// Example: Sunday at 03:00 AM");
	WriteFileLine(configFile, "\t\t\"2\"");
	WriteFileLine(configFile, "\t\t{");
	WriteFileLine(configFile, "\t\t\t\"day\"\t\t\"7\"");
	WriteFileLine(configFile, "\t\t\t\"hour\"\t\t\"3\"");
	WriteFileLine(configFile, "\t\t\t\"minute\"\t\"0\"");
	WriteFileLine(configFile, "\t\t}");
	WriteFileLine(configFile, "\t}");
	WriteFileLine(configFile, "}");

	delete configFile;
	LogPluginMessage(LogLevel_Info, "Default configuration file created with documentation");
}

// ==========================================
// RESTART SCHEDULER
// ==========================================
int RestartScheduler_CalculateNextRestartTime()
{
	int currentTime = GetTime();
	int nextTime = 0;

	switch (g_Config.mode)
	{
		case RestartMode_Delay:
		{
			nextTime = currentTime + (g_Config.delayMinutes * 60);
		}
		case RestartMode_Scheduled:
		{
			nextTime = RestartScheduler_GetNextScheduledTime();
		}
		case RestartMode_Hybrid:
		{
			int delayTime = currentTime + (g_Config.delayMinutes * 60);
			int scheduledTime = RestartScheduler_GetNextScheduledTime();

			// Use the earliest time
			if (scheduledTime > 0 && scheduledTime < delayTime)
				nextTime = scheduledTime;
			else
				nextTime = delayTime;
		}
	}

	// Check if restart is already overdue
	if (nextTime <= currentTime)
	{
		LogPluginMessage(LogLevel_Warning, "Restart is overdue (scheduled: %d, current: %d) - adjusting to respect minimum interval", nextTime, currentTime);
		nextTime = currentTime + MIN_RESTART_INTERVAL;
	}

	// Apply early restart logic if enabled (for delay-based or hybrid modes)
	if (g_Config.earlyRestart && (g_Config.mode == RestartMode_Delay || g_Config.mode == RestartMode_Hybrid) && RestartScheduler_ShouldEarlyRestart())
	{
		// Calculate early restart as half of the remaining time until the scheduled restart
		int remainingTime = nextTime - currentTime;
		int earlyTime = currentTime + (remainingTime / 2);

		nextTime = earlyTime;
		LogPluginMessage(LogLevel_Info, "Early restart applied: no human players online, restart time reduced by half (%d minutes)", (remainingTime / 60) / 2);
	}

	// Ensure minimum interval from NOW (only for NEW restart calculations, not overdue ones)
	int minimumNextTime = currentTime + MIN_RESTART_INTERVAL;
	if (nextTime < minimumNextTime)
	{
		nextTime = minimumNextTime;
		LogPluginMessage(LogLevel_Warning, "Restart time adjusted to respect minimum interval (%d seconds) from current time", MIN_RESTART_INTERVAL);
	}

	LogPluginMessage(LogLevel_Debug, "Next restart calculated: %d (current: %d, delta: %d minutes)", nextTime, currentTime, (nextTime - currentTime) / 60);

	return nextTime;
}

int RestartScheduler_GetNextScheduledTime()
{
	if (g_ScheduledRestarts == null || g_ScheduledRestarts.Length == 0)
		return 0;

	int currentTime = GetTime();
	int nextTime = 0;
	int recalculatedCount = 0;

	// Single pass: recalculate outdated timestamps and find minimum
	for (int i = 0; i < g_ScheduledRestarts.Length; i++)
	{
		ScheduledRestart restart;
		g_ScheduledRestarts.GetArray(i, restart, sizeof(restart));

		// Update timestamp if it's outdated
		if (restart.timestamp <= currentTime)
		{
			restart.timestamp = ConfigManager_CalculateNextOccurrenceTimestamp(restart);
			g_ScheduledRestarts.SetArray(i, restart, sizeof(restart));
			recalculatedCount++;
		}

		// Find the earliest restart time
		if (nextTime == 0 || restart.timestamp < nextTime)
			nextTime = restart.timestamp;
	}

	if (recalculatedCount > 0)
	{
		LogPluginMessage(LogLevel_Debug, "Recalculated %d outdated scheduled restart timestamp(s)", recalculatedCount);
	}

	return nextTime;
}

bool RestartScheduler_ShouldEarlyRestart()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientConnected(i) && !IsFakeClient(i))
			return false;
	}

	// Only allow early restart if no human players are connected
	return true;
}

bool RestartScheduler_ShouldPostponeRestart()
{
	if (g_Config.maxPlayers < 0)
		return false; // Disabled

	int playerCount = RestartScheduler_GetPlayerCount();
	if (playerCount > g_Config.maxPlayers)
	{
		LogPluginMessage(LogLevel_Info, "Restart postponed: %d players online (max: %d)", playerCount, g_Config.maxPlayers);
		return true;
	}

	return false;
}

int RestartScheduler_GetPlayerCount()
{
	int count = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientConnected(i))
		{
			if (g_Config.countBots || !IsFakeClient(i))
				count++;
		}
	}
	return count;
}

bool RestartScheduler_IsRestartDue()
{
	if (g_State.isPostponed)
		return false;

	if (g_State.nextRestartTime <= 0)
	{
		LogPluginMessage(LogLevel_Warning, "Restart due check skipped: invalid next restart time (%d)", g_State.nextRestartTime);
		return false;
	}

	int currentTime = GetTime();
	return (currentTime >= g_State.nextRestartTime);
}

void RestartScheduler_RestoreStateFromConfig()
{
	if (g_State.nextRestartTime <= 0)
		return;

	g_State.nextMapSet = true;

	int currentTime = GetTime();

	if (g_State.nextMap[0] != '\0')
	{
		if (g_State.nextRestartTime <= currentTime)
			LogPluginMessage(LogLevel_Info, "Restored overdue restart from config: %d on map '%s' (restart remains due)", g_State.nextRestartTime, g_State.nextMap);
		else
			LogPluginMessage(LogLevel_Info, "Restored next restart from config: %d on map '%s'", g_State.nextRestartTime, g_State.nextMap);
	}
	else
	{
		if (g_State.nextRestartTime <= currentTime)
			LogPluginMessage(LogLevel_Info, "Restored overdue restart from config: %d (restart remains due)", g_State.nextRestartTime);
		else
			LogPluginMessage(LogLevel_Info, "Restored next restart from config: %d", g_State.nextRestartTime);
	}
}

void RestartScheduler_ScheduleNextRestart(const char[] nextMap = "")
{
	if (g_State.nextMapSet)
		return;

	if (nextMap[0] != '\0')
	{
		strcopy(g_State.nextMap, sizeof(g_State.nextMap), nextMap);
	}
	else
	{
		char mapName[PLATFORM_MAX_PATH];
		if (GetNextMap(mapName, sizeof(mapName)))
		{
			strcopy(g_State.nextMap, sizeof(g_State.nextMap), mapName);
		}
		else
		{
			GetCurrentMap(mapName, sizeof(mapName));
			strcopy(g_State.nextMap, sizeof(g_State.nextMap), mapName);
			LogPluginMessage(LogLevel_Warning, "No next map set, using current map: %s", mapName);
		}
	}

	// Save to configuration
	g_State.nextRestartTime = RestartScheduler_CalculateNextRestartTime();
	g_State.restarted = false;
	g_State.changed = false;
	PluginState_Save();

	g_State.nextMapSet = true;

	LogPluginMessage(LogLevel_Info, "Next restart scheduled: %d on map '%s'", g_State.nextRestartTime, g_State.nextMap);
}

// ==========================================
// HELPERS
// ==========================================
stock void GetDayName(int day, char[] buffer, int maxlen)
{
	switch (day)
	{
		case 1: strcopy(buffer, maxlen, "Monday");
		case 2: strcopy(buffer, maxlen, "Tuesday");
		case 3: strcopy(buffer, maxlen, "Wednesday");
		case 4: strcopy(buffer, maxlen, "Thursday");
		case 5: strcopy(buffer, maxlen, "Friday");
		case 6: strcopy(buffer, maxlen, "Saturday");
		case 7: strcopy(buffer, maxlen, "Sunday");
		default: strcopy(buffer, maxlen, "Invalid");
	}
}

// ==========================================
// PERSISTENT STATE MANAGEMENT
// ==========================================
bool PluginState_Load()
{
	KeyValues kv = null;
	if (!ConfigManager_GetConfigKeyValues(kv))
		return false;

	if (!kv.JumpToKey(CONFIG_KV_INFO_NAME))
	{
		delete kv;
		return false;
	}

	char buf[32];
	kv.GetString("nextrestart", buf, sizeof(buf), "0");
	g_State.nextRestartTime = StringToInt(buf);

	kv.GetString("nextmap", g_State.nextMap, sizeof(g_State.nextMap), "");

	kv.GetString("restarted", buf, sizeof(buf), "0");
	g_State.restarted = strcmp(buf, "1") == 0;

	kv.GetString("changed", buf, sizeof(buf), "0");
	g_State.changed = strcmp(buf, "1") == 0;

	delete kv;
	return true;
}

bool PluginState_Save()
{
	KeyValues kv = null;
	if (!ConfigManager_GetConfigKeyValues(kv))
		return false;

	if (!kv.JumpToKey(CONFIG_KV_INFO_NAME))
	{
		delete kv;
		return false;
	}

	char buf[32];
	IntToString(g_State.nextRestartTime, buf, sizeof(buf));
	kv.SetString("nextrestart", buf);
	kv.SetString("nextmap", g_State.nextMap);
	kv.SetString("restarted", g_State.restarted ? "1" : "0");
	kv.SetString("changed", g_State.changed ? "1" : "0");

	char sFile[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sFile, sizeof(sFile), CONFIG_PATH);
	kv.Rewind();
	kv.ExportToFile(sFile);

	delete kv;
	return true;
}
