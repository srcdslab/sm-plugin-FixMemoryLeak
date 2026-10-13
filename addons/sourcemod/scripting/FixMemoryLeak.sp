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
	version = "1.5.0",
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
ConVar g_cMinUptime, g_cCooldown;
ConVar g_cWarnClose, g_cWarnInterval, g_cWarnCloseInterval;

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
int g_iMinUptime;
int g_iCooldown;
int g_iWarnClose;
int g_iWarnInterval;
int g_iWarnCloseInterval;

// Runtime restart state, cached in memory and mirrored to the "info" section of
// CONFIG_PATH. Reads never hit disk; writes go through WriteRuntimeState() which is
// atomic (temp file + validated reimport + rename).
int g_iNextRestartTime = 0;
char g_sNextRestartMap[PLATFORM_MAX_PATH] = "";
bool g_bStateRestarted = false;
bool g_bStateChanged = false;
int g_iLastRestartTime = 0;

// Countdown warning bookkeeping (in-memory only, reset whenever the restart target
// time changes via SetNextRestart()).
float g_flLastWarnTime = 0.0;

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
	g_cMinUptime = CreateConVar("sm_restart_min_uptime", "10", "Safety floor: an automatic restart may never be scheduled less than this many minutes from now, regardless of mode/schedule.", FCVAR_NOTIFY, true, 0.0, true, 1440.0);
	g_cCooldown = CreateConVar("sm_restart_cooldown", "10", "Safety floor: minimum minutes between two automatic restarts. Guarantees the plugin can never restart on every map in a row, even if the schedule/state is wrong. 0 = disabled.", FCVAR_NOTIFY, true, 0.0, true, 1440.0);
	g_cWarnClose = CreateConVar("sm_restart_warn_close", "15", "Below this many minutes remaining, countdown announcements switch to the (short) sm_restart_warn_close_interval spacing instead of sm_restart_warn_interval, so they show up on effectively every map.", FCVAR_NOTIFY, true, 0.0, true, 1440.0);
	g_cWarnInterval = CreateConVar("sm_restart_warn_interval", "600", "Minimum seconds between two countdown announcements ('restart in N minutes') while more than sm_restart_warn_close minutes remain. Keeps far-out warnings from firing on every single map.", FCVAR_NOTIFY, true, 0.0, true, 21600.0);
	g_cWarnCloseInterval = CreateConVar("sm_restart_warn_close_interval", "60", "Minimum seconds between two countdown announcements while inside the sm_restart_warn_close window. Kept short so it still fires on effectively every map.", FCVAR_NOTIFY, true, 0.0, true, 3600.0);

	// Hook CVARs
	HookConVarChange(g_cRestartMode, OnCvarChanged);
	HookConVarChange(g_cRestartDelay, OnCvarChanged);
	HookConVarChange(g_cMaxPlayers, OnCvarChanged);
	HookConVarChange(g_cMaxPlayersCountBots, OnCvarChanged);
	HookConVarChange(g_cvEarlySvRestart, OnCvarChanged);
	HookConVarChange(g_cMinUptime, OnCvarChanged);
	HookConVarChange(g_cCooldown, OnCvarChanged);
	HookConVarChange(g_cWarnClose, OnCvarChanged);
	HookConVarChange(g_cWarnInterval, OnCvarChanged);
	HookConVarChange(g_cWarnCloseInterval, OnCvarChanged);

	// Initialize values
	g_iMode = g_cRestartMode.IntValue;
	g_iDelay = g_cRestartDelay.IntValue;
	g_iMaxPlayers = g_cMaxPlayers.IntValue;
	g_bCountBots = g_cMaxPlayersCountBots.BoolValue;
	g_bEarlyRestart = g_cvEarlySvRestart.BoolValue;
	g_iMinUptime = g_cMinUptime.IntValue;
	g_iCooldown = g_cCooldown.IntValue;
	g_iWarnClose = g_cWarnClose.IntValue;
	g_iWarnInterval = g_cWarnInterval.IntValue;
	g_iWarnCloseInterval = g_cWarnCloseInterval.IntValue;

	AutoExecConfig(true);

	RegAdminCmd("sm_restartsv", Command_RestartServer, ADMFLAG_RCON, "Soft restarts the server to the nextmap.");
	RegAdminCmd("sm_cancelrestart", Command_AdminCancel, ADMFLAG_RCON, "Cancel the soft restart server.");
	RegAdminCmd("sm_svnextrestart", Command_SvNextRestart, ADMFLAG_RCON, "Print time until next restart.");
	RegAdminCmd("sm_reloadrestartcfg", Command_DebugConfig, ADMFLAG_ROOT, "Reloads the configuration.");
	RegAdminCmd("sm_forcerestartcmds", Command_ForceRestartCommands, ADMFLAG_ROOT, "Force execution of post-restart commands.");
	RegAdminCmd("sm_restart_selftest", Command_SelfTest, ADMFLAG_ROOT, "Run built-in self-tests for the restart safety/scheduling logic.");

	RegServerCmd("changelevel", Hook_OnMapChange);
	RegServerCmd("quit", Hook_OnServerQuit);
	RegServerCmd("_restart", Hook_OnServerRestart);

	HookEvent("round_end", OnRoundEnd, EventHookMode_Pre);

	LoadCommandsAfterRestart(false);
}

public void OnPluginEnd()
{
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
	else if (convar == g_cMinUptime)
		g_iMinUptime = g_cMinUptime.IntValue;
	else if (convar == g_cCooldown)
		g_iCooldown = g_cCooldown.IntValue;
	else if (convar == g_cWarnClose)
		g_iWarnClose = g_cWarnClose.IntValue;
	else if (convar == g_cWarnInterval)
		g_iWarnInterval = g_cWarnInterval.IntValue;
	else if (convar == g_cWarnCloseInterval)
		g_iWarnCloseInterval = g_cWarnCloseInterval.IntValue;

	// sm_restart_mode/sm_restart_delay/sm_restart_min_uptime all feed directly into
	// GetNextRestartTime() - without this, the persisted/announced g_iNextRestartTime
	// stays stuck at whatever it was computed to before the change, causing exactly the
	// kind of mismatch where the countdown says "19 hours" but sm_svnextrestart says
	// "1 minute" right after an admin tweaks sm_restart_delay live.
	if (convar == g_cRestartMode || convar == g_cRestartDelay || convar == g_cMinUptime)
		RefreshNextRestartTime();
}

