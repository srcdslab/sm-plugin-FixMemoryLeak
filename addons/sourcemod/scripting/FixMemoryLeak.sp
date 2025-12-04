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
}

enum struct ScheduledRestart
{
	int dayOfWeek;     // 0-6 (Sunday = 0)
	int hour;          // 0-23
	int minute;        // 0-59
	int timestamp;     // Pre-calculated UNIX timestamp
}

enum struct PluginState
{
	bool isRestarting;
	bool isPostponed;
	bool nextMapSet;
	bool commandsExecuted;
	int nextRestartTime;
	char nextMap[PLATFORM_MAX_PATH];
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
ConVar g_Cvar_HostIP, g_Cvar_HostPort;

int g_iServerIP;
int g_iServerPort;

// ==========================================
// PLUGIN INITIALIZATION
// ==========================================
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	g_bLate = late;
	g_State.isRestarting = false;
	g_State.isPostponed = false;
	g_State.nextMapSet = false;
	g_State.commandsExecuted = false;
	g_State.nextRestartTime = 0;
	g_State.nextMap = "";
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

	g_Cvar_HostIP   = FindConVar("hostip");
	g_Cvar_HostPort = FindConVar("hostport");

	g_iServerIP   = g_Cvar_HostIP.IntValue;
	g_iServerPort = g_Cvar_HostPort.IntValue;

	// Register commands
	RegAdminCmd("sm_restartsv", Command_RestartServer, ADMFLAG_RCON, "Force a server restart to the next map");
	RegAdminCmd("sm_cancelrestart", Command_AdminCancel, ADMFLAG_RCON, "Cancel or postpone the scheduled restart");
	RegAdminCmd("sm_svnextrestart", Command_SvNextRestart, ADMFLAG_RCON, "Display time until next scheduled restart");
	RegAdminCmd("sm_reloadrestartcfg", Command_DebugConfig, ADMFLAG_ROOT, "Reload restart configuration from file");
	RegAdminCmd("sm_forcerestartcmds", Command_ForceRestartCommands, ADMFLAG_ROOT, "Force execution of post-restart commands");

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

	// Reset state for new map
	g_State.isRestarting = false;
	g_State.isPostponed = false;
	g_State.nextMapSet = false;

	// Reload scheduled restarts in case configuration changed
	ConfigManager_LoadScheduledRestarts();

	// Check if we just restarted and need to change to the correct map
	char sectionValue[PLATFORM_MAX_PATH];
	if (GetSectionValue(CONFIG_KV_INFO_NAME, "restarted", sectionValue) && strcmp(sectionValue, "1") == 0)
	{
		if (GetSectionValue(CONFIG_KV_INFO_NAME, "changed", sectionValue) && strcmp(sectionValue, "0") == 0 && GetSectionValue(CONFIG_KV_INFO_NAME, "nextmap", sectionValue))
		{
			SetSectionValue(CONFIG_KV_INFO_NAME, "changed", "1");
			DataPack dp = new DataPack();
			dp.WriteString(sectionValue);
			CreateDataTimer(1.0, Timer_ChangeToNextMap, dp, TIMER_FLAG_NO_MAPCHANGE);
			return;
		}
	}

	// Schedule next restart for this map
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
	OnMapStart();
}

#if defined _mapchooser_extended_included_
public void OnSetNextMap(const char[] map)
{
	// In case nextmap get changed anytime
	g_State.nextMapSet = false;
	RestartScheduler_ScheduleNextRestart(map);
}
#endif

public Action Hook_OnMapChange(int args)
{
	LogPluginMessage(LogLevel_Debug, "Map change hook triggered");

	if (RestartScheduler_IsRestartDue() && !RestartScheduler_ShouldPostponeRestart())
	{
		LogPluginMessage(LogLevel_Info, "Initiating scheduled server restart");

		// Schedule next restart for the next map
		char nextMap[PLATFORM_MAX_PATH];
		if (GetNextMap(nextMap, sizeof(nextMap)))
		{
			RestartScheduler_ScheduleNextRestart(nextMap);
		}
		else
		{
			RestartScheduler_ScheduleNextRestart("");
		}

		PerformServerRestart();
		return Plugin_Stop;
	}
	else
	{
		// Clear postponement for next cycle
		g_State.isPostponed = false;
	}

	return Plugin_Continue;
}

