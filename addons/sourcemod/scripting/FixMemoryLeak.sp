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

public Plugin myinfo =
{
	name = "FixMemoryLeak",
	author = "maxime1907, .Rushaway",
	description = "Fix memory leaks resulting in crashes by restarting the server at a given time.",
	version = "1.4.0",
	url = "https://github.com/srcdslab"
}

enum struct ConfiguredRestart
{
	int iDay;
	int iHour;
	int iMinute;
}

ConVar g_cRestartMode, g_cRestartDelay;
ConVar g_cMaxPlayers, g_cMaxPlayersCountBots;
ConVar g_cvEarlySvRestart;

ArrayList g_iConfiguredRestarts = null;

bool g_bLate = false;
bool g_bDebug = false;
bool g_bRestart = false;
bool g_bPostponeRestart = false;
bool g_bCountBots = false;
bool g_bNextMapSet = false;
bool g_bEarlyRestart = false;
static bool g_bCmdsAlreadyExecuted = false;

int g_iMode;
int g_iDelay;
int g_iMaxPlayers;

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	g_bLate = late;
	return APLRes_Success;
}

public void OnPluginStart()
{
	// Load translations
	LoadTranslations("FixMemoryLeak.phrases");

	// Initalize cvars
	g_cRestartMode = CreateConVar("sm_restart_mode", "2", "2 = Add configured days and sm_restart_delay, 1 = Only configured days, 0 = Only sm_restart_delay.", FCVAR_NOTIFY, true, 0.0, true, 2.0);
	g_cRestartDelay = CreateConVar("sm_restart_delay", "1440", "How much time before a server restart in minutes.", FCVAR_NOTIFY, true, 1.0, true, 100000.0);
	g_cMaxPlayers = CreateConVar("sm_restart_maxplayers", "-1", "How many players should be connected to cancel restart (-1 = Disable)", FCVAR_NOTIFY, true, -1.0, true, float(MAXPLAYERS));
	g_cMaxPlayersCountBots = CreateConVar("sm_restart_maxplayers_count_bots", "0", "Should we count bots for sm_restart_maxplayers (1 = Enabled, 0 = Disabled)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvEarlySvRestart = CreateConVar("sm_fixmemoryleak_early_restart", "1", "Early restart if no players are connected. (sm_restart_delay / 2)", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	// Hook CVARs
	HookConVarChange(g_cRestartMode, OnCvarChanged);
	HookConVarChange(g_cRestartDelay, OnCvarChanged);
	HookConVarChange(g_cMaxPlayers, OnCvarChanged);
	HookConVarChange(g_cMaxPlayersCountBots, OnCvarChanged);
	HookConVarChange(g_cvEarlySvRestart, OnCvarChanged);

	// Initialize values
	g_iMode = g_cRestartMode.IntValue;
	g_iDelay = g_cRestartDelay.IntValue;
	g_iMaxPlayers = g_cMaxPlayers.IntValue;
	g_bCountBots = g_cMaxPlayersCountBots.BoolValue;
	g_bEarlyRestart = g_cvEarlySvRestart.BoolValue;

	AutoExecConfig(true);

	RegAdminCmd("sm_restartsv", Command_RestartServer, ADMFLAG_RCON, "Soft restarts the server to the nextmap.");
	RegAdminCmd("sm_cancelrestart", Command_AdminCancel, ADMFLAG_RCON, "Cancel the soft restart server.");
	RegAdminCmd("sm_svnextrestart", Command_SvNextRestart, ADMFLAG_RCON, "Print time until next restart.");
	RegAdminCmd("sm_reloadrestartcfg", Command_DebugConfig, ADMFLAG_ROOT, "Reloads the configuration.");
	RegAdminCmd("sm_forcerestartcmds", Command_ForceRestartCommands, ADMFLAG_ROOT, "Force execution of post-restart commands.");

	RegServerCmd("changelevel", Hook_OnMapChange);
	RegServerCmd("quit", Hook_OnServerQuit);
	RegServerCmd("_restart", Hook_OnServerRestart);

	HookEvent("round_end", OnRoundEnd, EventHookMode_Pre);

	LoadCommandsAfterRestart(false);
}

public void OnPluginEnd()
{
	UnhookEvent("round_end", OnRoundEnd, EventHookMode_Pre);

	if (g_iConfiguredRestarts != null)
		delete g_iConfiguredRestarts;
}

public void OnCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (convar == g_cRestartMode)
		g_iMode = g_cRestartMode.IntValue;
	else if (convar == g_cRestartDelay)
		g_iDelay = g_cRestartDelay.IntValue;
	else if (convar == g_cMaxPlayers)
		g_iMaxPlayers = g_cMaxPlayers.IntValue;
	else if (convar == g_cMaxPlayersCountBots)
		g_bCountBots = g_cMaxPlayersCountBots.BoolValue;
	else if (convar == g_cvEarlySvRestart)
		g_bEarlyRestart = g_cvEarlySvRestart.BoolValue;

	// Convar get changed, we need to check if we need to update the next restart time
	OnMapStart();
}

