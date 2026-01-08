/**
* DoD:S Sprint Exploit Fix by pratinha
*
* Description:
*   Fixes the stamina sprint exploit - adds penalty to sprint+forward pattern
*
* Version 2.1
* Changelog & more info at https://github.com/pratinha10/dodgs_plugin
*/
#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma semicolon 1
#pragma newdecls required

// Offset for stamina in DoD:S
int g_iStaminaOffset = -1;

// Stores last stamina to detect when it recovered
float g_flLastStamina[MAXPLAYERS + 1];
bool g_bJustRecovered[MAXPLAYERS + 1];
bool g_bSprintFirstDetected[MAXPLAYERS + 1];

// Track previous button state to detect order
int g_iPreviousButtons[MAXPLAYERS + 1];

public Plugin myinfo = 
{
    name = "DoD:S Sprint Exploit Fix",
    author = "pratinha",
    description = "Fixes stamina sprint exploits",
    version = "2.1",
    url = "https://github.com/pratinha10/dodgs_plugin"
};

public void OnPluginStart()
{
    g_iStaminaOffset = FindSendPropInfo("CDODPlayer", "m_flStamina");
    
    if (g_iStaminaOffset == -1)
    {
        SetFailState("Could not find m_flStamina offset!");
    }
    
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            SDKHook(i, SDKHook_PreThink, Hook_PreThink);
        }
    }
}

public void OnClientPutInServer(int client)
{
    g_flLastStamina[client] = 100.0;
    g_bJustRecovered[client] = false;
    g_bSprintFirstDetected[client] = false;
    g_iPreviousButtons[client] = 0;
    SDKHook(client, SDKHook_PreThink, Hook_PreThink);
}

public void OnClientDisconnect(int client)
{
    g_flLastStamina[client] = 100.0;
    g_bJustRecovered[client] = false;
    g_bSprintFirstDetected[client] = false;
    g_iPreviousButtons[client] = 0;
    SDKUnhook(client, SDKHook_PreThink, Hook_PreThink);
}

public void Hook_PreThink(int client)
{
    if (!IsPlayerAlive(client))
        return;
    
    int buttons = GetClientButtons(client);
    int prevButtons = g_iPreviousButtons[client];
    
    float stamina = GetEntDataFloat(client, g_iStaminaOffset);
    
    // Detect button press order
    bool justPressedForward = (buttons & IN_FORWARD) && !(prevButtons & IN_FORWARD);
    bool justPressedSprint = (buttons & IN_SPEED) && !(prevButtons & IN_SPEED);
    bool hadForward = (prevButtons & IN_FORWARD);
    bool hadSprint = (prevButtons & IN_SPEED);
    
    // Track if player pressed SPRINT first, then FORWARD (exploit pattern)
    if (justPressedForward && hadSprint)
    {
        g_bSprintFirstDetected[client] = true;
    }
    else if (justPressedSprint && hadForward)
    {
        g_bSprintFirstDetected[client] = false;
    }
    
    // Reset flag when both keys are released
    if (!(buttons & IN_SPEED) && !(buttons & IN_FORWARD))
    {
        g_bSprintFirstDetected[client] = false;
    }
    
    bool isActivelySprinting = (buttons & IN_SPEED) && (buttons & IN_FORWARD);
    
    // Detect when stamina reaches 100%
    if (stamina >= 99.5 && g_flLastStamina[client] < 99.5)
    {
        g_bJustRecovered[client] = true;
    }
    
    // Apply 15% penalty only if pressed SPRINT first (exploit pattern)
    if (isActivelySprinting && g_bJustRecovered[client] && g_bSprintFirstDetected[client])
    {
        SetEntDataFloat(client, g_iStaminaOffset, 85.0, true);
        g_bJustRecovered[client] = false;
    }
    else if (isActivelySprinting && g_bJustRecovered[client])
    {
        g_bJustRecovered[client] = false;
    }
    
    g_flLastStamina[client] = stamina;
    g_iPreviousButtons[client] = buttons;
}