public Action Hook_OnServerQuit(int args)
{
	if (g_State.isRestarting)
	{
		LogPluginMessage(LogLevel_Debug, "Server quit during restart process - allowing quit to proceed");
		return Plugin_Continue;
	}

	LogPluginMessage(LogLevel_Info, "Server quit detected - saving restart state");

	// Mark that we're restarting to prevent loops
	g_State.isRestarting = true;

	// Schedule restart for current map
	char currentMap[PLATFORM_MAX_PATH];
	GetCurrentMap(currentMap, sizeof(currentMap));
	RestartScheduler_ScheduleNextRestart(currentMap);

	// Save restart state and reconnect players
	ReconnectPlayers();
	SetSectionValue(CONFIG_KV_INFO_NAME, "restarted", "1");

	// Let the original quit command proceed
	LogPluginMessage(LogLevel_Info, "Restart state saved, allowing server quit to proceed");
	return Plugin_Continue;
}

public Action Hook_OnServerRestart(int args)
{
	if (g_State.isRestarting)
	{
		LogPluginMessage(LogLevel_Debug, "Server restart during restart process - allowing restart to proceed");
		return Plugin_Continue;
	}

	LogPluginMessage(LogLevel_Info, "Server restart command detected - saving restart state");

	// Mark that we're restarting to prevent loops
	g_State.isRestarting = true;

	// Schedule restart for current map
	char currentMap[PLATFORM_MAX_PATH];
	GetCurrentMap(currentMap, sizeof(currentMap));
	RestartScheduler_ScheduleNextRestart(currentMap);

	// Save restart state and reconnect players
	ReconnectPlayers();
	SetSectionValue(CONFIG_KV_INFO_NAME, "restarted", "1");

	// Let the original restart command proceed
	LogPluginMessage(LogLevel_Info, "Restart state saved, allowing server restart to proceed");
	return Plugin_Continue;
}

public Action OnRoundEnd(Handle event, const char[] name, bool dontBroadcast)
{
	LogPluginMessage(LogLevel_Debug, "Round end - checking restart conditions");

	if (!RestartScheduler_IsRestartDue())
	{
		LogPluginMessage(LogLevel_Debug, "Restart not due yet");
		return Plugin_Continue;
	}

	int timeleft;
	GetMapTimeLeft(timeleft);

	// Only show warnings when map is about to end
	if (timeleft > 0)
	{
		// Check if we should show "restart soon" warnings
		if (!g_State.isPostponed && !IsVoteInProgress())
		{
			LogPluginMessage(LogLevel_Debug, "Showing 'restart soon' warnings");
			ServerCommand("sm_msay %t", "Restart Soon Other");
			PrintHintTextToAll("%t", "Restart Soon Other");
			CPrintToChatAll("%t %t", "Alert", "Restart Soon Chat", "Alert");
		}
		return Plugin_Continue;
	}

	// Map has ended - check if restart should be postponed
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
		CPrintToChatAll("%t %t", "Alert", "Restart Start Chat");
	}

	return Plugin_Continue;
}

// ==========================================
// COMMANDS
// ==========================================
public Action Command_RestartServer(int client, int argc)
{
	// Check permissions and get client info
	char clientName[64];
	if (client == 0)
	{
		strcopy(clientName, sizeof(clientName), "Server Console");
	}
	else if (!GetClientName(client, clientName, sizeof(clientName)))
	{
		Format(clientName, sizeof(clientName), "Unknown (ID: %d)", client);
	}

	LogPluginMessage(LogLevel_Info, "Manual restart requested by: %s", clientName);

	char nextMap[PLATFORM_MAX_PATH];
	if (!GetNextMap(nextMap, sizeof(nextMap)))
	{
		CPrintToChat(client, "%t %t", "Prefix", "No Nextmap Set");
		LogPluginMessage(LogLevel_Warning, "Cannot restart server: no next map set");
		return Plugin_Handled;
	}

	// Schedule immediate restart
	g_State.nextRestartTime = GetTime();
	RestartScheduler_ScheduleNextRestart(nextMap);

	// Force the restart
	ForceChangeLevel(nextMap, "FixMemoryLeak");

	LogPluginMessage(LogLevel_Info, "Manual server restart initiated to map: %s", nextMap);
	return Plugin_Handled;
}