public void OnMapStart()
{
	g_bRestart = false;
	g_bNextMapSet = false;

	LoadConfiguredRestarts();
	LoadRuntimeState();

	if (g_bStateRestarted && !g_bStateChanged)
	{
		// Consume the pending flag immediately, before even attempting the changelevel,
		// so a bad/invalid persisted nextmap can never cause a retry on every subsequent map.
		g_bStateChanged = true;
		WriteRuntimeState();

		if (g_sNextRestartMap[0] && IsMapValid(g_sNextRestartMap))
		{
			ForceChangeLevel(g_sNextRestartMap, "FixMemoryLeak");
		}
		else if (g_sNextRestartMap[0])
		{
			LogError("[FixMemoryLeak] Persisted nextmap '%s' is not valid, staying on the current map.", g_sNextRestartMap);
		}

		// Close the loop right away: compute and persist the *next* restart cycle now,
		// instead of leaving restarted/changed stuck at "1" until something else (the
		// next scheduled restart, or MapChooser Extended's OnSetNextMap if present)
		// eventually gets around to recomputing it.
		SetupNextRestartNextMap("");
	}

	CheckAndAnnounceCountdown();
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
	if (!GetConfigKv(kv))
	{
		delete kv;
		return false;
	}

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
		CReplyToCommand(client, "%t %t", "Prefix", "No Nextmap Set");
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
			int iTime = GetModeZeroThresholdMinutes(g_iDelay, g_bEarlyRestart, g_bEarlyRestart ? AnyRealPlayerConnected() : false, g_iMinUptime);

			int iMinsUntilRestart = iTime - iUptime;
			if (iMinsUntilRestart < 0)
				iMinsUntilRestart = 0;

			int iHours = iMinsUntilRestart / 60;
			int iDays = iHours / 24;
			iHours = iHours % 24;

			CReplyToCommand(client, "%t %t", "Prefix", "Next Restart", iDays, iHours, iMinsUntilRestart % 60);
		}
		case 1, 2:
		{
			char buffer[768], rTime[768];
			int iRemaining = g_iNextRestartTime - GetTime();
			if (iRemaining < 0)
				iRemaining = 0;

			FormatTime(buffer, sizeof(buffer), "%A %d %B %G @ %r", g_iNextRestartTime);
			// Plain HH:MM:SS from the raw second count, not FormatTime("%X", iRemaining) -
			// that formatted the duration as if it were a UTC epoch timestamp and let the
			// server's local timezone/DST rules (evaluated against Jan 1 1970, not today)
			// shift the displayed value, which only looked right by coincidence.
			FormatEx(rTime, sizeof(rTime), "%02d:%02d:%02d", iRemaining / 3600, (iRemaining % 3600) / 60, iRemaining % 60);

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
		// The schedule may have just changed - keep the announced/queried next restart
		// time in sync with it instead of leaving it stale until the next natural event.
		RefreshNextRestartTime();

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

public Action Command_SelfTest(int client, int argc)
{
	int iPass = 0, iFail = 0;
	int iNow = GetTime();

	// ClampToMinUptime floors a time that is already in the past / too close.
	{
		int iFloor = iNow + (10 * 60);
		int iResult = ClampToMinUptime(iNow - 500, 10, iNow);
		if (iResult == iFloor) { iPass++; ReplyToCommand(client, "[PASS] ClampToMinUptime floors a too-close time"); }
		else { iFail++; ReplyToCommand(client, "[FAIL] ClampToMinUptime floors a too-close time (expected %d, got %d)", iFloor, iResult); }
	}

	// ClampToMinUptime leaves a far-future time untouched.
	{
		int iFuture = iNow + 99999;
		int iResult = ClampToMinUptime(iFuture, 10, iNow);
		if (iResult == iFuture) { iPass++; ReplyToCommand(client, "[PASS] ClampToMinUptime keeps a far-future time"); }
		else { iFail++; ReplyToCommand(client, "[FAIL] ClampToMinUptime keeps a far-future time (expected %d, got %d)", iFuture, iResult); }
	}

	// IsCooldownActive gates a very recent restart.
	{
		bool bResult = IsCooldownActive(iNow - 30, 10, iNow);
		if (bResult) { iPass++; ReplyToCommand(client, "[PASS] IsCooldownActive blocks right after a restart"); }
		else { iFail++; ReplyToCommand(client, "[FAIL] IsCooldownActive blocks right after a restart (expected true)"); }
	}

	// IsCooldownActive releases once the cooldown window has passed.
	{
		bool bResult = IsCooldownActive(iNow - 700, 10, iNow);
		if (!bResult) { iPass++; ReplyToCommand(client, "[PASS] IsCooldownActive releases after the window"); }
		else { iFail++; ReplyToCommand(client, "[FAIL] IsCooldownActive releases after the window (expected false)"); }
	}

	// IsCooldownActive never blocks when no restart has ever happened.
	{
		bool bResult = IsCooldownActive(0, 10, iNow);
		if (!bResult) { iPass++; ReplyToCommand(client, "[PASS] IsCooldownActive is inactive with no prior restart"); }
		else { iFail++; ReplyToCommand(client, "[FAIL] IsCooldownActive is inactive with no prior restart (expected false)"); }
	}

	// GetConfiguredRestartTime lands on the configured day/hour/minute, strictly in the future,
	// and never more than 7 days out (catches a runaway day-diff calculation).
	{
		ConfiguredRestart cr;
		cr.iDay = 3;
		cr.iHour = 14;
		cr.iMinute = 30;

		int iResult = GetConfiguredRestartTime(cr, iNow);

		char sBuf[8];
		FormatTime(sBuf, sizeof(sBuf), "%u", iResult);
		int iResultDay = StringToInt(sBuf);
		FormatTime(sBuf, sizeof(sBuf), "%H", iResult);
		int iResultHour = StringToInt(sBuf);
		FormatTime(sBuf, sizeof(sBuf), "%M", iResult);
		int iResultMinute = StringToInt(sBuf);

		bool bOk = (iResult > iNow)
			&& (iResultDay == cr.iDay)
			&& (iResultHour == cr.iHour)
			&& (iResultMinute == cr.iMinute)
			&& ((iResult - iNow) <= 7 * 24 * 60 * 60);

		if (bOk) { iPass++; ReplyToCommand(client, "[PASS] GetConfiguredRestartTime lands on the configured day/hour/minute"); }
		else { iFail++; ReplyToCommand(client, "[FAIL] GetConfiguredRestartTime lands on the configured day/hour/minute (got day=%d hour=%d min=%d, now=%d, result=%d)", iResultDay, iResultHour, iResultMinute, iNow, iResult); }
	}

	// ShouldAnnounceCountdown uses the long "far" spacing while well ahead of the restart.
	{
		bool bResult = ShouldAnnounceCountdown(45, 15, 0.0, 500.0, 600, 60);
		if (!bResult) { iPass++; ReplyToCommand(client, "[PASS] ShouldAnnounceCountdown throttles far-out announcements"); }
		else { iFail++; ReplyToCommand(client, "[FAIL] ShouldAnnounceCountdown throttles far-out announcements (expected false)"); }

		bResult = ShouldAnnounceCountdown(45, 15, 0.0, 700.0, 600, 60);
		if (bResult) { iPass++; ReplyToCommand(client, "[PASS] ShouldAnnounceCountdown fires again once the far interval elapses"); }
		else { iFail++; ReplyToCommand(client, "[FAIL] ShouldAnnounceCountdown fires again once the far interval elapses (expected true)"); }
	}

	// ShouldAnnounceCountdown switches to the short "close" spacing so it fires on
	// effectively every map once inside the warn-close window.
	{
		bool bResult = ShouldAnnounceCountdown(10, 15, 0.0, 90.0, 600, 60);
		if (bResult) { iPass++; ReplyToCommand(client, "[PASS] ShouldAnnounceCountdown uses the short interval once close"); }
		else { iFail++; ReplyToCommand(client, "[FAIL] ShouldAnnounceCountdown uses the short interval once close (expected true)"); }

		bResult = ShouldAnnounceCountdown(10, 15, 0.0, 30.0, 600, 60);
		if (!bResult) { iPass++; ReplyToCommand(client, "[PASS] ShouldAnnounceCountdown still respects the short interval floor"); }
		else { iFail++; ReplyToCommand(client, "[FAIL] ShouldAnnounceCountdown still respects the short interval floor (expected false)"); }
	}

	// GetModeZeroThresholdMinutes: the mode-0 trigger (IsRestartNeeded) and the display
	// (sm_svnextrestart) must always agree on this value.
	{
		int iResult = GetModeZeroThresholdMinutes(60, false, false, 10);
		if (iResult == 60) { iPass++; ReplyToCommand(client, "[PASS] GetModeZeroThresholdMinutes ignores early-restart when disabled"); }
		else { iFail++; ReplyToCommand(client, "[FAIL] GetModeZeroThresholdMinutes ignores early-restart when disabled (expected 60, got %d)", iResult); }

		iResult = GetModeZeroThresholdMinutes(60, true, false, 10);
		if (iResult == 30) { iPass++; ReplyToCommand(client, "[PASS] GetModeZeroThresholdMinutes halves the delay on an empty server"); }
		else { iFail++; ReplyToCommand(client, "[FAIL] GetModeZeroThresholdMinutes halves the delay on an empty server (expected 30, got %d)", iResult); }

		iResult = GetModeZeroThresholdMinutes(60, true, true, 10);
		if (iResult == 60) { iPass++; ReplyToCommand(client, "[PASS] GetModeZeroThresholdMinutes does not halve while players are connected"); }
		else { iFail++; ReplyToCommand(client, "[FAIL] GetModeZeroThresholdMinutes does not halve while players are connected (expected 60, got %d)", iResult); }

		iResult = GetModeZeroThresholdMinutes(10, true, false, 30);
		if (iResult == 30) { iPass++; ReplyToCommand(client, "[PASS] GetModeZeroThresholdMinutes still respects min_uptime after halving"); }
		else { iFail++; ReplyToCommand(client, "[FAIL] GetModeZeroThresholdMinutes still respects min_uptime after halving (expected 30, got %d)", iResult); }
	}

	// GetEarlyRestartTime: mode 1/2 early restart on an empty server must actually fire.
	{
		int iResult = GetEarlyRestartTime(iNow + 1000, iNow - 1000);
		if (iResult == iNow) { iPass++; ReplyToCommand(client, "[PASS] GetEarlyRestartTime halves the span since process start"); }
		else { iFail++; ReplyToCommand(client, "[FAIL] GetEarlyRestartTime halves the span since process start (expected %d, got %d)", iNow, iResult); }

		iResult = GetEarlyRestartTime(iNow - 100, iNow - 5000);
		if (iResult <= iNow) { iPass++; ReplyToCommand(client, "[PASS] GetEarlyRestartTime keeps an overdue target due"); }
		else { iFail++; ReplyToCommand(client, "[FAIL] GetEarlyRestartTime keeps an overdue target due (expected <= %d, got %d)", iNow, iResult); }

		iResult = GetEarlyRestartTime(iNow + 1000, iNow + 2000);
		if (iResult == iNow + 1000) { iPass++; ReplyToCommand(client, "[PASS] GetEarlyRestartTime leaves the target alone without a usable anchor"); }
		else { iFail++; ReplyToCommand(client, "[FAIL] GetEarlyRestartTime leaves the target alone without a usable anchor (expected %d, got %d)", iNow + 1000, iResult); }
	}

	// A pending target survives a map change instead of being recomputed into tomorrow's
	// slot - the whole reason scheduled restarts were being skipped.
	{
		int iHorizon = 8 * 24 * 60 * 60;

		if (IsRestartTargetSane(iNow + 3600, iNow, iHorizon)) { iPass++; ReplyToCommand(client, "[PASS] IsRestartTargetSane keeps a pending in-horizon target"); }
		else { iFail++; ReplyToCommand(client, "[FAIL] IsRestartTargetSane keeps a pending in-horizon target (expected true)"); }

		// Overdue but never consumed: still the target, so the next changelevel restarts.
		if (IsRestartTargetSane(iNow - 600, iNow, iHorizon)) { iPass++; ReplyToCommand(client, "[PASS] IsRestartTargetSane keeps an overdue target pending"); }
		else { iFail++; ReplyToCommand(client, "[FAIL] IsRestartTargetSane keeps an overdue target pending (expected true)"); }

		if (!IsRestartTargetSane(0, iNow, iHorizon)) { iPass++; ReplyToCommand(client, "[PASS] IsRestartTargetSane rejects an unset target"); }
		else { iFail++; ReplyToCommand(client, "[FAIL] IsRestartTargetSane rejects an unset target (expected false)"); }

		if (!IsRestartTargetSane(iNow + (30 * 24 * 60 * 60), iNow, iHorizon)) { iPass++; ReplyToCommand(client, "[PASS] IsRestartTargetSane rejects a target past the horizon"); }
		else { iFail++; ReplyToCommand(client, "[FAIL] IsRestartTargetSane rejects a target past the horizon (expected false)"); }
	}

	// A configured slot resolves to the same whole-minute timestamp regardless of which
	// second it gets computed on.
	{
		ConfiguredRestart crStable;
		crStable.iDay = 3;
		crStable.iHour = 14;
		crStable.iMinute = 30;

		int iA = GetConfiguredRestartTime(crStable, iNow);
		int iB = GetConfiguredRestartTime(crStable, iNow + 37);
		// The 37s step can legitimately cross the slot itself, which rolls it a week on.
		bool bStable = (iA == iB) || ((iA - iNow) <= 60);

		if ((iA % 60) == 0 && bStable) { iPass++; ReplyToCommand(client, "[PASS] GetConfiguredRestartTime is second-stable"); }
		else { iFail++; ReplyToCommand(client, "[FAIL] GetConfiguredRestartTime is second-stable (got %d then %d)", iA, iB); }
	}

	ReplyToCommand(client, "[FixMemoryLeak] Selftest complete: %d passed, %d failed.", iPass, iFail);
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
	{
		CheckAndAnnounceCountdown();
		return Plugin_Continue;
	}

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

/**
 * Anti-loop safety nets. These are intentionally independent from the mode 0/1/2
 * scheduling logic below: even if that logic (or a corrupted/stale persisted state)
 * says "restart now", these two checks guarantee the plugin can never restart the
 * server on every single map change.
 */
stock int ClampToMinUptime(int iTime, int iMinUptimeMinutes, int iNow)
{
	int iFloor = iNow + (iMinUptimeMinutes * 60);
	return (iTime < iFloor) ? iFloor : iTime;
}

stock bool IsCooldownActive(int iLastRestart, int iCooldownMinutes, int iNow)
{
	return iLastRestart > 0 && (iNow - iLastRestart) < (iCooldownMinutes * 60);
}

stock bool AnyRealPlayerConnected()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientConnected(i) && !IsFakeClient(i))
			return true;
	}
	return false;
}

