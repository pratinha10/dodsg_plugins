/*
 * DoD:S ConVar Enforcer
 * 
 * Description:
 *   Monitors and enforces client console variable (CVar) values in Day of Defeat: Source.
 *   Automatically checks player CVars at regular intervals and applies warnings/punishments
 *   for invalid values. Supports multiple checking modes including exact match, range validation,
 *   and min/max limits.
 * 
 * Features:
 *   - Periodic CVar checking with configurable intervals
 *   - Multiple validation modes (equal, not equal, range, min, max)
 *   - Warning system with configurable attempts before punishment
 *   - Public violation alerts visible to all players
 *   - Kick or temporary ban punishments
 *   - Easy configuration via KeyValues file
 * 
 * Commands:
 *   sm_dodsg_test      - Display plugin configuration (ROOT)
 *   sm_dodsg_reload    - Reload configuration file (ROOT)
 *   sm_dodsg_check     - Check specific player's CVars (ADMIN)
 *   sm_dodsg_testmsg   - Test violation message in chat (SERVER CONSOLE)
 * 
 * ConVars:
 *   sm_dodsg_timer     - CVar check interval in seconds (default: 10.0)
 *   sm_dodsg_warn      - Number of warnings before punishment (default: 3)
 * 
 * Configuration:
 *   File: addons/sourcemod/configs/dodsg_cvar_checker.cfg
 * 
 * Author: pratinha
 * Version: 2.0.0
 * URL: https://github.com/pratinha10/dodsg_plugins
 */

#include <sourcemod>
#include <sdktools>

#pragma newdecls required
#pragma semicolon 1

#define PLUGIN_VERSION "2.0.0"
#define MAX_CVARS 1000
#define MAX_PATH_LENGTH 256

// Color definitions for Source games
#define COLOR_DEFAULT "\x01"
#define COLOR_TEAMCOLOR "\x03"
#define COLOR_GREEN "\x04"
#define COLOR_OLIVE "\x05"

// Structure to store CVar data
enum struct CvarData
{
    char name[MAX_PATH_LENGTH];
    char value[MAX_PATH_LENGTH];
    char minValue[MAX_PATH_LENGTH];
    char maxValue[MAX_PATH_LENGTH];
    int mode;
    int punishment;
    int banTime;
}

// Global variables
ArrayList g_CvarList;
int g_iPlayerWarnings[MAXPLAYERS + 1];
Handle g_hCheckTimer;

// ConVars
ConVar g_cvCheckTimer;
ConVar g_cvMaxWarnings;

public Plugin myinfo =
{
    name = "DoD:S ConVar Enforcer",
    author = "pratinha",
    version = PLUGIN_VERSION,
    description = "Check and enforce client console variable rules",
    url = "https://github.com/pratinha10/dodsg_plugins"
};

public void OnPluginStart()
{
    // Create ConVars
    g_cvCheckTimer = CreateConVar("sm_dodsg_timer", "10.0", "CVar check interval (seconds)", FCVAR_NOTIFY, true, 5.0, true, 60.0);
    g_cvMaxWarnings = CreateConVar("sm_dodsg_warn", "3", "Number of warnings before punishment", FCVAR_NOTIFY, true, 0.0, true, 10.0);
    
    // Hook for changes
    g_cvCheckTimer.AddChangeHook(OnConVarChanged);
    g_cvMaxWarnings.AddChangeHook(OnConVarChanged);
    
    // Admin commands
    RegAdminCmd("sm_dodsg_test", Command_Test, ADMFLAG_ROOT, "Test plugin configuration");
    RegAdminCmd("sm_dodsg_reload", Command_Reload, ADMFLAG_ROOT, "Reload configuration");
    RegAdminCmd("sm_dodsg_check", Command_CheckPlayer, ADMFLAG_GENERIC, "Check specific player");
    RegServerCmd("sm_dodsg_testmsg", Command_TestMessage, "Test violation message in chat");
    
    // Auto-execute config
    AutoExecConfig(true, "dodsg_cvar_checker");
    
    // Initialize ArrayList
    g_CvarList = new ArrayList(sizeof(CvarData));
}

