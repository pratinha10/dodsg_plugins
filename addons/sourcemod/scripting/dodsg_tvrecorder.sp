#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

bool g_bRecording = false;
bool g_bMatchLive = false;
ConVar g_cvWarmupTime;
ConVar g_cvTvEnable;
char g_sCurrentDemoFile[256];

public Plugin myinfo = 
{
    name = "DoD:S Competitive Demo Recorder",
    author = "pratinha",
    description = "Records demos automatically for 6v6 matches after mp_clan_readyrestart",
    version = "2.3.0",
    url = "https://github.com/pratinha10/dodsg_plugins"
};

public void OnPluginStart()
{
    // Hook commands
    RegServerCmd("mp_clan_readyrestart", Command_ReadyRestart);
    RegServerCmd("mp_restartgame", Command_RestartGame);
    RegServerCmd("mp_restartwarmup", Command_RestartWarmup);
    
    // Hook only essential events
    HookEvent("dod_warmup_ends", Event_WarmupEnds, EventHookMode_Post);
    
    // Admin commands
    RegAdminCmd("dodsg_startdemo", Command_StartDemo, ADMFLAG_RCON, "Force start demo recording");
    RegAdminCmd("dodsg_stopdemo", Command_StopDemo, ADMFLAG_RCON, "Force stop demo recording");
    RegAdminCmd("dodsg_demostatus", Command_DemoStatus, ADMFLAG_RCON, "Check demo recording status");
    
    // Cache ConVars
    g_cvWarmupTime = FindConVar("mp_warmup_time");
    g_cvTvEnable = FindConVar("tv_enable");
    
    PrintToServer("[DODSG TV Recorder] v2.3.0 loaded - Optimized");
}

public void OnConfigsExecuted()
{
    CreateDemosDirectory();
    
    if (g_cvTvEnable == null)
    {
        LogError("[DODSG TV Recorder] ERROR: tv_enable ConVar not found!");
        return;
    }
    
    // Check SourceTV bot existence
    if (!IsSourceTVActive())
    {
        g_cvTvEnable.SetInt(1);
        ServerCommand("tv_enable 1");
        CreateTimer(3.0, Timer_ReloadMap, _, TIMER_FLAG_NO_MAPCHANGE);
        return;
    }
    
    ConfigureSourceTV();
}

bool IsSourceTVActive()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientConnected(i) && IsClientSourceTV(i))
            return true;
    }
    return false;
}

void ConfigureSourceTV()
{
    ServerCommand("tv_autorecord 0");
    ServerCommand("tv_snapshotrate 64");
    ServerCommand("tv_maxrate 16000");
    ServerCommand("tv_transmitall 1");
    ServerCommand("tv_delay 30");
    ServerCommand("tv_name \"DODSG TV\"");
}

void CreateDemosDirectory()
{
    char demosPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, demosPath, sizeof(demosPath), "../../demos");
    
    if (!DirExists(demosPath))
        CreateDirectory(demosPath, 511);
}

public Action Timer_ReloadMap(Handle timer)
{
    char currentMap[64];
    GetCurrentMap(currentMap, sizeof(currentMap));
    ServerCommand("changelevel %s", currentMap);
    return Plugin_Stop;
}

// ══════════════════════════════════════════════════════════
// COMMAND HOOKS
// ══════════════════════════════════════════════════════════

public Action Command_ReadyRestart(int args)
{
    return Plugin_Continue;
}

public Action Command_RestartGame(int args)
{
    if (g_bRecording)
        StopAndDeleteRecording();
    return Plugin_Continue;
}

public Action Command_RestartWarmup(int args)
{
    if (g_bRecording)
        StopAndDeleteRecording();
    return Plugin_Continue;
}

// ══════════════════════════════════════════════════════════
// EVENT HOOKS
// ══════════════════════════════════════════════════════════

public void Event_WarmupEnds(Event event, const char[] name, bool dontBroadcast)
{
    if (g_bRecording)
    {
        StopAndDeleteRecording();
        CreateTimer(1.5, Timer_StartNewRecording, _, TIMER_FLAG_NO_MAPCHANGE);
    }
    else
    {
        RequestFrame(Frame_StartRecording);
    }
}