// Mode 0's "minutes of uptime before we restart" threshold, shared by IsRestartNeeded()
// (the actual trigger) and Command_SvNextRestart (the display) so they can never disagree.
stock int GetModeZeroThresholdMinutes(int iDelay, bool bEarlyRestart, bool bHasPlayers, int iMinUptime)
{
	int iTime = iDelay;

	if (bEarlyRestart && !bHasPlayers)
		iTime /= 2;

	if (iTime < iMinUptime)
		iTime = iMinUptime;

	return iTime;
}

// Mode 1/2 early restart on an empty server: halve the span between process start and the
// scheduled target, the timestamp equivalent of mode 0's "uptime >= delay / 2". Halving the
// time remaining from *now* instead is a no-op (now + (T - now) / 2 is only reached once T
// itself is), and must not be floored at now + min_uptime either, or an empty server never
// restarts - the actual-uptime floor in IsRestartNeeded() already covers that concern.
stock int GetEarlyRestartTime(int iTarget, int iProcessStart)
{
	if (iProcessStart <= 0 || iProcessStart >= iTarget)
		return iTarget;

	return iProcessStart + ((iTarget - iProcessStart) / 2);
}

stock bool IsRestartNeeded()
{
	int currentTime = GetTime();

	if (IsCooldownActive(g_iLastRestartTime, g_iCooldown, currentTime))
		return false;

	// Hard floor on *actual* uptime. ClampToMinUptime() only guards the scheduled timestamp
	// at the moment it is computed, which says nothing about how long this process has been
	// alive: now that a pending target survives across maps (see ResolveNextRestartTime), a
	// server coming back up with an already-overdue target - crash, manual stop, a window
	// that was missed - would otherwise restart again on its very first map change.
	if (g_iMinUptime > 0 && CalculateUptime() < g_iMinUptime)
		return false;

	bool bHasPlayers = g_bEarlyRestart ? AnyRealPlayerConnected() : false;

	switch (g_iMode)
	{
		case 0:
		{
			int iUptime = CalculateUptime();
			int iTime = GetModeZeroThresholdMinutes(g_iDelay, g_bEarlyRestart, bHasPlayers, g_iMinUptime);

			return iUptime >= iTime;
		}
		case 1, 2:
		{
			if (g_iNextRestartTime <= 0)
			{
				SetupNextRestartNextMap("");
				return false;
			}

			int iTime = g_iNextRestartTime;

			if (g_bEarlyRestart && !bHasPlayers)
				iTime = GetEarlyRestartTime(iTime, currentTime - RoundToFloor(GetEngineTime()));

			return currentTime >= iTime;
		}
	}

	return false;
}