public void OnConfigsExecuted()
{
    LoadConfiguration();
    StartCheckTimer();
}

public void OnMapStart()
{
    StartCheckTimer();
}

public void OnMapEnd()
{
    StopCheckTimer();
}

void StartCheckTimer()
{
    StopCheckTimer();
    float interval = g_cvCheckTimer.FloatValue;
    g_hCheckTimer = CreateTimer(interval, Timer_CheckCvars, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

void StopCheckTimer()
{
    delete g_hCheckTimer;
}

void LoadConfiguration()
{
    char configPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, configPath, sizeof(configPath), "configs/dodsg_cvar_checker.cfg");
    
    if (!FileExists(configPath))
    {
        LogError("Configuration file not found: %s", configPath);
        return;
    }
    
    // Clear existing list
    g_CvarList.Clear();
    
    KeyValues kv = new KeyValues("cvar");
    
    if (!kv.ImportFromFile(configPath))
    {
        LogError("Failed to load configuration file");
        delete kv;
        return;
    }
    
    if (kv.GotoFirstSubKey())
    {
        do
        {
            CvarData data;
            
            kv.GetSectionName(data.name, sizeof(CvarData::name));
            kv.GetString("value", data.value, sizeof(CvarData::value), "");
            kv.GetString("min", data.minValue, sizeof(CvarData::minValue), "");
            kv.GetString("max", data.maxValue, sizeof(CvarData::maxValue), "");
            data.mode = kv.GetNum("mode", 0);
            data.punishment = kv.GetNum("punishment", 1);
            data.banTime = kv.GetNum("bantime", 0);
            
            g_CvarList.PushArray(data);
        }
        while (kv.GotoNextKey());
    }
    
    delete kv;
    
    // Reset warnings
    ResetAllWarnings();
    
    LogMessage("Configuration loaded: %d cvars monitored", g_CvarList.Length);
}

void ResetAllWarnings()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        g_iPlayerWarnings[i] = 0;
    }
}

public Action Timer_CheckCvars(Handle timer)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsValidClient(client))
        {
            CheckClientCvars(client);
        }
    }
    
    return Plugin_Continue;
}

void CheckClientCvars(int client)
{
    int length = g_CvarList.Length;
    
    for (int i = 0; i < length; i++)
    {
        CvarData data;
        g_CvarList.GetArray(i, data);
        
        QueryClientConVar(client, data.name, OnCvarQueried, i);
    }
}

public void OnCvarQueried(QueryCookie cookie, int client, ConVarQueryResult result, const char[] cvarName, const char[] cvarValue, int cvarIndex)
{
    if (!IsValidClient(client))
        return;
    
    if (result != ConVarQuery_Okay)
    {
        HandleQueryError(result, cvarName);
        return;
    }
    
    CvarData data;
    g_CvarList.GetArray(cvarIndex, data);
    
    // Check if value is incorrect
    bool isViolation = false;
    
    switch (data.mode)
    {
        case 0: // Must be equal
        {
            isViolation = !StrEqual(cvarValue, data.value);
        }
        case 1: // Must be different
        {
            isViolation = StrEqual(cvarValue, data.value);
        }
        case 2: // Must be within range (min-max)
        {
            if (data.minValue[0] != '\0' && data.maxValue[0] != '\0')
            {
                float currentValue = StringToFloat(cvarValue);
                float minVal = StringToFloat(data.minValue);
                float maxVal = StringToFloat(data.maxValue);
                
                isViolation = (currentValue < minVal || currentValue > maxVal);
            }
        }
        case 3: // Must be less than or equal
        {
            if (data.value[0] != '\0')
            {
                float currentValue = StringToFloat(cvarValue);
                float maxVal = StringToFloat(data.value);
                
                isViolation = (currentValue > maxVal);
            }
        }
        case 4: // Must be greater than or equal
        {
            if (data.value[0] != '\0')
            {
                float currentValue = StringToFloat(cvarValue);
                float minVal = StringToFloat(data.value);
                
                isViolation = (currentValue < minVal);
            }
        }
    }
    
    if (isViolation)
    {
        HandleViolation(client, cvarName, cvarValue, data);
    }
}