public Action Command_SvNextRestart(int client, int argc)
{
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

			// Show scheduled restarts
			if (g_ScheduledRestarts != null && g_ScheduledRestarts.Length > 0)
			{
				CReplyToCommand(client, "%t %t", "Prefix", "Debug Scheduled Restarts", g_ScheduledRestarts.Length);
				for (int i = 0; i < g_ScheduledRestarts.Length; i++)
				{
					ScheduledRestart restart;
					g_ScheduledRestarts.GetArray(i, restart, sizeof(restart));

					char dayName[16];
					switch (restart.dayOfWeek)
					{
						case 0: strcopy(dayName, sizeof(dayName), "Sunday");
						case 1: strcopy(dayName, sizeof(dayName), "Monday");
						case 2: strcopy(dayName, sizeof(dayName), "Tuesday");
						case 3: strcopy(dayName, sizeof(dayName), "Wednesday");
						case 4: strcopy(dayName, sizeof(dayName), "Thursday");
						case 5: strcopy(dayName, sizeof(dayName), "Friday");
						case 6: strcopy(dayName, sizeof(dayName), "Saturday");
					}

					CReplyToCommand(client, "%t  %s %02d:%02d", "Prefix", dayName, restart.hour, restart.minute);
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

	// Toggle postponement state
	g_State.isPostponed = !g_State.isPostponed;

	LogPluginMessage(LogLevel_Info, "%s has %s the server restart", clientName, g_State.isPostponed ? "postponed" : "unpostponed");

	char action[32];
	strcopy(action, sizeof(action), g_State.isPostponed ? "Postponed" : "Unpostponed");

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

public Action Command_ForceRestartCommands(int client, int args)
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

	LogPluginMessage(LogLevel_Info, "Changing to restart map: %s", nextMap);
	ForceChangeLevel(nextMap, "FixMemoryLeak");
	return Plugin_Stop;
}

public void ExecuteServerQuit()
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
	// Security check
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

	// Disconnect players safely
	ReconnectPlayers();

	// Mark restart in configuration
	SetSectionValue(CONFIG_KV_INFO_NAME, "restarted", "1");

	// Schedule the actual quit
	RequestFrame(ExecuteServerQuit);
}

stock void SetSectionValue(const char[] sConfigName, const char[] sSectionName, const char[] sSectionValue)
{
	KeyValues kv = null;
	if (!ConfigManager_GetConfigKeyValues(kv))
		return;

	if (!kv.JumpToKey(sConfigName))
	{
		delete kv;
		return;
	}

	kv.SetString(sSectionName, sSectionValue);

	char sFile[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sFile, sizeof(sFile), CONFIG_PATH);

	kv.Rewind();
	kv.ExportToFile(sFile);

	delete kv;
}

stock bool GetSectionValue(const char[] sConfigName, const char[] sSectionName, char sSectionValue[PLATFORM_MAX_PATH])
{
	KeyValues kv = null;
	if (!ConfigManager_GetConfigKeyValues(kv))
		return false;

	if (!kv.JumpToKey(sConfigName))
	{
		delete kv;
		return false;
	}

	kv.GetString(sSectionName, sSectionValue, sizeof(sSectionValue), "");

	delete kv;

	return (strlen(sSectionValue) > 0);
}

stock void ReconnectPlayers()
{
	static char sAdress[128];
	FormatEx(sAdress, sizeof(sAdress), "%d.%d.%d.%d:%d", g_iServerIP >>> 24 & 255, g_iServerIP >>> 16 & 255, g_iServerIP >>> 8 & 255, g_iServerIP & 255, g_iServerPort);
	LogPluginMessage(LogLevel_Info, "Reconnecting players to address: %s", sAdress);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientConnected(i) && !IsFakeClient(i))
			ClientCommand(i, "redirect %s", sAdress);
	}
}

