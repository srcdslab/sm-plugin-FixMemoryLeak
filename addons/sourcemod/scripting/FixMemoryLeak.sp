#pragma semicolon 1

#include <nextmap>
#include <multicolors>

#pragma newdecls required

#define CONFIG_PATH				"configs/fixmemoryleak.cfg"
#define	CONFIG_KV_NAME			"server"
#define	CONFIG_KV_INFO_NAME		"info"
#define	CONFIG_KV_RESTART_NAME	"restart"

public Plugin myinfo =
{
	name = "FixMemoryLeak",
	author = "maxime1907",
	description = "Fix memory leaks resulting in crashes by restarting the server at a given time.",
	version = "1.0"
}

enum struct ConfiguredRestart {
	int iDay;
	int iHour;
	int iMinute;
}

ConVar g_cRestartMode;
ConVar g_cRestartDelay;

ArrayList g_iConfiguredRestarts = null;

bool g_bDebug = false;

bool g_bRestart = false;

public void OnPluginStart()
{
	g_cRestartMode = CreateConVar("sm_restart_mode", "2", "2 = Add configured days and sm_restart_delay, 1 = Only configured days, 0 = Only sm_restart_delay.", FCVAR_NOTIFY, true, 0.0, true, 2.0);

	g_cRestartDelay = CreateConVar("sm_restart_delay", "1440", "How much time before a server restart in minutes.", FCVAR_NOTIFY, true, 60.0, true, 100000.0);

	AutoExecConfig(true);

	RegAdminCmd("sm_restartsv", Command_RestartServer, ADMFLAG_RCON, "Soft restarts the server to the nextmap.");
	RegAdminCmd("sm_reloadrestartcfg", Command_DebugConfig, ADMFLAG_RCON, "Reloads the configuration.");

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
	if (IsRestartNeeded())
	{
		SetupNextRestartNextMap();
		SoftServerRestart();
		return Plugin_Stop;
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
		CPrintToChat(client, "{green}[FixMemoryLeak] No nextmap have been set, please set one.");
		return Plugin_Handled;
	}

	SetupNextRestartCurrentMap();
	ForceChangeLevel(sNextMap, "FixMemoryLeak");

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
			PrintConfiguredRestarts();
			CPrintToChatAll("Nextrestart => %d", GetNextRestartTime());
		}
		CPrintToChat(client, "{green}[FixMemoryLeak] {white}Successfully reloaded the restart config.");
	}
	else
		CPrintToChat(client, "{green}[FixMemoryLeak] {white}There was an error reading the config file.");

	g_bDebug = false;
	return Plugin_Handled;
}

public Action OnRoundEnd(Handle event, const char[] name, bool dontBroadcast)
{
	int timeleft;

	if (IsRestartNeeded())
	{
		GetMapTimeLeft(timeleft);
		if (timeleft <= 0)
		{
			char sWarningText[256];

			Format(sWarningText, sizeof(sWarningText), "Automatic server restart.\\nRejoin and have fun !");
			ServerCommand("sm_msay %s", sWarningText);

			CPrintToChatAll("{fullred}[Server] {white}Automatic server restart.\n{fullred}[Server] {white}Rejoin and have fun !");
		}
		else
		{
			ServerCommand("sm_msay Automatic server restart at the end of the map.\\nDon't forget to rejoin after the restart!");
			CPrintToChatAll("{fullred}[Server] {white}Automatic server restart at the end of the map.\n{fullred}[Server] {white}Don't forget to rejoin after the restart!");
		}
	}
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

stock void PrintConfiguredRestarts()
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

		PrintToChatAll("Day => T %d, C %d", iCurrentDay, configuredRestart.iDay);
		PrintToChatAll("Hour => T %d, C %d", iCurrentHour, configuredRestart.iHour);
		PrintToChatAll("Minute => T %d, C %d", iCurrentMinute, configuredRestart.iMinute);
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
