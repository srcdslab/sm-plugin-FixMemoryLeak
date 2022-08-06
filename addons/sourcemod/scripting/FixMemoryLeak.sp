#pragma semicolon 1

#include <nextmap>
#include <multicolors>

#pragma newdecls required

#define CONFIG_PATH				"configs/fixmemoryleak.cfg"
#define	CONFIG_KV_NAME			"server"
#define	CONFIG_KV_INFO_NAME		"info"
#define	CONFIG_KV_RESTART_NAME	"restart"
#define PREFIX_CHAT				"{olive}[FixMemoryLeak]"

public Plugin myinfo =
{
	name = "FixMemoryLeak",
	author = "maxime1907, .Rushaway",
	description = "Fix memory leaks resulting in crashes by restarting the server at a given time.",
	version = "1.2.4"
}

enum struct ConfiguredRestart {
	int iDay;
	int iHour;
	int iMinute;
}

ConVar g_cRestartMode;
ConVar g_cRestartDelay;
ConVar g_cMaxPlayers = null;
ConVar g_cMaxPlayersCountBots = null;

ArrayList g_iConfiguredRestarts = null;

bool g_bDebug = false;

bool g_bRestart = false;

bool g_bPostponeRestart = false;

public void OnPluginStart()
{
	g_cRestartMode = CreateConVar("sm_restart_mode", "2", "2 = Add configured days and sm_restart_delay, 1 = Only configured days, 0 = Only sm_restart_delay.", FCVAR_NOTIFY, true, 0.0, true, 2.0);
	g_cRestartDelay = CreateConVar("sm_restart_delay", "1440", "How much time before a server restart in minutes.", FCVAR_NOTIFY, true, 1.0, true, 100000.0);
	g_cMaxPlayers = CreateConVar("sm_restart_maxplayers", "-1", "How many players should be connected to cancel restart (-1 = Disable)", FCVAR_NOTIFY, true, -1.0, true, float(MAXPLAYERS));
	g_cMaxPlayersCountBots = CreateConVar("sm_restart_maxplayers_count_bots", "0", "Should we count bots for sm_restart_maxplayers (1 = Enabled, 0 = Disabled)", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	AutoExecConfig(true);

	RegAdminCmd("sm_restartsv", Command_RestartServer, ADMFLAG_RCON, "Soft restarts the server to the nextmap.");
	RegAdminCmd("sm_cancelrestart", Command_AdminCancel, ADMFLAG_RCON, "Cancel the soft restart server.");
	RegAdminCmd("sm_svnextrestart", Command_SvNextRestart, ADMFLAG_RCON, "Print time until next restart.");
	RegAdminCmd("sm_reloadrestartcfg", Command_DebugConfig, ADMFLAG_ROOT, "Reloads the configuration.");

	RegServerCmd("changelevel", Hook_OnMapChange);
	RegServerCmd("quit", Hook_OnServerQuit);
	RegServerCmd("_restart", Hook_OnServerRestart);

	HookEvent("round_end", OnRoundEnd, EventHookMode_Pre);
}

public void OnPluginEnd()
{
	UnhookEvent("round_end", OnRoundEnd, EventHookMode_Pre);

	if (g_iConfiguredRestarts != null)
		delete g_iConfiguredRestarts;
}

public void OnMapStart()
{
	g_bRestart = false;

	LoadConfiguredRestarts();

	char sSectionValue[PLATFORM_MAX_PATH];
	if (GetSectionValue(CONFIG_KV_INFO_NAME, "restarted", sSectionValue) && StrEqual(sSectionValue, "1"))
	{
		if (GetSectionValue(CONFIG_KV_INFO_NAME, "changed", sSectionValue))
		{
			if (StrEqual(sSectionValue, "0") && GetSectionValue(CONFIG_KV_INFO_NAME, "nextmap", sSectionValue))
			{
				SetSectionValue(CONFIG_KV_INFO_NAME, "changed", "1");
				ForceChangeLevel(sSectionValue, "FixMemoryLeak");
			}
		}
	}
}

public Action Hook_OnMapChange(int args)
{
	if (IsRestartNeeded() && !g_bPostponeRestart)
	{
		SetupNextRestartNextMap();
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
	if (!g_bRestart)
	{
		SetupNextRestartCurrentMap();
		SoftServerRestart();
		return Plugin_Handled;
	}
	return Plugin_Continue;
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
		CPrintToChat(client, "%s {red}No nextmap have been set, please set one.", PREFIX_CHAT);
		return Plugin_Handled;
	}

	SetupNextRestartCurrentMap();
	ForceChangeLevel(sNextMap, "FixMemoryLeak");

	return Plugin_Handled;
}

public Action Command_SvNextRestart(int client, int argc)
{
	char buffer[768], rTime[768];
	int RemaingTime = GetNextRestartTime() - GetTime();
	FormatTime(buffer, sizeof(buffer), "%A %d %B %G @ %r", GetNextRestartTime());
	FormatTime(rTime, sizeof(rTime), "%X", RemaingTime);
	CPrintToChat(client, "%s {default}Nextrestart will be {green}%s", PREFIX_CHAT, buffer);
	CPrintToChat(client, "%s {default}Remaing time until nextrestart : {green}%s", PREFIX_CHAT, rTime);
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
			CPrintToChat(client, "{red}[Debug] T = Current | {green}C = Configured.");
			PrintConfiguredRestarts(client);
			CPrintToChat(client, "Timeleft until server restart ? Use {green}sm_svnextrestart");
		}
		CPrintToChat(client, "%s {blue}Successfully reloaded the restart config.", PREFIX_CHAT);
	}
	else
		CPrintToChat(client, "%s {red}There was an error reading the config file.", PREFIX_CHAT);

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

	LogMessage("[FixMemoryLeak] %s has %s the server restart!", name, g_bPostponeRestart ? "scheduled" : "canceled");
	CPrintToChatAll("{green}[SM] {olive}%s {default}has %s the server restart!", name, g_bPostponeRestart ? "scheduled" : "canceled");
	g_bPostponeRestart = !g_bPostponeRestart;

	return Plugin_Handled;
}