stock bool LoadCommandsAfterRestart(bool bReload = false)
{
	// Prevent execution if conditions not met
	if (!bReload && (g_State.commandsExecuted || GetEngineTime() > 30.0))
		return false;

	LogPluginMessage(LogLevel_Debug, "Loading post-restart commands (reload: %s)", bReload ? "true" : "false");

	KeyValues kv = null;
	if (!ConfigManager_GetConfigKeyValues(kv))
		return false;

	if (!kv.JumpToKey(CONFIG_KV_COMMANDS_NAME))
	{
		LogPluginMessage(LogLevel_Warning, "No commands section found in configuration");
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
		{
			g_State.commandsExecuted = true;
			LogPluginMessage(LogLevel_Info, "Successfully executed %d post-restart commands", executedCount);
		}
		else
		{
			LogPluginMessage(LogLevel_Warning, "No valid commands found to execute");
		}
	}
	else
	{
		LogPluginMessage(LogLevel_Debug, "No commands configured for execution after restart");
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

	char levelPrefix[16];
	switch (level)
	{
		case LogLevel_Debug:    strcopy(levelPrefix, sizeof(levelPrefix), "[DEBUG]");
		case LogLevel_Info:     strcopy(levelPrefix, sizeof(levelPrefix), "[INFO]");
		case LogLevel_Warning:  strcopy(levelPrefix, sizeof(levelPrefix), "[WARNING]");
		case LogLevel_Error:    strcopy(levelPrefix, sizeof(levelPrefix), "[ERROR]");
	}

	char finalMessage[512];
	Format(finalMessage, sizeof(finalMessage), "[FixMemoryLeak] %s %s", levelPrefix, formattedMessage);

	switch (level)
	{
		case LogLevel_Debug:    LogMessage(finalMessage);
		case LogLevel_Info:     LogMessage(finalMessage);
		case LogLevel_Warning:  LogMessage(finalMessage);
		case LogLevel_Error:    LogError(finalMessage);
	}
}

// ==========================================
// SECURITY MANAGER
// ==========================================
bool PluginConfig_Validate(PluginConfig config)
{
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
	if (restart.dayOfWeek < 0 || restart.dayOfWeek > 6) return false;
	if (restart.hour < 0 || restart.hour > 23) return false;
	if (restart.minute < 0 || restart.minute > 59) return false;
	return true;
}

// ==========================================
// CONFIG MANAGER
// ==========================================
void PluginConfig_Init(PluginConfig config)
{
	config.mode = RestartMode_Hybrid;
	config.delayMinutes = 1440; // 24 hours
	config.maxPlayers = -1;
	config.countBots = false;
	config.earlyRestart = true;
	config.enableSecurity = true;
}

bool ConfigManager_LoadConfiguration()
{
	// Initialize defaults
	PluginConfig_Init(g_Config);

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
		PluginConfig_Init(g_Config);
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
		restart.dayOfWeek = StringToInt(dayStr);
		restart.hour = StringToInt(hourStr);
		restart.minute = StringToInt(minuteStr);

		// Convert config days (1-7, where 7=Sunday) to FormatTime days (0-6, where 0=Sunday)
		if (restart.dayOfWeek == 7)
			restart.dayOfWeek = 0;

		if (Security_ValidateScheduledRestart(restart))
		{
			restart.timestamp = ConfigManager_CalculateScheduledTimestamp(restart);
			g_ScheduledRestarts.PushArray(restart, sizeof(restart));
			loadedCount++;
		}
		else
		{
			LogPluginMessage(LogLevel_Warning, "Invalid scheduled restart configuration: Day=%s, Hour=%s, Minute=%s",
				dayStr, hourStr, minuteStr);
		}

	} while (kv.GotoNextKey());

	delete kv;

	LogPluginMessage(LogLevel_Info, "Loaded %d scheduled restart configurations", loadedCount);
	return (loadedCount > 0);
}