public void OnMapStart()
{
	g_bRestart = false;
	g_bNextMapSet = false;

	LoadConfiguredRestarts();

	char sSectionValue[PLATFORM_MAX_PATH];
	if (GetSectionValue(CONFIG_KV_INFO_NAME, "restarted", sSectionValue) && strcmp(sSectionValue, "1") == 0)
	{
		if (GetSectionValue(CONFIG_KV_INFO_NAME, "changed", sSectionValue))
		{
			if (strcmp(sSectionValue, "0") == 0 && GetSectionValue(CONFIG_KV_INFO_NAME, "nextmap", sSectionValue))
			{
				SetSectionValue(CONFIG_KV_INFO_NAME, "changed", "1");
				ForceChangeLevel(sSectionValue, "FixMemoryLeak");
			}
		}
	}
}

stock bool LoadCommandsAfterRestart(bool bReload = false)
{
	if (!bReload && (g_bLate || g_bCmdsAlreadyExecuted || GetEngineTime() > 30.0))
		return false;

	// This function will search in the kv file the section "commands" and execute each command
	// Example:
	// "commands"
	// {
	// 	"cmd"		"sm exts load CSSFixes"
	// 	"cmd"		"sm plugins reload adminmenu"
	// }

	KeyValues kv;
	GetConfigKv(kv);
	if (!kv.JumpToKey(CONFIG_KV_COMMANDS_NAME))
	{
		delete kv;
		return false;
	}

	if (kv.GotoFirstSubKey(false))
	{
		g_bCmdsAlreadyExecuted = true;
		char sCommand[PLATFORM_MAX_PATH];

		do
		{
			kv.GetString(NULL_STRING, sCommand, sizeof(sCommand));
			if (sCommand[0] != '\0')
			{
				LogMessage("Executing command: %s", sCommand);
				ServerCommand(sCommand);
			}
		} while (kv.GotoNextKey(false));

		kv.GoBack();
	}
	else
	{
		LogError("No commands found in the config file.");
		delete kv;
		return false;
	}

	delete kv;
	return true;
}

#if defined _mapchooser_extended_included_
public void OnSetNextMap(const char[] map)
{
	// In case nextmap get changed anytime
	g_bNextMapSet = false;
	SetupNextRestartNextMap(map);
}
#endif

public Action Hook_OnMapChange(int args)
{
	if (IsRestartNeeded() && !g_bPostponeRestart)
	{
		SetupNextRestartNextMap("");
		SoftServerRestart();
		return Plugin_Stop;
	}
	else
	{
		g_bPostponeRestart = false;
	}

	return Plugin_Continue;
}

public Action Hook_OnServerQuit(int args)
{
	if (g_bRestart)
		return Plugin_Continue;

	SetupNextRestartCurrentMap();
	SoftServerRestart();
	return Plugin_Handled;
}

public Action Hook_OnServerRestart(int args)
{
	SetupNextRestartCurrentMap();
	SoftServerRestart();
	return Plugin_Handled;
}

public Action Command_RestartServer(int client, int argc)
{
	char sNextMap[PLATFORM_MAX_PATH];
	if (!GetNextMap(sNextMap, sizeof(sNextMap)))
	{
		CPrintToChat(client, "%t %t", "Prefix", "No Nextmap Set");
		return Plugin_Handled;
	}

	SetupNextRestartCurrentMap(true);
	ForceChangeLevel(sNextMap, "FixMemoryLeak");

	return Plugin_Handled;
}