stock void SoftServerRestart()
{
	g_bRestart = true;

	int iNow = GetTime();
	g_iLastRestartTime = iNow;
	g_iNextRestartTime = GetNextRestartTime(iNow);
	g_bStateRestarted = true;
	g_bStateChanged = false;

	// We need to persist the (future) next restart time and the "restarted" flag before
	// actually quitting, so that if the process comes back up before this timestamp is
	// reached again, IsRestartNeeded()/IsCooldownActive() both refuse to fire immediately.
	if (!WriteRuntimeState())
		LogError("[FixMemoryLeak] Failed to persist restart state before quitting - the server may not land on the intended nextmap after relaunch.");

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
}

/**
 * A scheduled restart target has to survive map changes.
 *
 * IsRestartNeeded() is only consulted on "changelevel", so a target that comes due mid-map
 * stays pending until the next map change. Every SetupNextRestart* caller used to recompute
 * it from "now" instead - and OnSetNextMap runs that path once per map, as soon as
 * MapChooser resolves the nextmap. Any recompute landing after the configured time (i.e.
 * the whole rest of the map, which sm_restart_min_uptime makes near-certain by pushing an
 * imminent target past the natural changelevel) made GetConfiguredClosestTime() return the
 * *next* slot - a full day later - so the due restart was silently dropped. Repeat daily and
 * the server simply never restarts.
 *
 * So: keep the pending target. A new one is computed only when there is none, when the
 * persisted one is not sane, after a restart consumed it (SoftServerRestart), or when an
 * admin explicitly forces it (RefreshNextRestartTime).
 */