int ConfigManager_CalculateScheduledTimestamp(ScheduledRestart restart)
{
	int currentTime = GetTime();

	// Get current time components
	char timeStr[64];
	FormatTime(timeStr, sizeof(timeStr), "%w %H %M", currentTime);
	char timeParts[3][8];
	ExplodeString(timeStr, " ", timeParts, sizeof(timeParts), sizeof(timeParts[]));

	int currentDay = StringToInt(timeParts[0]);
	int currentHour = StringToInt(timeParts[1]);
	int currentMinute = StringToInt(timeParts[2]);

	// Calculate next occurrence
	int targetTime = currentTime;

	// Adjust to target day
	int dayDiff = restart.dayOfWeek - currentDay;
	if (dayDiff < 0) dayDiff += 7;
	if (dayDiff == 0)
	{
		// Same day - check if time has passed
		if (restart.hour < currentHour || (restart.hour == currentHour && restart.minute <= currentMinute))
			dayDiff = 7; // Next week
	}

	targetTime += dayDiff * 86400; // Add days in seconds

	// Set target time within the day
	FormatTime(timeStr, sizeof(timeStr), "%H %M", targetTime);
	ExplodeString(timeStr, " ", timeParts, sizeof(timeParts), sizeof(timeParts[]));
	int targetHour = StringToInt(timeParts[0]);
	int targetMinute = StringToInt(timeParts[1]);

	targetTime -= targetHour * 3600 + targetMinute * 60; // Remove current time
	targetTime += restart.hour * 3600 + restart.minute * 60; // Add target time

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

	// Write default configuration
	WriteFileLine(configFile, "\"%s\"", CONFIG_KV_NAME);
	WriteFileLine(configFile, "{");
	WriteFileLine(configFile, "\t\"%s\"", CONFIG_KV_COMMANDS_NAME);
	WriteFileLine(configFile, "\t{");
	WriteFileLine(configFile, "\t\t\"cmd\"\t\"\"");
	WriteFileLine(configFile, "\t}");
	WriteFileLine(configFile, "\t\"%s\"", CONFIG_KV_INFO_NAME);
	WriteFileLine(configFile, "\t{");
	WriteFileLine(configFile, "\t\t\"nextrestart\"\t\"\"");
	WriteFileLine(configFile, "\t\t\"nextmap\"\t\"\"");
	WriteFileLine(configFile, "\t\t\"restarted\"\t\"\"");
	WriteFileLine(configFile, "\t\t\"changed\"\t\"\"");
	WriteFileLine(configFile, "\t}");
	WriteFileLine(configFile, "\t\"%s\"", CONFIG_KV_RESTART_NAME);
	WriteFileLine(configFile, "\t{");
	WriteFileLine(configFile, "\t\t\"0\"");
	WriteFileLine(configFile, "\t\t{");
	WriteFileLine(configFile, "\t\t\t\"day\"\t\t\"1\"");
	WriteFileLine(configFile, "\t\t\t\"hour\"\t\t\"6\"");
	WriteFileLine(configFile, "\t\t\t\"minute\"\t\"0\"");
	WriteFileLine(configFile, "\t\t}");
	WriteFileLine(configFile, "\t}");
	WriteFileLine(configFile, "}");

	delete configFile;
	LogPluginMessage(LogLevel_Info, "Default configuration file created");
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

	// Apply early restart logic if enabled (for delay-based or hybrid modes)
	if (g_Config.earlyRestart && (g_Config.mode == RestartMode_Delay || g_Config.mode == RestartMode_Hybrid) && RestartScheduler_ShouldEarlyRestart())
	{
		int earlyTime = currentTime + ((g_Config.delayMinutes * 60) / 2);

		// Safety check: don't allow early restart too soon (minimum 1 hour)
		int minEarlyTime = currentTime + 3600; // 1 hour minimum
		if (earlyTime < minEarlyTime)
			earlyTime = minEarlyTime;

		// Only apply early restart if it would make the restart happen sooner
		if (nextTime > earlyTime)
		{
			nextTime = earlyTime;
			LogPluginMessage(LogLevel_Info, "Early restart applied: no human players online, delay reduced by half (minimum 1 hour)");
		}
	}

	// Ensure minimum interval from NOW
	int minimumNextTime = currentTime + MIN_RESTART_INTERVAL;
	if (nextTime < minimumNextTime)
	{
		nextTime = minimumNextTime;
		LogPluginMessage(LogLevel_Warning, "Restart time adjusted to respect minimum interval from current time");
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

	for (int i = 0; i < g_ScheduledRestarts.Length; i++)
	{
		ScheduledRestart restart;
		g_ScheduledRestarts.GetArray(i, restart, sizeof(restart));

		// Update timestamp if it's outdated
		if (restart.timestamp <= currentTime)
		{
			restart.timestamp = ConfigManager_CalculateScheduledTimestamp(restart);
			g_ScheduledRestarts.SetArray(i, restart, sizeof(restart));
		}

		if (nextTime == 0 || restart.timestamp < nextTime)
			nextTime = restart.timestamp;
	}

	return nextTime;
}

bool RestartScheduler_ShouldEarlyRestart()
{
	// Count human players
	int humanPlayers = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientConnected(i) && !IsFakeClient(i))
		{
			humanPlayers++;
			break;
		}
	}

	// Only allow early restart if no human players are connected
	return (humanPlayers == 0);
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

	int currentTime = GetTime();
	return (currentTime >= g_State.nextRestartTime);
}

void RestartScheduler_ScheduleNextRestart(const char[] nextMap = "")
{
	if (g_State.nextMapSet)
		return;

	g_State.nextRestartTime = RestartScheduler_CalculateNextRestartTime();

	if (nextMap[0] != '\0')
		strcopy(g_State.nextMap, sizeof(g_State.nextMap), nextMap);

	// Save to configuration
	char timeStr[32];
	IntToString(g_State.nextRestartTime, timeStr, sizeof(timeStr));
	SetSectionValue(CONFIG_KV_INFO_NAME, "nextrestart", timeStr);
	SetSectionValue(CONFIG_KV_INFO_NAME, "nextmap", g_State.nextMap);
	SetSectionValue(CONFIG_KV_INFO_NAME, "restarted", "0");
	SetSectionValue(CONFIG_KV_INFO_NAME, "changed", "0");

	g_State.nextMapSet = true;

	LogPluginMessage(LogLevel_Info, "Next restart scheduled: %d on map '%s'", g_State.nextRestartTime, g_State.nextMap);
}