public Action Command_SvNextRestart(int client, int argc)
{
	switch (g_iMode)
	{
		case 0:
		{
			int iUptime = CalculateUptime();
			int iMinsUntilRestart = (iUptime + g_iDelay) - iUptime;
			int iHours = iMinsUntilRestart / 60;
			int iDays = iHours / 24;
			iHours = iHours % 24;

			CReplyToCommand(client, "%t %t", "Prefix", "Next Restart", iDays, iHours, iMinsUntilRestart % 60);
		}
		case 1,2:
		{
			char buffer[768], rTime[768];
			int RemaingTime = GetNextRestartTime() - GetTime();
			FormatTime(buffer, sizeof(buffer), "%A %d %B %G @ %r", GetNextRestartTime());
			FormatTime(rTime, sizeof(rTime), "%X", RemaingTime);

			CReplyToCommand(client, "%t %t", "Prefix", "Next Restart Time", buffer);
			CReplyToCommand(client, "%t %t", "Prefix", "Remaining Time", rTime);
		}
	}
	return Plugin_Handled;
}

public Action Command_DebugConfig(int client, int argc)
{
	if (argc >= 1)
		g_bDebug = true;

	if (LoadConfiguredRestarts())
	{
		if (g_bDebug)
		{
			CReplyToCommand(client, "{red}[Debug] T = Current | {green}C = Configured.");
			PrintConfiguredRestarts(client);
			CReplyToCommand(client, "Timeleft until server restart ? Use {green}sm_svnextrestart");
		}

		CReplyToCommand(client, "%t %t", "Prefix", "Reload Config Success");
	}
	else
	{
		CReplyToCommand(client, "%t %t", "Prefix", "Reload Config Error");
	}
	g_bDebug = false;
	return Plugin_Handled;
}

public Action Command_AdminCancel(int client, int argc)
{
	char name[64];

	if (client == 0)
		name = "The server";
	else if (!GetClientName(client, name, sizeof(name)))
		Format(name, sizeof(name), "Disconnected (uid:%d)", client);

	LogMessage("%s has %s the server restart!", name, g_bPostponeRestart ? "scheduled" : "canceled");
	CPrintToChatAll("%t %t", "Prefix", "Server Restart", name, g_bPostponeRestart ? "Scheduled" : "Canceled");
	g_bPostponeRestart = !g_bPostponeRestart;

	return Plugin_Handled;
}

public Action Command_ForceRestartCommands(int client, int args)
{
	g_bCmdsAlreadyExecuted = false;
	bool success = LoadCommandsAfterRestart(true);
	g_bCmdsAlreadyExecuted = true;

	if (success)
		CReplyToCommand(client, "%t %t", "Prefix", "Reload Config Success");
	else
		CReplyToCommand(client, "%t %t", "Prefix", "Reload Config Error");
	return Plugin_Handled;
}

stock int GetClientCountEx(bool countBots)
{
	int iRealClients = 0;
	int iFakeClients = 0;

	for (int player = 1; player <= MaxClients; player++)
	{
		if (IsClientConnected(player))
		{
			if (IsFakeClient(player))
				iFakeClients++;
			else
				iRealClients++;
		}
	}
	return countBots ? iFakeClients + iRealClients : iRealClients;
}

public Action OnRoundEnd(Handle event, const char[] name, bool dontBroadcast)
{
	if (!IsRestartNeeded())
		return Plugin_Continue;

	int timeleft;
	int playersCount = GetClientCountEx(g_bCountBots);

	GetMapTimeLeft(timeleft);

	if (timeleft <= 0)
	{
		if (g_iMaxPlayers > -1 && playersCount > g_iMaxPlayers)
		{
			g_bPostponeRestart = true;
			LogMessage("Server restart postponed! (Too many players: %d>%d)", playersCount, g_iMaxPlayers);
			CPrintToChatAll("%t %t", "Prefix", "Restart Postponed Chat", playersCount, g_iMaxPlayers);
			PrintHintTextToAll("%t", "Restart Postponed Other", playersCount, g_iMaxPlayers);
			ServerCommand("sm_msay %t", "Restart Postponed Other", playersCount, g_iMaxPlayers);
			ServerCommand("sm_csay %t", "Restart Postponed Other", playersCount, g_iMaxPlayers);
			return Plugin_Continue;
		}

		if (!g_bPostponeRestart)
		{
			ServerCommand("sm_csay %t", "Restart Start Other");
			ServerCommand("sm_msay %t", "Restart Start Other");

			PrintHintTextToAll("%t", "Restart Start Other");
			CPrintToChatAll("%t %t", "Alert", "Restart Start Chat", "Alert");
		}
		return Plugin_Continue;
	}

	if (!g_bPostponeRestart)
	{
		if (!IsVoteInProgress())
			ServerCommand("sm_msay %t", "Restart Soon Other");

		PrintHintTextToAll("%t", "Restart Soon Other");
		CPrintToChatAll("%t %t", "Alert", "Restart Soon Chat", "Alert");
	}
	return Plugin_Continue;
}