stock bool IsRestartTargetSane(int iTarget, int iNow, int iHorizon)
{
	return iTarget > 0 && iTarget <= iNow + iHorizon;
}

// Furthest a legitimate target can sit, plus a day of slack. A configured slot is never more
// than one week out, and every mode falls back to sm_restart_delay (mode 0 always, mode 1/2
// when no slot is configured), so the bound is the larger of the two. Anything past this is a
// corrupted persisted value: without the bound, a single bad "nextrestart" in the config
// would freeze the schedule forever now that the target is no longer recomputed on every map.
// Bounding it by the week alone would do the opposite for a delay above 8 days - the target
// would be rejected and pushed forward on every map, so it would never be reached.
stock int GetMaxSaneRestartHorizon()
{
	int iWeek = 7 * 24 * 60 * 60;
	int iDelay = g_iDelay * 60;
	return ((iDelay > iWeek) ? iDelay : iWeek) + (24 * 60 * 60);
}

stock int ResolveNextRestartTime(int iNow)
{
	if (IsRestartTargetSane(g_iNextRestartTime, iNow, GetMaxSaneRestartHorizon()))
		return g_iNextRestartTime;

	return GetNextRestartTime(iNow);
}

stock void SetupNextRestartCurrentMap(bool bForce = false)
{
	char sMap[PLATFORM_MAX_PATH];
	GetCurrentMap(sMap, sizeof(sMap));

	int iNextTime = bForce ? GetTime() : ResolveNextRestartTime(GetTime());
	SetNextRestart(iNextTime, sMap);
}

stock void SetupNextRestartNextMap(const char[] map)
{
	// Nextmap is already set, no need to continue
	if (g_bNextMapSet)
		return;

	char sNextMap[PLATFORM_MAX_PATH];
	strcopy(sNextMap, sizeof(sNextMap), map);

	if (!sNextMap[0] && !GetNextMap(sNextMap, sizeof(sNextMap)))
	{
		ConVar cvar = FindConVar("sm_nextmap");
		if (cvar != null)
			cvar.GetString(sNextMap, sizeof(sNextMap));
	}

	if (!sNextMap[0] || !IsMapValid(sNextMap))
	{
		if (sNextMap[0])
			LogError("[FixMemoryLeak] Resolved nextmap '%s' is invalid, falling back to current map.", sNextMap);

		SetupNextRestartCurrentMap();
		return;
	}

	SetNextRestart(ResolveNextRestartTime(GetTime()), sNextMap);
}

stock void SetNextRestart(int iNextTime, const char[] sMap)
{
	bool bTimeChanged = (iNextTime != g_iNextRestartTime);

	g_iNextRestartTime = iNextTime;
	strcopy(g_sNextRestartMap, sizeof(g_sNextRestartMap), sMap);
	g_bStateRestarted = false;
	g_bStateChanged = false;

	if (!WriteRuntimeState())
		LogError("[FixMemoryLeak] Failed to persist next restart (%d, map=%s).", iNextTime, sMap);
	else if (bTimeChanged)
		LogMessage("Next restart set at %d on %s", iNextTime, sMap);
	else
		LogMessage("Next restart still pending at %d, now targeting %s", iNextTime, sMap);

	// New target time: let the next check announce it right away. An unchanged target must
	// not reset this - every map change would otherwise restart the throttle and
	// sm_restart_warn_interval would never actually space the announcements out.
	if (bTimeChanged)
		g_flLastWarnTime = 0.0;

	g_bNextMapSet = true;
}

// Recomputes g_iNextRestartTime from the *current* mode/delay/min_uptime, keeping
// whatever nextmap is already tracked. Unlike SetupNextRestartNextMap(), this ignores
// the g_bNextMapSet guard on purpose - it exists specifically to force a refresh when
// an admin changes the scheduling convars or reloads the schedule live, so the
// announced/queried next restart time never goes stale mid-map. It is also the only path
// that deliberately throws away a still-pending target - ResolveNextRestartTime() keeps it
// everywhere else.
stock void RefreshNextRestartTime()
{
	if (g_sNextRestartMap[0])
		SetNextRestart(GetNextRestartTime(GetTime()), g_sNextRestartMap);
	else
		SetupNextRestartNextMap("");
}

/**
 * Countdown announcements always show the *live* remaining time ("restart in 23
 * minutes", then 22, 21, ... on whichever maps happen to land on a check), rather
 * than snapping to a fixed list of checkpoints - a fixed-checkpoint design would
 * silently skip announcing on any map that doesn't land exactly on one. Spacing is
 * controlled purely by a minimum interval: a long one while far from the restart
 * (so it doesn't fire on every single map), and a short one once inside
 * sm_restart_warn_close (so it effectively does fire on every map).
 */
stock void CheckAndAnnounceCountdown()
{
	if (g_bPostponeRestart || g_iNextRestartTime <= 0)
		return;

	int iRemainingSec = g_iNextRestartTime - GetTime();
	if (iRemainingSec <= 0)
		return;

	int iRemainingMin = RoundToCeil(float(iRemainingSec) / 60.0);
	float flNow = GetEngineTime();

	if (!ShouldAnnounceCountdown(iRemainingMin, g_iWarnClose, g_flLastWarnTime, flNow, g_iWarnInterval, g_iWarnCloseInterval))
		return;

	AnnounceCountdown(iRemainingMin);
	g_flLastWarnTime = flNow;
}