void HandleViolation(int client, const char[] cvarName, const char[] cvarValue, CvarData data)
{
    g_iPlayerWarnings[client]++;
    
    int maxWarnings = g_cvMaxWarnings.IntValue;
    int remainingWarnings = maxWarnings - g_iPlayerWarnings[client];
    
    char clientName[MAX_NAME_LENGTH];
    GetClientName(client, clientName, sizeof(clientName));
    
    // Warn player privately
    if (remainingWarnings > 0)
    {
        PrintToChat(client, "%s[DODSG]%s %sWarning%s: CVar %s%s%s is %s%s%s. Fix it or be kicked! (%s%d%s warnings left)", 
            COLOR_TEAMCOLOR, COLOR_DEFAULT, COLOR_TEAMCOLOR, COLOR_DEFAULT, 
            COLOR_GREEN, cvarName, COLOR_DEFAULT, COLOR_TEAMCOLOR, cvarValue, COLOR_DEFAULT, 
            COLOR_OLIVE, remainingWarnings, COLOR_DEFAULT);
    }
    else if (remainingWarnings == 0)
    {
        PrintToChat(client, "%s[DODSG]%s %sFinal Warning%s: CVar %s%s%s is %s%s%s. You will be punished in %s%.0f%s seconds!", 
            COLOR_TEAMCOLOR, COLOR_DEFAULT, COLOR_TEAMCOLOR, COLOR_DEFAULT, 
            COLOR_GREEN, cvarName, COLOR_DEFAULT, COLOR_TEAMCOLOR, cvarValue, COLOR_DEFAULT, 
            COLOR_OLIVE, g_cvCheckTimer.FloatValue, COLOR_DEFAULT);
    }
    
    // Notify everyone in the server with eye-catching colors
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsValidClient(i))
        {
            PrintToChat(i, "%s[DODSG]%s %s⚠ ALERT ⚠%s Player %s%s%s has invalid CVar %s%s%s = %s%s%s (%s%d%s warnings left)", 
                COLOR_TEAMCOLOR, COLOR_DEFAULT, COLOR_TEAMCOLOR, COLOR_DEFAULT, 
                COLOR_OLIVE, clientName, COLOR_DEFAULT, COLOR_GREEN, cvarName, COLOR_DEFAULT, 
                COLOR_TEAMCOLOR, cvarValue, COLOR_DEFAULT, COLOR_OLIVE, remainingWarnings, COLOR_DEFAULT);
        }
    }
    
    // Apply punishment if needed
    if (g_iPlayerWarnings[client] > maxWarnings)
    {
        ApplyPunishment(client, cvarName, cvarValue, data);
    }
}

void ApplyPunishment(int client, const char[] cvarName, const char[] cvarValue, CvarData data)
{
    char reason[512];
    
    switch (data.punishment)
    {
        case 1: // Kick
        {
            Format(reason, sizeof(reason), "Invalid CVar: %s = %s", cvarName, cvarValue);
            KickClient(client, "%s", reason);
        }
        case 2: // Ban
        {
            Format(reason, sizeof(reason), "Invalid CVar: %s = %s", cvarName, cvarValue);
            char kickReason[512];
            Format(kickReason, sizeof(kickReason), "Banned for invalid CVar: %s = %s", cvarName, cvarValue);
            
            BanClient(client, data.banTime, BANFLAG_AUTO, reason, kickReason, "sm_dodsg");
        }
    }
}

void NotifyAdmins(const char[] clientName, const char[] cvarName, const char[] cvarValue)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsValidClient(i) && IsAdmin(i))
        {
            CPrintToChat(i, "[DODSG] {red}Alert{default}: Player {green}%s{default} has invalid CVar {yellow}%s{default} = {red}%s{default}", clientName, cvarName, cvarValue);
        }
    }
}