stock bool IsRestartNeeded()
{
	bool bHasPlayers = false;
	int currentTime = GetTime();
	int iTime = g_iDelay;

	if (g_bEarlyRestart)
	{
		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsClientConnected(i) && !IsFakeClient(i))
			{
				bHasPlayers = true;
				break;
			}
		}
	}

	switch (g_iMode)
	{
		case 0:
		{
			int iUptime = CalculateUptime();
			if (g_bEarlyRestart && !bHasPlayers)
				iTime = iTime / 2;

			return iUptime >= iTime;
		}
		case 1,2:
		{
			char sSectionValue[PLATFORM_MAX_PATH];
			if (GetSectionValue(CONFIG_KV_INFO_NAME, "nextrestart", sSectionValue))
			{
				iTime = StringToInt(sSectionValue);
				if (g_bEarlyRestart && !bHasPlayers)
					iTime = iTime / 2;

				return currentTime >= iTime;
			}
			else
			{
				SetupNextRestartNextMap("");
			}
		}
	}

	return false;
}

stock void SoftServerRestart()
{
	g_bRestart = true;
	int iNextTime = GetNextRestartTime();

	char sNextTime[64];
	IntToString(iNextTime, sNextTime, sizeof(sNextTime));

	// We need to set the next restart time before restarting the server to prevent infinite loop
	// This value will be updated later in SetNextRestart()
	SetSectionValue(CONFIG_KV_INFO_NAME, "nextrestart", sNextTime);
	SetSectionValue(CONFIG_KV_INFO_NAME, "restarted", "1");
	ReconnectPlayers();
	RequestFrame(RestartServer);
}

stock void ReconnectPlayers()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientConnected(i) && !IsFakeClient(i))
			ClientCommand(i, "retry");
	}
}

public void RestartServer()
{
	ServerCommand("quit");
	// InsertServerCommand("quit");
	// ServerExecute();
}

stock void SetupNextRestartCurrentMap(bool bForce = false)
{
	char sNextMap[PLATFORM_MAX_PATH];
	GetCurrentMap(sNextMap, sizeof(sNextMap));

	int iNextTime;
	if (bForce)
		iNextTime = GetTime();
	else
		iNextTime = GetNextRestartTime();

	SetNextRestart(iNextTime, sNextMap);
}

stock void SetupNextRestartNextMap(const char[] map)
{
	// Nextmap is already set, no need to continue
	if (g_bNextMapSet)
		return;

	PrintToServer("[FixMemoryLeak] Setting nextmap..");

	char sNextMap[PLATFORM_MAX_PATH];
	FormatEx(sNextMap, sizeof(sNextMap), map);

	if (!sNextMap[0])
	{
		if (!GetNextMap(sNextMap, sizeof(sNextMap)))
		{
			LogMessage("Could not get the nextmap. Attempting to get nextmap via convar.");
			ConVar cvar = FindConVar("sm_nextmap");
			if (cvar != INVALID_HANDLE)
				GetConVarString(cvar, sNextMap, sizeof(sNextMap));
		}

		// Final check: Is the nextmap still empty?
		if (!sNextMap[0])
		{
			LogError("Could not find the nextmap.. Fallback on the currentmap.");
			SetupNextRestartCurrentMap();
			return;
		}
	}

	int iNextTime = GetNextRestartTime();
	SetNextRestart(iNextTime, sNextMap);
}

stock void SetNextRestart(int iNextTime, char sNextMap[PLATFORM_MAX_PATH])
{
	char sNextTime[64];
	IntToString(iNextTime, sNextTime, sizeof(sNextTime));

	SetSectionValue(CONFIG_KV_INFO_NAME, "nextrestart", sNextTime);
	SetSectionValue(CONFIG_KV_INFO_NAME, "nextmap", sNextMap);
	SetSectionValue(CONFIG_KV_INFO_NAME, "restarted", "0");
	SetSectionValue(CONFIG_KV_INFO_NAME, "changed", "0");

	LogMessage("Next restart set at %s on %s", sNextTime, sNextMap);
	g_bNextMapSet = true;
}