stock bool ShouldAnnounceCountdown(int iRemainingMin, int iWarnCloseMin, float flLastWarn, float flNow, int iFarIntervalSec, int iCloseIntervalSec)
{
	int iRequiredInterval = (iRemainingMin <= iWarnCloseMin) ? iCloseIntervalSec : iFarIntervalSec;
	return (flNow - flLastWarn) >= float(iRequiredInterval);
}

stock void AnnounceCountdown(int iMinutes)
{
	// Past 2 hours remaining, showing raw minutes ("in 156 minutes") is noise - round
	// down to whole hours instead ("in 2 hours").
	if (iMinutes >= 120)
		CPrintToChatAll("%t %t", "Prefix", "Restart Countdown Hours", iMinutes / 60);
	else
		CPrintToChatAll("%t %t", "Prefix", "Restart Countdown", iMinutes);
}

// Known limitation: this walks day-to-day in flat 24*60*60-second steps, which assumes
// every day is exactly 86400 seconds of wall-clock time. During the week a DST transition
// happens, a local day is actually 82800s (spring-forward) or 90000s (fall-back), so the
// configured hour/minute can land up to 1h off that week. SourcePawn has no DST-aware
// mktime()-equivalent to compute "epoch for this local Y-M-D H:M" correctly, so this is
// accepted rather than fixed - re-verify the schedule (or just expect a possible 1h drift)
// around DST changes.
stock int GetConfiguredRestartTime(ConfiguredRestart configuredRestart, int iNow)
{
	char sBuffer[10];
	FormatTime(sBuffer, sizeof(sBuffer), "%u", iNow);
	int iCurrentDay = StringToInt(sBuffer);

	int iDiff;
	if (iCurrentDay > configuredRestart.iDay)
		iDiff = (7 - iCurrentDay) + configuredRestart.iDay;
	else
		iDiff = configuredRestart.iDay - iCurrentDay;

	int iTime = iNow;
	iTime += iDiff * (24 * 60 * 60);

	FormatTime(sBuffer, sizeof(sBuffer), "%H", iTime);
	int iCurrentHour = StringToInt(sBuffer);

	FormatTime(sBuffer, sizeof(sBuffer), "%M", iTime);
	int iCurrentMinute = StringToInt(sBuffer);

	// Zero the seconds as well. Without this the target inherited whatever second the
	// computation happened to run on, so the same configured slot resolved to a slightly
	// different timestamp every time and "06:45" silently became "06:45:47".
	FormatTime(sBuffer, sizeof(sBuffer), "%S", iTime);
	int iCurrentSecond = StringToInt(sBuffer);

	iTime -= iCurrentHour * (60 * 60);
	iTime -= iCurrentMinute * (60);
	iTime -= iCurrentSecond;

	iTime += configuredRestart.iHour * (60 * 60);
	iTime += configuredRestart.iMinute * (60);

	if (iTime <= iNow)
		iTime += 7 * (24 * 60 * 60);

	return iTime;
}

stock int GetConfiguredClosestTime(int iNow)
{
	int iNextTime = 0;

	if (g_iConfiguredRestarts == null)
		return iNextTime;

	for (int i = 0; i < g_iConfiguredRestarts.Length; i++)
	{
		ConfiguredRestart configuredRestart;
		g_iConfiguredRestarts.GetArray(i, configuredRestart, sizeof(configuredRestart));

		int iConfiguredRestartTime = GetConfiguredRestartTime(configuredRestart, iNow);

		if (g_bDebug)
			CPrintToChatAll("Timestamp => %d", iConfiguredRestartTime);

		if (i == 0 || iConfiguredRestartTime < iNextTime)
			iNextTime = iConfiguredRestartTime;
	}

	return iNextTime;
}

stock int GetNextRestartTime(int iNow)
{
	int iNextTime = 0;
	int iDelayTime = iNow + (g_iDelay * 60);

	switch (g_iMode)
	{
		case 0:
		{
			iNextTime = iDelayTime;
		}
		case 1:
		{
			iNextTime = GetConfiguredClosestTime(iNow);
		}
		case 2:
		{
			int iConfiguredTime = GetConfiguredClosestTime(iNow);
			iNextTime = (iConfiguredTime > 0 && iConfiguredTime < iDelayTime) ? iConfiguredTime : iDelayTime;
		}
	}

	if (iNextTime <= 0)
		iNextTime = iDelayTime;

	return ClampToMinUptime(iNextTime, g_iMinUptime, iNow);
}

/**
 * Config file handling. CONFIG_PATH holds three sections:
 *  - "commands": admin-authored, executed once after a restart-triggered relaunch.
 *  - "restart":  admin-authored weekly schedule (day 1-7 ISO, Monday=1..Sunday=7).
 *  - "info":     plugin-owned runtime state, mirrored in g_iNextRestartTime/etc and
 *                only ever written through WriteRuntimeState() (atomic).
 * A missing or corrupted file is regenerated with safe defaults; a corrupted file is
 * first backed up (".corrupt-<timestamp>") so nothing is silently lost.
 */
#define CONFIG_SECTION_COMMANDS (1 << 0)
#define CONFIG_SECTION_INFO     (1 << 1)
#define CONFIG_SECTION_RESTART  (1 << 2)
#define CONFIG_SECTION_ALL      (CONFIG_SECTION_COMMANDS | CONFIG_SECTION_INFO | CONFIG_SECTION_RESTART)

stock int GetConfigSectionBit(int iIndex, char[] sName, int iMaxLen)
{
	switch (iIndex)
	{
		case 0: strcopy(sName, iMaxLen, CONFIG_KV_COMMANDS_NAME);
		case 1: strcopy(sName, iMaxLen, CONFIG_KV_INFO_NAME);
		case 2: strcopy(sName, iMaxLen, CONFIG_KV_RESTART_NAME);
	}
	return (1 << iIndex);
}

// Bitmask of the known sections reachable directly under the root.
stock int GetRootConfigSections(KeyValues kv)
{
	int iMask = 0;
	char sName[16];

	for (int i = 0; i < 3; i++)
	{
		int iBit = GetConfigSectionBit(i, sName, sizeof(sName));
		kv.Rewind();
		if (kv.JumpToKey(sName))
			iMask |= iBit;
	}

	kv.Rewind();
	return iMask;
}

