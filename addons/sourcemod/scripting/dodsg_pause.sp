/**
 * dodsg_pause - Controlled Pause Plugin
 *
 * - Native engine pause + FL_FROZEN flag (server-side full input block)
 * - Disables dod_capture_area, dod_control_point_master, dod_scoring (stops tickpoints)
 * - Freezes mp_timelimit (compensates time lost during pause)
 * - Full black screen via Fade message (same method as dodsg_ftb)
 * - Center-text status display refreshed every 0.75s
 * - [DODSG PAUSE] prefix in green in all chat messages
 * - !pause / !unpause with opposing team confirmation
 * - 5-second resume countdown
 * - Configurable via addons/sourcemod/configs/dodsg_pause.cfg
 *
 * Compile with SourceMod 1.10+
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION  "8.0.0"
#define CHAT_TAG        "\x04[DODSG PAUSE]\x01 "

// Fade flags (matches dodsg_ftb)
#define FFADE_IN        0x0001
#define FFADE_OUT       0x0002
#define FFADE_MODULATE  0x0004
#define FFADE_STAYOUT   0x0008
#define FFADE_PURGE     0x0010

public Plugin myinfo =
{
    name        = "DODSG Pause",
    author      = "pratinha",
    description = "Competitive pause: full freeze + black screen + timeleft/tickpoints freeze",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ── ConVars ───────────────────────────────────────────────────────────────────
ConVar g_cvMaxPauseTime;
ConVar g_cvWarningInterval;
ConVar g_cvSvPausable;
ConVar g_cvMpTimelimit;
ConVar g_cvTickPointInterval;  // mp_tickpointinterval — set to very high value to stop tickpoints

// ── State ─────────────────────────────────────────────────────────────────────
bool   g_bPaused          = false;
bool   g_bWaitingUnpause  = false;
bool   g_bCountingDown    = false;
int    g_iPauseTeam       = -1;
int    g_iCountdown       = 0;
int    g_iTimeRemaining   = 0;
int    g_iNextWarning     = 0;
int    g_iTimeleftAtPause = 0;

MoveType g_SavedMoveType[MAXPLAYERS + 1];

Handle g_hCountdownTimer  = INVALID_HANDLE;
Handle g_hMaxPauseTimer   = INVALID_HANDLE;
Handle g_hCenterTextTimer = INVALID_HANDLE;

// ── Plugin start ──────────────────────────────────────────────────────────────
public void OnPluginStart()
{
    g_cvSvPausable        = FindConVar("sv_pausable");
    g_cvMpTimelimit       = FindConVar("mp_timelimit");
    g_cvTickPointInterval = FindConVar("mp_tickpointinterval");
    g_cvSvPausable.IntValue = 0;

    g_cvMaxPauseTime    = CreateConVar("dodsg_pause_maxtime",  "300", "Maximum pause duration in seconds. 0 = unlimited.", FCVAR_NOTIFY, true, 0.0);
    g_cvWarningInterval = CreateConVar("dodsg_pause_warntime", "60",  "Interval in seconds between remaining-time announcements.", FCVAR_NOTIFY, true, 10.0);

    LoadConfig();

    RegAdminCmd("sm_dodsg_listents", Cmd_ListEnts, ADMFLAG_ROOT, "List all dod_ entities in the map");

    RegConsoleCmd("sm_pause",   Cmd_Pause,   "Pauses the game");
    RegConsoleCmd("sm_unpause", Cmd_Unpause, "Requests to resume the game (opposing team must confirm)");

    // Block native pause from clients
    AddCommandListener(Listener_NativePause, "pause");

    // Block minimap commands (not blocked by FL_FROZEN as they are engine-level)
    AddCommandListener(Listener_Block, "+showmap");
    AddCommandListener(Listener_Block, "showmap");
    AddCommandListener(Listener_Block, "dod_togglemap");
    AddCommandListener(Listener_Block, "+dod_zoom_map");
    AddCommandListener(Listener_Block, "dod_zoom_map");
    AddCommandListener(Listener_Block, "overview_zoom");
    AddCommandListener(Listener_Block, "overview_mode");

    HookEvent("dod_round_start", Event_RoundStart, EventHookMode_Post);
    HookEvent("player_spawn",    Event_PlayerSpawn, EventHookMode_Post);

    LoadTranslations("common.phrases");
}

public void OnMapStart()
{
    g_cvSvPausable.IntValue = 0;
    ResetState();
}

// ── Input listeners ───────────────────────────────────────────────────────────
public Action Listener_NativePause(int client, const char[] command, int argc)
{
    if (client == 0)
        return Plugin_Continue;
    return Plugin_Stop;
}

public Action Listener_Block(int client, const char[] command, int argc)
{
    if (g_bPaused && client > 0)
        return Plugin_Stop;
    return Plugin_Continue;
}

// ── Events ────────────────────────────────────────────────────────────────────
public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_bPaused)
        return;

    int client = GetClientOfUserId(event.GetInt("userid"));
    if (IsValidPausableClient(client))
    {
        FreezePlayer(client);
        SendFade(client, true);
    }
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_bPaused)
        return;

    DoEngineUnpause();
    UnfreezeAllPlayers();
    SendFadeAll(false);
    SetCaptureAreasEnabled(true);
    RestoreTimeleft();
    StopCenterText();
    PrintToChatAll(CHAT_TAG ... "Pause cancelled — new round started.");
    ResetState();
}

// ── Command: !pause ───────────────────────────────────────────────────────────
public Action Cmd_Pause(int client, int argc)
{
    if (client == 0)
    {
        ReplyToCommand(client, "[DODSG PAUSE] This command is for players only.");
        return Plugin_Handled;
    }

    if (g_bPaused)
    {
        PrintToChat(client, CHAT_TAG ... "The game is already paused. Type \x03!unpause\x01 to resume.");
        return Plugin_Handled;
    }

    int team = GetClientTeam(client);
    if (team < 2)
    {
        PrintToChat(client, CHAT_TAG ... "You must be on a team to pause the game.");
        return Plugin_Handled;
    }

    g_bPaused         = true;
    g_bCountingDown   = false;
    g_bWaitingUnpause = false;
    g_iPauseTeam      = team;

    GetMapTimeLeft(g_iTimeleftAtPause);
    FreezeTimeleft();
    SetCaptureAreasEnabled(false);
    FreezeAllPlayers();
    DoEnginePause();
    SendFadeAll(true);
    StartCenterText();

    char playerName[64];
    GetClientName(client, playerName, sizeof(playerName));

    int maxTime = g_cvMaxPauseTime.IntValue;
    if (maxTime > 0)
    {
        g_iTimeRemaining = maxTime;
        g_iNextWarning   = ComputeNextWarning(g_iTimeRemaining);

        PrintToChatAll(CHAT_TAG ... "\x03%s\x01 paused the game for up to \x05%s\x01. Type \x03!unpause\x01 to resume (opposing team confirmation required).",
            playerName, FormatDuration(maxTime));

        g_hMaxPauseTimer = CreateTimer(1.0, Timer_MaxPause, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    }
    else
    {
        PrintToChatAll(CHAT_TAG ... "\x03%s\x01 paused the game. Type \x03!unpause\x01 to resume (opposing team confirmation required).", playerName);
    }

    return Plugin_Handled;
}

// ── Command: !unpause ─────────────────────────────────────────────────────────
public Action Cmd_Unpause(int client, int argc)
{
    if (client == 0)
    {
        ReplyToCommand(client, "[DODSG PAUSE] This command is for players only.");
        return Plugin_Handled;
    }

    if (!g_bPaused)
    {
        PrintToChat(client, CHAT_TAG ... "The game is not paused.");
        return Plugin_Handled;
    }

    if (g_bCountingDown)
    {
        PrintToChat(client, CHAT_TAG ... "Resume countdown already in progress...");
        return Plugin_Handled;
    }

    int team = GetClientTeam(client);
    if (team < 2)
    {
        PrintToChat(client, CHAT_TAG ... "You must be on a team to use this command.");
        return Plugin_Handled;
    }

    if (!g_bWaitingUnpause)
    {
        g_bWaitingUnpause = true;

        char playerName[64];
        GetClientName(client, playerName, sizeof(playerName));

        char adversary[32];
        GetTeamName(g_iPauseTeam == 2 ? 3 : 2, adversary, sizeof(adversary));

        PrintToChatAll(CHAT_TAG ... "\x03%s\x01 wants to resume. A player from team \x05%s\x01 must confirm with \x03!unpause\x01.", playerName, adversary);
        return Plugin_Handled;
    }

    int opposingTeam = (g_iPauseTeam == 2) ? 3 : 2;
    if (team != opposingTeam)
    {
        PrintToChat(client, CHAT_TAG ... "Confirmation must come from a player on the opposing team.");
        return Plugin_Handled;
    }

    StopMaxPauseTimer();

    char playerName[64];
    GetClientName(client, playerName, sizeof(playerName));
    PrintToChatAll(CHAT_TAG ... "\x03%s\x01 confirmed. Resuming soon...", playerName);

    g_bWaitingUnpause = false;
    StartCountdown();

    return Plugin_Handled;
}

// ── Max-pause timer ───────────────────────────────────────────────────────────
public Action Timer_MaxPause(Handle timer)
{
    if (!g_bPaused)
    {
        g_hMaxPauseTimer = INVALID_HANDLE;
        return Plugin_Stop;
    }

    g_iTimeRemaining--;

    if (g_iTimeRemaining > 0 && g_iTimeRemaining == g_iNextWarning)
    {
        PrintToChatAll(CHAT_TAG ... "Pause time remaining: \x03%s\x01.", FormatDuration(g_iTimeRemaining));
        g_iNextWarning = ComputeNextWarning(g_iTimeRemaining);
    }

    if (g_iTimeRemaining <= 0)
    {
        g_hMaxPauseTimer = INVALID_HANDLE;
        PrintToChatAll(CHAT_TAG ... "\x07FF4444Maximum pause time reached.\x01 Resuming automatically...");

        if (g_hCountdownTimer != INVALID_HANDLE)
        {
            KillTimer(g_hCountdownTimer);
            g_hCountdownTimer = INVALID_HANDLE;
        }

        StartCountdown();
        return Plugin_Stop;
    }

    return Plugin_Continue;
}

// ── Resume countdown ──────────────────────────────────────────────────────────
void StartCountdown()
{
    g_bCountingDown = true;
    g_iCountdown    = 5;

    if (g_hCountdownTimer != INVALID_HANDLE)
    {
        KillTimer(g_hCountdownTimer);
        g_hCountdownTimer = INVALID_HANDLE;
    }

    PrintToChatAll(CHAT_TAG ... "Game resumes in \x03%d\x01...", g_iCountdown);
    PrintCenterTextAll("RESUMING IN\n\n%d", g_iCountdown);

    g_hCountdownTimer = CreateTimer(1.0, Timer_Countdown, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_Countdown(Handle timer)
{
    g_iCountdown--;

    if (g_iCountdown > 0)
    {
        PrintToChatAll(CHAT_TAG ... "Game resumes in \x03%d\x01...", g_iCountdown);
        PrintCenterTextAll("RESUMING IN\n\n%d", g_iCountdown);
        return Plugin_Continue;
    }

    PrintToChatAll(CHAT_TAG ... "\x05GO GO GO!\x01 Game resumed!");
    PrintCenterTextAll("GO GO GO!");

    g_hCountdownTimer = INVALID_HANDLE;

    DoEngineUnpause();
    UnfreezeAllPlayers();
    SendFadeAll(false);
    SetCaptureAreasEnabled(true);
    RestoreTimeleft();
    StopCenterText();
    ResetState();

    return Plugin_Stop;
}

// ── Center text ───────────────────────────────────────────────────────────────
void StartCenterText()
{
    StopCenterText();
    ShowPauseCenterText();
    g_hCenterTextTimer = CreateTimer(0.75, Timer_CenterText, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

void StopCenterText()
{
    if (g_hCenterTextTimer != INVALID_HANDLE)
    {
        KillTimer(g_hCenterTextTimer);
        g_hCenterTextTimer = INVALID_HANDLE;
    }
}

public Action Timer_CenterText(Handle timer)
{
    if (!g_bPaused || g_bCountingDown)
    {
        g_hCenterTextTimer = INVALID_HANDLE;
        return Plugin_Stop;
    }

    ShowPauseCenterText();
    return Plugin_Continue;
}

void ShowPauseCenterText()
{
    int maxTime = g_cvMaxPauseTime.IntValue;

    if (maxTime > 0 && g_iTimeRemaining > 0)
        PrintCenterTextAll("** PAUSED **\n\n%s remaining\n\nType !unpause to resume", FormatDuration(g_iTimeRemaining));
    else
        PrintCenterTextAll("** PAUSED **\n\nType !unpause to resume");
}

// ── Screen fade ───────────────────────────────────────────────────────────────
void SendFade(int client, bool blacken)
{
    Handle msg = StartMessageOne("Fade", client, USERMSG_RELIABLE);
    if (msg == INVALID_HANDLE)
        return;

    if (blacken)
    {
        BfWriteShort(msg, 0);                        // duration: instant
        BfWriteShort(msg, 99999);                    // holdtime: permanent until cleared
        BfWriteShort(msg, FFADE_OUT | FFADE_STAYOUT);
        BfWriteByte(msg, 0);                         // R
        BfWriteByte(msg, 0);                         // G
        BfWriteByte(msg, 0);                         // B
        BfWriteByte(msg, 255);                       // A: fully opaque
    }
    else
    {
        BfWriteShort(msg, 500);                      // duration: 500ms fade back to normal
        BfWriteShort(msg, 0);                        // holdtime: none
        BfWriteShort(msg, FFADE_IN | FFADE_PURGE);   // clear held fade and fade back
        BfWriteByte(msg, 0);
        BfWriteByte(msg, 0);
        BfWriteByte(msg, 0);
        BfWriteByte(msg, 0);                         // A: transparent
    }

    EndMessage();
}

void SendFadeAll(bool blacken)
{
    for (int i = 1; i <= MaxClients; i++)
        if (IsClientInGame(i) && !IsFakeClient(i))
            SendFade(i, blacken);
}

// ── Freeze / Unfreeze ─────────────────────────────────────────────────────────
void FreezePlayer(int client)
{
    // FL_FROZEN blocks actions (shooting, reloading, etc.)
    int flags = GetEntProp(client, Prop_Send, "m_fFlags");
    SetEntProp(client, Prop_Send, "m_fFlags", flags | FL_FROZEN);

    // MOVETYPE_NONE blocks all movement
    g_SavedMoveType[client] = GetEntityMoveType(client);
    SetEntityMoveType(client, MOVETYPE_NONE);

    // Zero velocity so the player stops immediately
    float zero[3] = {0.0, 0.0, 0.0};
    TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, zero);
}

void UnfreezePlayer(int client)
{
    // Restore FL_FROZEN
    int flags = GetEntProp(client, Prop_Send, "m_fFlags");
    SetEntProp(client, Prop_Send, "m_fFlags", flags & ~FL_FROZEN);

    // Restore move type
    MoveType saved = g_SavedMoveType[client];
    SetEntityMoveType(client, (saved != MOVETYPE_NONE) ? saved : MOVETYPE_WALK);
}

void FreezeAllPlayers()
{
    for (int i = 1; i <= MaxClients; i++)
        if (IsClientInGame(i) && IsPlayerAlive(i))
            FreezePlayer(i);
}

void UnfreezeAllPlayers()
{
    for (int i = 1; i <= MaxClients; i++)
        if (IsClientInGame(i) && IsPlayerAlive(i))
            UnfreezePlayer(i);
}

// ── Timeleft freeze ───────────────────────────────────────────────────────────
void FreezeTimeleft()
{
    if (g_cvMpTimelimit.FloatValue <= 0.0)
        return;

    g_cvMpTimelimit.FloatValue = 9999.0;
}

void RestoreTimeleft()
{
    if (g_iTimeleftAtPause <= 0)
        return;

    int restoreSeconds = g_iTimeleftAtPause - 5;
    if (restoreSeconds < 10)
        restoreSeconds = 10;

    float newLimit = (GetEngineTime() / 60.0) + (float(restoreSeconds) / 60.0);
    g_cvMpTimelimit.FloatValue = newLimit;
}

// ── Debug: list dod_ entities ────────────────────────────────────────────────
public Action Cmd_ListEnts(int client, int argc)
{
    int count = 0;
    int ent = -1;

    char classname[64];
    char targetname[64];

    // Iterate all entities and print dod_ ones
    while ((ent = FindEntityByClassname(ent, "dod_*")) != -1)
    {
        GetEntityClassname(ent, classname, sizeof(classname));
        GetEntPropString(ent, Prop_Data, "m_iName", targetname, sizeof(targetname));
        PrintToServer("[DODSG Debug] ent %d: classname=%s targetname=%s", ent, classname, targetname);
        if (client > 0)
            PrintToChat(client, " [Debug] ent %d: %s (%s)", ent, classname, targetname);
        count++;
    }

    PrintToServer("[DODSG Debug] Total dod_ entities: %d", count);
    ReplyToCommand(client, "[DODSG Debug] Found %d dod_ entities. Check server console.", count);
    return Plugin_Handled;
}

// ── Capture area control ──────────────────────────────────────────────────────
void SetCaptureAreasEnabled(bool enable)
{
    char input[8];
    if (enable)
        strcopy(input, sizeof(input), "Enable");
    else
        strcopy(input, sizeof(input), "Disable");

    int ent = -1;

    // Disable capture zones (stops flag captures)
    while ((ent = FindEntityByClassname(ent, "dod_capture_area")) != -1)
    {
        SetVariantString("");
        AcceptEntityInput(ent, input);
    }

    // Disable control point master (stops tickpoints logic)
    // Also use mp_tickpointinterval as a backup to prevent point awards
    ent = -1;
    while ((ent = FindEntityByClassname(ent, "dod_control_point_master")) != -1)
    {
        SetVariantString("");
        AcceptEntityInput(ent, input);

        if (!enable)
        {
            // Push the next give-points time far into the future as backup
            // SetEntPropFloat: m_fGivePointsTime is a server-side float on this entity
            SetEntPropFloat(ent, Prop_Data, "m_fGivePointsTime", GetGameTime() + 99999.0);
        }
    }

    // Also set mp_tickpointinterval to a huge value as a final safety net
    if (g_cvTickPointInterval != INVALID_HANDLE)
    {
        if (!enable)
            g_cvTickPointInterval.FloatValue = 99999.0;
        else
            g_cvTickPointInterval.FloatValue = 30.0; // default value
    }
}

// ── Config ────────────────────────────────────────────────────────────────────
void LoadConfig()
{
    char configPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, configPath, sizeof(configPath), "configs/dodsg_pause.cfg");

    if (!FileExists(configPath))
    {
        PrintToServer("[DODSG Pause] Config not found, creating default: %s", configPath);
        CreateDefaultConfig(configPath);
    }

    // Read values directly from the cfg file line by line (synchronous)
    // ServerCommand("exec ...") is async and would apply values too late
    File f = OpenFile(configPath, "r");
    if (f == null)
    {
        PrintToServer("[DODSG Pause] ERROR: Could not open config file: %s", configPath);
        return;
    }

    char line[256];
    while (f.ReadLine(line, sizeof(line)))
    {
        TrimString(line);

        // Skip comments and empty lines
        if (line[0] == '/' || line[0] == '\0')
            continue;

        char key[64];
        char value[64];

        // Parse "key \"value\"" format
        int spacePos = FindCharInString(line, ' ');
        if (spacePos == -1)
            continue;

        strcopy(key, spacePos + 1, line);
        strcopy(value, sizeof(value), line[spacePos + 1]);
        TrimString(value);

        // Strip surrounding quotes if present
        int vlen = strlen(value);
        if (vlen >= 2 && value[0] == '"' && value[vlen - 1] == '"')
        {
            strcopy(value, vlen - 1, value[1]);
            vlen -= 2;
        }

        if (StrEqual(key, "dodsg_pause_maxtime"))
            g_cvMaxPauseTime.IntValue = StringToInt(value);
        else if (StrEqual(key, "dodsg_pause_warntime"))
            g_cvWarningInterval.IntValue = StringToInt(value);
    }

    delete f;

    PrintToServer("[DODSG Pause] Config loaded — maxtime: %d, warntime: %d",
        g_cvMaxPauseTime.IntValue, g_cvWarningInterval.IntValue);
}

void CreateDefaultConfig(const char[] path)
{
    File f = OpenFile(path, "w");
    if (f == null)
    {
        PrintToServer("[DODSG Pause] ERROR: Could not create config file: %s", path);
        return;
    }

    f.WriteLine("// DODSG Pause - Configuration file");
    f.WriteLine("// Location: addons/sourcemod/configs/dodsg_pause.cfg");
    f.WriteLine("");
    f.WriteLine("// Maximum pause duration in seconds. Set to 0 for unlimited.");
    f.WriteLine("// Default: 300 (5 minutes)");
    f.WriteLine("dodsg_pause_maxtime \"300\"");
    f.WriteLine("");
    f.WriteLine("// Interval in seconds between remaining-time announcements in chat.");
    f.WriteLine("// Minimum: 10  Default: 60");
    f.WriteLine("dodsg_pause_warntime \"60\"");

    delete f;

    PrintToServer("[DODSG Pause] Created default config file: %s", path);
}

// ── Engine pause / unpause ────────────────────────────────────────────────────
void DoEnginePause()
{
    g_cvSvPausable.IntValue = 1;
    ServerCommand("pause");
    RequestFrame(Frame_LockPausable, 0);
}

void DoEngineUnpause()
{
    g_cvSvPausable.IntValue = 1;
    ServerCommand("unpause");
    RequestFrame(Frame_LockPausable, 0);
}

public void Frame_LockPausable(any data)
{
    g_cvSvPausable.IntValue = 0;
}

// ── Helpers ───────────────────────────────────────────────────────────────────
bool IsValidPausableClient(int client)
{
    return (client > 0 && client <= MaxClients && IsClientInGame(client) && IsPlayerAlive(client) && !IsFakeClient(client));
}

void StopMaxPauseTimer()
{
    if (g_hMaxPauseTimer != INVALID_HANDLE)
    {
        KillTimer(g_hMaxPauseTimer);
        g_hMaxPauseTimer = INVALID_HANDLE;
    }
    g_iTimeRemaining = 0;
    g_iNextWarning   = 0;
}

int ComputeNextWarning(int currentSeconds)
{
    int interval = g_cvWarningInterval.IntValue;
    if (interval <= 0)
        return 0;

    int next = (currentSeconds / interval) * interval;
    if (next >= currentSeconds)
        next -= interval;

    return (next > 0) ? next : 0;
}

char[] FormatDuration(int seconds)
{
    char buf[32];
    int m = seconds / 60;
    int s = seconds % 60;

    if (m > 0 && s > 0)
        Format(buf, sizeof(buf), "%dm %ds", m, s);
    else if (m > 0)
        Format(buf, sizeof(buf), "%dm", m);
    else
        Format(buf, sizeof(buf), "%ds", s);

    return buf;
}

void ResetState()
{
    g_bPaused          = false;
    g_bWaitingUnpause  = false;
    g_bCountingDown    = false;
    g_iPauseTeam       = -1;
    g_iCountdown       = 0;
    g_iTimeleftAtPause = 0;

    StopMaxPauseTimer();
    StopCenterText();

    if (g_hCountdownTimer != INVALID_HANDLE)
    {
        KillTimer(g_hCountdownTimer);
        g_hCountdownTimer = INVALID_HANDLE;
    }
}