stock int GetConfiguredRestartTime(ConfiguredRestart configuredRestart)
{
	int iCurrentTime = GetTime();

	char sBuffer[10];
	FormatTime(sBuffer, sizeof(sBuffer), "%u", iCurrentTime);
	int iCurrentDay = StringToInt(sBuffer);

	int iDiff;
	if (iCurrentDay > configuredRestart.iDay)
		iDiff = (7 - iCurrentDay) + configuredRestart.iDay;
	else
		iDiff = configuredRestart.iDay - iCurrentDay;

	int iTime = iCurrentTime;
	iTime += iDiff * (24*60*60);

	FormatTime(sBuffer, sizeof(sBuffer), "%H", iTime);
	int iCurrentHour = StringToInt(sBuffer);

	FormatTime(sBuffer, sizeof(sBuffer), "%M", iTime);
	int iCurrentMinute = StringToInt(sBuffer);

	iTime -= iCurrentHour * (60*60);
	iTime -= iCurrentMinute * (60);

	iTime += configuredRestart.iHour * (60*60);
	iTime += configuredRestart.iMinute * (60);

	if (iTime <= iCurrentTime)
		iTime += 7 * (24*60*60);

	return iTime;
}

stock int GetConfiguredClosestTime()
{
	int iNextTime = 0;

	if (g_iConfiguredRestarts == null)
		return iNextTime;

	for (int i = 0; i < g_iConfiguredRestarts.Length; i++)
	{
		ConfiguredRestart configuredRestart;
		g_iConfiguredRestarts.GetArray(i, configuredRestart, sizeof(configuredRestart));

		int iConfiguredRestartTime = GetConfiguredRestartTime(configuredRestart);

		if (g_bDebug)
			CPrintToChatAll("Timestamp => %d", iConfiguredRestartTime);

		if (i == 0)
		{
			iNextTime = iConfiguredRestartTime;
			continue;
		}

		if (iConfiguredRestartTime < iNextTime)
			iNextTime = iConfiguredRestartTime;
	}

	return iNextTime;
}

stock int GetNextRestartTime()
{
	int iNextTime = 0;
	int currentTime = GetTime();
	int iDelayTime = currentTime + (g_iDelay * 60);

	switch (g_iMode)
	{
		case 0:
		{
			iNextTime = iDelayTime;
		}
		case 1:
		{
			iNextTime = GetConfiguredClosestTime();
		}
		case 2:
		{
			int iConfiguredTime = GetConfiguredClosestTime();
			if (iConfiguredTime > iDelayTime)
				iNextTime = iDelayTime;
			else
				iNextTime = iConfiguredTime;
		}
	}

	if (iNextTime <= 0)
		iNextTime = iDelayTime;

	return iNextTime;
}

stock void GetConfigKv(KeyValues &kv, const char[] sConfigPath = CONFIG_PATH, const char[] sKvName = CONFIG_KV_NAME)
{
	kv = new KeyValues(sKvName);

	char sFile[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sFile, sizeof(sFile), sConfigPath);

	if (!FileExists(sFile))
	{
		Handle hFile = OpenFile(sFile, "w");

		if (hFile == INVALID_HANDLE)
		{
			SetFailState("Could not create %s", sFile);
			delete kv;
			return;
		}

		WriteFileLine(hFile, "\"%s\"", CONFIG_KV_NAME);
		WriteFileLine(hFile, "{");

		WriteFileLine(hFile, "\t\"%s\"", CONFIG_KV_COMMANDS_NAME);
		WriteFileLine(hFile, "\t{");
		WriteFileLine(hFile, "\t\t\"cmd\"\t\"\"");
		WriteFileLine(hFile, "\t\t\"cmd\"\t\"\"");
		WriteFileLine(hFile, "\t}");

		WriteFileLine(hFile, "\t\"%s\"", CONFIG_KV_INFO_NAME);
		WriteFileLine(hFile, "\t{");
		WriteFileLine(hFile, "\t\t\"nextrestart\"\t\"\"");
		WriteFileLine(hFile, "\t\t\"nextmap\"\t\"\"");
		WriteFileLine(hFile, "\t\t\"restarted\"\t\"\"");
		WriteFileLine(hFile, "\t\t\"changed\"\t\"\"");
		WriteFileLine(hFile, "\t}");

		WriteFileLine(hFile, "\t\"%s\"", CONFIG_KV_RESTART_NAME);
		WriteFileLine(hFile, "\t{");
		WriteFileLine(hFile, "\t\t\"%s\"", "0");
		WriteFileLine(hFile, "\t\t{");
		WriteFileLine(hFile, "\t\t\t\"day\"\t\t\"\"");
		WriteFileLine(hFile, "\t\t\t\"hour\"\t\t\"\"");
		WriteFileLine(hFile, "\t\t\t\"minute\"\t\"\"");
		WriteFileLine(hFile, "\t\t}");
		WriteFileLine(hFile, "\t}");

		WriteFileLine(hFile, "}");

		CloseHandle(hFile);
	}

	kv.ImportFromFile(sFile);
}