stock void FormatConfigSections(int iMask, char[] sBuffer, int iMaxLen)
{
	sBuffer[0] = '\0';
	char sName[16];

	for (int i = 0; i < 3; i++)
	{
		if (iMask & GetConfigSectionBit(i, sName, sizeof(sName)))
			Format(sBuffer, iMaxLen, "%s\"%s\" ", sBuffer, sName);
	}
}

// KeyValues.ImportFromFile() is lenient about malformed braces - it can return true on a
// genuinely broken file (mismatched "{"/"}") while silently nesting the following sections
// inside the unclosed one instead of failing outright. A section that is merely absent is
// fine (an admin may drop an unused "commands" or "restart" block, and "info" is created on
// the first write); a known section found one level down, under another top-level section,
// is what a brace mismatch looks like. Returns the bitmask of such misplaced sections.
stock int GetNestedConfigSections(KeyValues kv, int iMissingMask)
{
	int iNested = 0;
	char sName[16];

	kv.Rewind();
	if (iMissingMask && kv.GotoFirstSubKey())
	{
		do
		{
			for (int i = 0; i < 3; i++)
			{
				int iBit = GetConfigSectionBit(i, sName, sizeof(sName));
				if ((iMissingMask & iBit) && kv.JumpToKey(sName))
				{
					iNested |= iBit;
					kv.GoBack();
				}
			}
		} while (kv.GotoNextKey());
	}

	kv.Rewind();
	return iNested;
}

stock bool GetConfigKv(KeyValues &kv)
{
	kv = new KeyValues(CONFIG_KV_NAME);

	char sFile[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sFile, sizeof(sFile), CONFIG_PATH);

	bool bFileExists = FileExists(sFile);
	bool bImported = bFileExists && kv.ImportFromFile(sFile);

	int iNested = 0;
	if (bImported)
	{
		iNested = GetNestedConfigSections(kv, CONFIG_SECTION_ALL & ~GetRootConfigSections(kv));
		if (!iNested)
			return true;
	}

	if (bFileExists)
	{
		char sBackup[PLATFORM_MAX_PATH];
		FormatEx(sBackup, sizeof(sBackup), "%s.corrupt-%d", sFile, GetTime());

		char sReason[128];
		if (!bImported)
			strcopy(sReason, sizeof(sReason), "file failed to parse (invalid KeyValues syntax, e.g. stray brace or a BOM/encoding issue)");
		else
		{
			char sNested[64];
			FormatConfigSections(iNested, sNested, sizeof(sNested));
			FormatEx(sReason, sizeof(sReason), "section(s) %snested under another section, likely a missing closing brace", sNested);
		}

		if (RenameFile(sBackup, sFile))
			LogError("[FixMemoryLeak] Config file was unreadable or malformed (%s), backed up to '%s' and regenerating defaults.", sReason, sBackup);
		else
			LogError("[FixMemoryLeak] Config file was unreadable or malformed (%s) and could not be backed up; overwriting with defaults.", sReason);
	}

	WriteDefaultConfig(sFile);

	delete kv;
	kv = new KeyValues(CONFIG_KV_NAME);

	if (!kv.ImportFromFile(sFile))
	{
		LogError("[FixMemoryLeak] CRITICAL: unable to create a usable config at %s.", sFile);
		delete kv;
		kv = null;
		return false;
	}

	return true;
}