public void Frame_StartRecording(any data)
{
    StartRecording();
}

public Action Timer_StartNewRecording(Handle timer)
{
    StartRecording();
    return Plugin_Stop;
}

void StartRecording()
{
    char mapName[64], timestamp[64], demoName[256];
    
    GetCurrentMap(mapName, sizeof(mapName));
    FormatTime(timestamp, sizeof(timestamp), "%d-%m-%Y_%H%M%S", GetTime());
    Format(demoName, sizeof(demoName), "%s-%s", timestamp, mapName);
    Format(g_sCurrentDemoFile, sizeof(g_sCurrentDemoFile), "demos/%s", demoName);
    
    ServerCommand("tv_record \"demos/%s\"", demoName);
    g_bRecording = true;
    g_bMatchLive = true;
    
    PrintToServer("[DODSG TV Recorder] Recording: %s.dem", demoName);
}

void StopRecording()
{
    if (!g_bRecording)
        return;
    
    ServerCommand("tv_stoprecord");
    g_bRecording = false;
    g_bMatchLive = false;
    g_sCurrentDemoFile[0] = '\0';
}

void StopAndDeleteRecording()
{
    if (!g_bRecording)
        return;
    
    ServerCommand("tv_stoprecord");
    g_bRecording = false;
    g_bMatchLive = false;
    
    CreateTimer(1.0, Timer_DeleteDemo, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_DeleteDemo(Handle timer)
{
    if (g_sCurrentDemoFile[0] == '\0')
        return Plugin_Stop;
    
    char demoPath[PLATFORM_MAX_PATH];
    Format(demoPath, sizeof(demoPath), "%s.dem", g_sCurrentDemoFile);
    
    if (FileExists(demoPath))
        DeleteFile(demoPath);
    
    g_sCurrentDemoFile[0] = '\0';
    return Plugin_Stop;
}

public void OnMapEnd()
{
    if (g_bRecording)
        StopRecording();
}

// ══════════════════════════════════════════════════════════
// ADMIN COMMANDS
// ══════════════════════════════════════════════════════════

public Action Command_StartDemo(int client, int args)
{
    if (g_bRecording)
    {
        ReplyToCommand(client, "[DODSG TV Recorder] Recording already active!");
        return Plugin_Handled;
    }
    
    StartRecording();
    ReplyToCommand(client, "[DODSG TV Recorder] Recording started");
    return Plugin_Handled;
}

public Action Command_StopDemo(int client, int args)
{
    if (!g_bRecording)
    {
        ReplyToCommand(client, "[DODSG TV Recorder] No active recording!");
        return Plugin_Handled;
    }
    
    StopRecording();
    ReplyToCommand(client, "[DODSG TV Recorder] Recording stopped");
    return Plugin_Handled;
}

public Action Command_DemoStatus(int client, int args)
{
    ReplyToCommand(client, "[DODSG TV Recorder] ═══════════════════════════════");
    ReplyToCommand(client, "Status: %s", g_bRecording ? "RECORDING" : "STOPPED");
    ReplyToCommand(client, "Match Live: %s", g_bMatchLive ? "YES" : "NO");
    
    if (g_bRecording && g_sCurrentDemoFile[0] != '\0')
        ReplyToCommand(client, "File: %s.dem", g_sCurrentDemoFile);
    
    if (g_cvWarmupTime != null)
    {
        int warmupTime = g_cvWarmupTime.IntValue;
        ReplyToCommand(client, "Warmup: %d (%s)", warmupTime, 
                      (warmupTime != -1 && warmupTime != 0) ? "ACTIVE" : "MATCH LIVE");
    }
    
    if (g_cvTvEnable != null)
        ReplyToCommand(client, "tv_enable: %d", g_cvTvEnable.IntValue);
    
    ReplyToCommand(client, "SourceTV Bot: %s", IsSourceTVActive() ? "CONNECTED" : "NOT FOUND");
    ReplyToCommand(client, "[DODSG TV Recorder] ═══════════════════════════════");
    
    return Plugin_Handled;
}