stock void PrintConfiguredRestarts(int client)
{
	if (g_iConfiguredRestarts == null)
		return;

	int currentTime = GetTime();

	char sBuffer[10];
	FormatTime(sBuffer, sizeof(sBuffer), "%u", currentTime);
	int iCurrentDay = StringToInt(sBuffer);

	FormatTime(sBuffer, sizeof(sBuffer), "%H", currentTime);
	int iCurrentHour = StringToInt(sBuffer);

	FormatTime(sBuffer, sizeof(sBuffer), "%M", currentTime);
	int iCurrentMinute = StringToInt(sBuffer);

	for (int i = 0; i < g_iConfiguredRestarts.Length; i++)
	{
		ConfiguredRestart configuredRestart;

		g_iConfiguredRestarts.GetArray(i, configuredRestart, sizeof(configuredRestart));

		CPrintToChat(client, "{red}[Debug] {blue}Day : {default}T %d. {green}C %d {default}| {blue}Hour : {default}T %d. {green}C %d {default}| {blue}Minute : {default}T %d. {green}C %d", iCurrentDay, configuredRestart.iDay, iCurrentHour, configuredRestart.iHour, iCurrentMinute, configuredRestart.iMinute);
	}
}

stock bool LoadConfiguredRestarts(bool bReload = true)
{
	KeyValues kv;
	GetConfigKv(kv);

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

	if (bReload && g_iConfiguredRestarts != null)
		delete g_iConfiguredRestarts;

	if (g_iConfiguredRestarts == null)
		g_iConfiguredRestarts = new ArrayList(sizeof(ConfiguredRestart));

	do
	{
		char sSectionValue[10];
		kv.GetString("day", sSectionValue, sizeof(sSectionValue), "");
		if (strcmp(sSectionValue, "") == 0)
			continue;

		ConfiguredRestart configuredRestart;
		configuredRestart.iDay = StringToInt(sSectionValue);

		if (configuredRestart.iDay < 1 || configuredRestart.iDay > 7)
			continue;

		kv.GetString("hour", sSectionValue, sizeof(sSectionValue), "");

		if (strcmp(sSectionValue, "") == 0)
			continue;

		configuredRestart.iHour = StringToInt(sSectionValue);

		if (configuredRestart.iHour < 0 || configuredRestart.iHour > 24)
			continue;

		kv.GetString("minute", sSectionValue, sizeof(sSectionValue), "");
		if (strcmp(sSectionValue, "") == 0)
			continue;

		configuredRestart.iMinute = StringToInt(sSectionValue);

		if (configuredRestart.iMinute < 0 || configuredRestart.iMinute > 59)
			continue;

		g_iConfiguredRestarts.PushArray(configuredRestart, sizeof(configuredRestart));

	} while(kv.GotoNextKey());

	delete kv;

	return true;
}

stock void SetSectionValue(const char[] sConfigName, const char[] sSectionName, const char[] sSectionValue)
{
	KeyValues kv;
	GetConfigKv(kv);

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
	KeyValues kv;
	GetConfigKv(kv);

	if (!kv.JumpToKey(sConfigName))
	{
		delete kv;
		return false;
	}

	kv.GetString(sSectionName, sSectionValue, sizeof(sSectionValue), "");

	delete kv;

	if (strcmp(sSectionValue, "") == 0)
		return false;

	return true;
}

stock int CalculateUptime()
{
	int ServerUpTime = RoundToFloor(GetEngineTime());
	int Days = ServerUpTime / 60 / 60 / 24;
	int Hours = (ServerUpTime / 60 / 60) % 24;
	int Mins = (ServerUpTime / 60) % 60;
	int Total = (Days * 24 * 60) + (Hours * 60) + Mins;

	return Total;
}