stock int GetClientCountEx(bool countBots)
{
	int iRealClients = 0;
	int iFakeClients = 0;

	for(int player = 1; player <= MaxClients; player++)
	{
		if(IsClientConnected(player))
		{
			if(IsFakeClient(player))
				iFakeClients++;
			else
				iRealClients++;
		}
	}
	return countBots ? iFakeClients + iRealClients : iRealClients;
}

public Action OnRoundEnd(Handle event, const char[] name, bool dontBroadcast)
{
	int timeleft;
	char sWarningText[256];
	int playersCount = GetClientCountEx(g_cMaxPlayersCountBots.BoolValue);

	if (IsRestartNeeded())
	{
		GetMapTimeLeft(timeleft);

		if (timeleft <= 0)
		{
			if (g_cMaxPlayers.IntValue > -1 && playersCount > g_cMaxPlayers.IntValue)
			{
				g_bPostponeRestart = true;
				LogMessage("{green}[SM] {default}Too many players %d>%d, server restart postponed !", playersCount, g_cMaxPlayers.IntValue);
				CPrintToChatAll("{green}[SM] {default}Too many players %d>%d, server restart postponed !", playersCount, g_cMaxPlayers.IntValue);
				ServerCommand("sm_msay Too many players %d>%d, server restart postponed !", playersCount, g_cMaxPlayers.IntValue);
				ServerCommand("sm_tsay Server restart postponed !");
				return Plugin_Continue;
			}

			if (!g_bPostponeRestart)
			{
				Format(sWarningText, sizeof(sWarningText), "Automatic server restart.\\nRejoin and have fun !");

				if (GetEngineVersion() == Engine_CSGO)
				{
					PrintHintTextToAll("<font class='fontSize-l' color='#ff0000'>[Server]</font> <font class='fontSize-l'>Automatic server restart. Rejoin and have fun !</font>");
					ServerCommand("sm_csay Automatic server restart. Rejoin and have fun !");
					ServerCommand("sm_tsay red Automatic server restart.");
					ServerCommand("sm_msay %s", sWarningText);
					CPrintToChatAll("{darkred}[Server] {gray}Automatic server restart.\n{darkred}[Server] {gray}Rejoin and have fun !");
				}
				else
				{
					PrintHintTextToAll("Automatic server restart. Rejoin and have fun !");
					ServerCommand("sm_csay Automatic server restart. Rejoin and have fun !");
					ServerCommand("sm_tsay red Automatic server restart.");
					ServerCommand("sm_msay %s", sWarningText);
					CPrintToChatAll("{fullred}[Server] {white}Automatic server restart.\n{fullred}[Server] {white}Rejoin and have fun !");
				}
			}
			return Plugin_Continue;
		}

		if (!g_bPostponeRestart)
		{
			if (GetEngineVersion() == Engine_CSGO)
			{
				if (!IsVoteInProgress())
					ServerCommand("sm_msay Automatic server restart at the end of the map.\\nDon't forget to rejoin after the restart!");
				PrintHintTextToAll("<font class='fontSize-l' color='#ff0000'>[Server]</font> <font class='fontSize-l'>Automatic server restart at the end of the map. Don't forget to rejoin after the restart!</font>");
				CPrintToChatAll("{darkred}[Server] {gray}Automatic server restart at the end of the map.\n{darkred}[Server] {gray}Don't forget to rejoin after the restart!");
			}
			else
			{
				PrintHintTextToAll("Automatic server restart at the end of the map.");
				if (!IsVoteInProgress())
					ServerCommand("sm_msay Automatic server restart at the end of the map.\\nDon't forget to rejoin after the restart!");
				CPrintToChatAll("{fullred}[Server] {white}Automatic server restart at the end of the map.\n{fullred}[Server] {white}Don't forget to rejoin after the restart!");
				
			}
		}
	}
	return Plugin_Continue;
}