stock bool WriteDefaultConfig(const char[] sFile)
{
	Handle hFile = OpenFile(sFile, "w");

	if (hFile == INVALID_HANDLE)
	{
		LogError("[FixMemoryLeak] Could not create default config at %s", sFile);
		return false;
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
	WriteFileLine(hFile, "\t\t\"nextrestart\"\t\"0\"");
	WriteFileLine(hFile, "\t\t\"nextmap\"\t\"\"");
	WriteFileLine(hFile, "\t\t\"restarted\"\t\"0\"");
	WriteFileLine(hFile, "\t\t\"changed\"\t\"0\"");
	WriteFileLine(hFile, "\t\t\"lastrestart\"\t\"0\"");
	WriteFileLine(hFile, "\t}");

	// "day" is ISO-8601 (1=Monday .. 7=Sunday), "hour" is 0-23, "minute" is 0-59.
	// Leave "day" empty to disable this slot, or add more numbered blocks for more slots.
	WriteFileLine(hFile, "\t\"%s\"", CONFIG_KV_RESTART_NAME);
	WriteFileLine(hFile, "\t{");
	WriteFileLine(hFile, "\t\t\"0\"");
	WriteFileLine(hFile, "\t\t{");
	WriteFileLine(hFile, "\t\t\t\"day\"\t\t\"\"");
	WriteFileLine(hFile, "\t\t\t\"hour\"\t\t\"\"");
	WriteFileLine(hFile, "\t\t\t\"minute\"\t\"\"");
	WriteFileLine(hFile, "\t\t}");
	WriteFileLine(hFile, "\t}");

	WriteFileLine(hFile, "}");

	CloseHandle(hFile);
	return true;
}

stock bool ExportConfigAtomic(KeyValues kv)
{
	char sFile[PLATFORM_MAX_PATH], sTmp[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sFile, sizeof(sFile), CONFIG_PATH);
	FormatEx(sTmp, sizeof(sTmp), "%s.tmp", sFile);

	if (!kv.ExportToFile(sTmp))
		return false;

	// Validate the temp file actually parses AND still has every section the in-memory tree
	// had before trusting it over the live config. ExportToFile round-tripping the tree can
	// still yield a technically-parseable file that lost a section (e.g. if the section was
	// empty) - without this check, that broken file would get promoted over the last
	// known-good config and the admin's schedule or commands would be silently dropped.
	int iExpected = GetRootConfigSections(kv);

	KeyValues kvCheck = new KeyValues(CONFIG_KV_NAME);
	bool bValid = kvCheck.ImportFromFile(sTmp);

	int iLost = bValid ? (iExpected & ~GetRootConfigSections(kvCheck)) : 0;
	if (iLost)
	{
		char sLost[64];
		FormatConfigSections(iLost, sLost, sizeof(sLost));
		LogError("[FixMemoryLeak] Refusing to persist restart state: exporting it produced a config missing section(s): %s- keeping the previous file on disk.", sLost);
		bValid = false;
	}

	delete kvCheck;

	if (!bValid)
	{
		DeleteFile(sTmp);
		return false;
	}

	if (!RenameFile(sFile, sTmp))
	{
		DeleteFile(sTmp);
		return false;
	}

	return true;
}

stock void LoadRuntimeState()
{
	g_iNextRestartTime = 0;
	g_sNextRestartMap[0] = '\0';
	g_bStateRestarted = false;
	g_bStateChanged = false;
	g_iLastRestartTime = 0;

	KeyValues kv;
	if (!GetConfigKv(kv))
	{
		delete kv;
		return;
	}

	if (!kv.JumpToKey(CONFIG_KV_INFO_NAME))
	{
		delete kv;
		return;
	}

	char sValue[PLATFORM_MAX_PATH];

	kv.GetString("nextrestart", sValue, sizeof(sValue), "0");
	g_iNextRestartTime = StringToInt(sValue);

	kv.GetString("nextmap", g_sNextRestartMap, sizeof(g_sNextRestartMap), "");

	kv.GetString("restarted", sValue, sizeof(sValue), "0");
	g_bStateRestarted = (sValue[0] == '1');

	kv.GetString("changed", sValue, sizeof(sValue), "0");
	g_bStateChanged = (sValue[0] == '1');

	kv.GetString("lastrestart", sValue, sizeof(sValue), "0");
	g_iLastRestartTime = StringToInt(sValue);

	delete kv;
}

stock bool WriteRuntimeState()
{
	KeyValues kv;
	if (!GetConfigKv(kv))
	{
		delete kv;
		return false;
	}

	if (!kv.JumpToKey(CONFIG_KV_INFO_NAME, true))
	{
		LogError("[FixMemoryLeak] Could not access '%s' section while saving restart state.", CONFIG_KV_INFO_NAME);
		delete kv;
		return false;
	}

	char sBuffer[32];
	IntToString(g_iNextRestartTime, sBuffer, sizeof(sBuffer));
	kv.SetString("nextrestart", sBuffer);
	kv.SetString("nextmap", g_sNextRestartMap);
	kv.SetString("restarted", g_bStateRestarted ? "1" : "0");
	kv.SetString("changed", g_bStateChanged ? "1" : "0");
	IntToString(g_iLastRestartTime, sBuffer, sizeof(sBuffer));
	kv.SetString("lastrestart", sBuffer);

	kv.Rewind();

	bool bSuccess = ExportConfigAtomic(kv);
	delete kv;

	return bSuccess;
}

stock void GetDayName(int iDay, char[] sBuffer, int iMaxLen)
{
	static char sNames[7][10] = { "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" };

	if (iDay >= 1 && iDay <= 7)
		strcopy(sBuffer, iMaxLen, sNames[iDay - 1]);
	else
		strcopy(sBuffer, iMaxLen, "Invalid");
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

	char sCurrentDayName[10], sConfiguredDayName[10];
	GetDayName(iCurrentDay, sCurrentDayName, sizeof(sCurrentDayName));

	for (int i = 0; i < g_iConfiguredRestarts.Length; i++)
	{
		ConfiguredRestart configuredRestart;

		g_iConfiguredRestarts.GetArray(i, configuredRestart, sizeof(configuredRestart));
		GetDayName(configuredRestart.iDay, sConfiguredDayName, sizeof(sConfiguredDayName));

		CPrintToChat(client, "{red}[Debug] {blue}Day : {default}T %s. {green}C %s {default}| {blue}Hour : {default}T %d. {green}C %d {default}| {blue}Minute : {default}T %d. {green}C %d", sCurrentDayName, sConfiguredDayName, iCurrentHour, configuredRestart.iHour, iCurrentMinute, configuredRestart.iMinute);
	}
}

stock bool LoadConfiguredRestarts(bool bReload = true)
{
	KeyValues kv;
	if (!GetConfigKv(kv))
	{
		delete kv;
		return false;
	}

	// Reset before looking at the section, so emptying or removing the schedule and
	// reloading actually drops the old slots instead of keeping them active.
	if (bReload && g_iConfiguredRestarts != null)
		delete g_iConfiguredRestarts;

	if (g_iConfiguredRestarts == null)
		g_iConfiguredRestarts = new ArrayList(sizeof(ConfiguredRestart));

	// No "restart" section, or an empty one, simply means no scheduled slot.
	if (!kv.JumpToKey(CONFIG_KV_RESTART_NAME) || !kv.GotoFirstSubKey())
	{
		delete kv;
		return true;
	}

	char sKeyName[16];
	char sValue[16];

	do
	{
		kv.GetSectionName(sKeyName, sizeof(sKeyName));

		ConfiguredRestart configuredRestart;
		bool bValid = true;

		kv.GetString("day", sValue, sizeof(sValue), "");
		configuredRestart.iDay = StringToInt(sValue);
		if (sValue[0] == '\0')
		{
			// Empty day is the documented way to leave a schedule slot disabled - skip silently.
			bValid = false;
		}
		else if (configuredRestart.iDay < 1 || configuredRestart.iDay > 7)
		{
			LogError("[FixMemoryLeak] Restart schedule entry '%s': invalid day '%s' (expected 1-7, Monday=1), skipping.", sKeyName, sValue);
			bValid = false;
		}

		kv.GetString("hour", sValue, sizeof(sValue), "");
		configuredRestart.iHour = StringToInt(sValue);
		if (bValid && (sValue[0] == '\0' || configuredRestart.iHour < 0 || configuredRestart.iHour > 23))
		{
			LogError("[FixMemoryLeak] Restart schedule entry '%s': invalid hour '%s' (expected 0-23), skipping.", sKeyName, sValue);
			bValid = false;
		}

		kv.GetString("minute", sValue, sizeof(sValue), "");
		configuredRestart.iMinute = StringToInt(sValue);
		if (bValid && (sValue[0] == '\0' || configuredRestart.iMinute < 0 || configuredRestart.iMinute > 59))
		{
			LogError("[FixMemoryLeak] Restart schedule entry '%s': invalid minute '%s' (expected 0-59), skipping.", sKeyName, sValue);
			bValid = false;
		}

		if (bValid)
			g_iConfiguredRestarts.PushArray(configuredRestart, sizeof(configuredRestart));

	} while (kv.GotoNextKey());

	delete kv;

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