void HandleQueryError(ConVarQueryResult result, const char[] cvarName)
{
    switch (result)
    {
        case ConVarQuery_NotFound:
            LogError("Client CVar not found: %s", cvarName);
        case ConVarQuery_NotValid:
            LogError("Console command found but not a CVar: %s", cvarName);
        case ConVarQuery_Protected:
            LogError("CVar is protected, cannot retrieve value: %s", cvarName);
    }
}

public void OnClientPutInServer(int client)
{
    g_iPlayerWarnings[client] = 0;
}

public void OnClientDisconnect(int client)
{
    g_iPlayerWarnings[client] = 0;
}

public void OnConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (convar == g_cvCheckTimer)
    {
        StartCheckTimer();
    }
    else if (convar == g_cvMaxWarnings)
    {
        ResetAllWarnings();
    }
}

// ========== COMANDOS ==========

public Action Command_Test(int client, int args)
{
    if (!client || IsFakeClient(client))
        return Plugin_Handled;
    
    int length = g_CvarList.Length;
    PrintToConsole(client, "=== Client ConVar Checker Configuration ===");
    PrintToConsole(client, "Total monitored CVars: %d", length);
    
    for (int i = 0; i < length; i++)
    {
        CvarData data;
        g_CvarList.GetArray(i, data);
        
        PrintToConsole(client, "[%d] %s | Value: %s | Min: %s | Max: %s | Mode: %d | Punishment: %d | Ban: %dm",
            i + 1, data.name, data.value, 
            data.minValue[0] ? data.minValue : "N/A",
            data.maxValue[0] ? data.maxValue : "N/A",
            data.mode, data.punishment, data.banTime);
    }
    
    PrintToChat(client, "Information sent to console.");
    return Plugin_Handled;
}

public Action Command_Reload(int client, int args)
{
    LoadConfiguration();
    
    if (client)
        PrintToChat(client, "%s[DODSG]%s Configuration reloaded successfully!", COLOR_TEAMCOLOR, COLOR_DEFAULT);
    
    return Plugin_Handled;
}

public Action Command_CheckPlayer(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "%s[DODSG]%s Usage: sm_dodsg_check <name|#userid>", COLOR_TEAMCOLOR, COLOR_DEFAULT);
        return Plugin_Handled;
    }
    
    char arg[64];
    GetCmdArg(1, arg, sizeof(arg));
    
    int target = FindTarget(client, arg, true, false);
    if (target == -1)
        return Plugin_Handled;
    
    CheckClientCvars(target);
    
    char targetName[MAX_NAME_LENGTH];
    GetClientName(target, targetName, sizeof(targetName));
    ReplyToCommand(client, "%s[DODSG]%s Checking %s's CVars...", COLOR_TEAMCOLOR, COLOR_DEFAULT, targetName);
    
    return Plugin_Handled;
}

public Action Command_TestMessage(int args)
{
    // Send test violation message to all players in the server
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsValidClient(i))
        {
            PrintToChat(i, "%s[DODSG]%s %s⚠ ALERT ⚠%s Player %sTestPlayer%s has invalid CVar %sr_shadows%s = %s1%s (%s2%s warnings left)", 
                COLOR_TEAMCOLOR, COLOR_DEFAULT, COLOR_TEAMCOLOR, COLOR_DEFAULT, 
                COLOR_OLIVE, COLOR_DEFAULT, COLOR_GREEN, COLOR_DEFAULT, 
                COLOR_TEAMCOLOR, COLOR_DEFAULT, COLOR_OLIVE, COLOR_DEFAULT);
        }
    }
    
    PrintToServer("[DODSG] Test violation message sent to all players in chat!");
    
    return Plugin_Handled;
}

// ========== HELPER FUNCTIONS ==========

bool IsValidClient(int client)
{
    return (client > 0 && client <= MaxClients && IsClientConnected(client) && IsClientInGame(client) && !IsFakeClient(client));
}