stock bool IsRestartNeeded()
{
	int currentTime = GetTime();

	char sSectionValue[PLATFORM_MAX_PATH];
	if (GetSectionValue(CONFIG_KV_INFO_NAME, "nextrestart", sSectionValue))
	{
		int restartTime = StringToInt(sSectionValue);
		if (currentTime >= restartTime)
			return true;
	}
	else
		SetupNextRestartNextMap();
	return false;
}

stock void SoftServerRestart()
{
	g_bRestart = true;
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

stock void SetupNextRestartCurrentMap()
{
	char sNextMap[PLATFORM_MAX_PATH];
	GetCurrentMap(sNextMap, sizeof(sNextMap));

	int iNextTime = GetNextRestartTime();

	SetNextRestart(iNextTime, sNextMap);
}

stock void SetupNextRestartNextMap()
{
	char sNextMap[PLATFORM_MAX_PATH];
	GetNextMap(sNextMap, sizeof(sNextMap));

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
	int currentTime = GetTime();
	int iNextTime = 0;

	switch (g_cRestartMode.IntValue)
	{
		case 1:
		{
			iNextTime = GetConfiguredClosestTime();
		}
		case 2:
		{
			int iConfiguredTime = GetConfiguredClosestTime();
			int iDelayTime = currentTime + (g_cRestartDelay.IntValue * 60);
			if (iConfiguredTime > iDelayTime)
				iNextTime = iDelayTime;
			else
				iNextTime = iConfiguredTime;
		}
	}

	if (iNextTime <= 0)
		iNextTime = currentTime + (g_cRestartDelay.IntValue * 60);

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
			SetFailState("[FixMemoryLeak] could not create %s", sFile);
			delete kv;
			return;
		}

		WriteFileLine(hFile, "\"%s\"", CONFIG_KV_NAME);
		WriteFileLine(hFile, "{");

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
		if (StrEqual(sSectionValue, ""))
			continue;

		ConfiguredRestart configuredRestart;
		configuredRestart.iDay = StringToInt(sSectionValue);

		if (configuredRestart.iDay < 1 || configuredRestart.iDay > 7)
			continue;

		kv.GetString("hour", sSectionValue, sizeof(sSectionValue), "");

		if (StrEqual(sSectionValue, ""))
			continue;

		configuredRestart.iHour = StringToInt(sSectionValue);

		if (configuredRestart.iHour < 0 || configuredRestart.iHour > 24)
			continue;

		kv.GetString("minute", sSectionValue, sizeof(sSectionValue), "");
		if (StrEqual(sSectionValue, ""))
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

	if (StrEqual(sSectionValue, ""))
		return false;

	return true;
}
