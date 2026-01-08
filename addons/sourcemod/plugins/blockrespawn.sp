/**
* DoD:S Block Class Respawn by pratinha
*
* Description:
*   Prevents immediately re-spawning after changing player class within a spawn area (always, when player is hurt or if player has thrown a grenade).
*
* Version 1.0
* Changelog & more info at https://github.com/pratinha10/dodgs_plugin
*/

// ====[ CONSTANTS ]======================================================================
#define PLUGIN_NAME    "DoD:S Block Class Respawn"
#define PLUGIN_VERSION "1.0"

#define CLASS_INIT     0
#define MAX_CLASS      6
#define DOD_MAXPLAYERS 33
#define MAX_HEALTH     100

// Define the GetEntProp condition for m_iDesiredPlayerClass netprop
#define m_iDesiredPlayerClass(%1) (GetEntProp(%1, Prop_Send, "m_iDesiredPlayerClass"))

enum
{
	TEAM_UNASSIGNED,
	TEAM_SPECTATOR,
	TEAM_ALLIES,
	TEAM_AXIS,
	TEAM_SIZE
};

enum
{
	Bazooka = 17,
	Pschreck,
	Frag_US,
	Frag_GER,
	Frag_US_Live,
	Frag_GER_Live,
	Smoke_US,
	Smoke_GER,
	Riflegren_US,
	Riflegren_GER,
	Riflegren_US_Live,
	Riflegren_GER_Live
};

// ====[ VARIABLES ]======================================================================
static const String:block_cmds[][] = { "cls_random", "joinclass" },
	String:allies_cmds[][]  = { "cls_garand", "cls_tommy", "cls_bar",  "cls_spring", "cls_30cal", "cls_bazooka"  },
	String:axis_cmds[][]    = { "cls_k98",    "cls_mp40",  "cls_mp44", "cls_k98s",   "cls_mg42",  "cls_pschreck" },
	String:allies_cvars[][] =
{
	"mp_limit_allies_rifleman",
	"mp_limit_allies_assault",
	"mp_limit_allies_support",
	"mp_limit_allies_sniper",
	"mp_limit_allies_mg",
	"mp_limit_allies_rocket"
},
	String:axis_cvars[][] =
{
	"mp_limit_axis_rifleman",
	"mp_limit_axis_assault",
	"mp_limit_axis_support",
	"mp_limit_axis_sniper",
	"mp_limit_axis_mg",
	"mp_limit_axis_rocket"
};

new	classlimit[TEAM_SIZE][MAX_CLASS], Handle:blockchange_mode = INVALID_HANDLE, bool:ThrownGrenade[DOD_MAXPLAYERS + 1];

// ====[ PLUGIN ]=========================================================================
public Plugin:myinfo =
{
	name        = PLUGIN_NAME,
	author      = "Root",
	description = "Prevents immediately re-spawning after changing player class within a spawn area",
	version     = PLUGIN_VERSION,
	url         = "http://dodsplugins.com/"
}


/* OnPluginStart()
 *
 * When the plugin starts up.
 * --------------------------------------------------------------------------------------- */
public OnPluginStart()
{
	CreateConVar("dod_blockrespawn_version", PLUGIN_VERSION, PLUGIN_NAME, FCVAR_NOTIFY|FCVAR_DONTRECORD);
	blockchange_mode = CreateConVar("dod_blockrespawn", "1", "Determines when block player respawning after changing class:\n1 - Block when player is hurt or have used any explosives\n2 - Always block respawning", FCVAR_PLUGIN, true, 0.0, true, 2.0);

	for (new i; i < sizeof(block_cmds); i++)
	{
		// Using RegConsoleCmd to intercept is in poor practice for already existing commands
		AddCommandListener(OtherClass, block_cmds[i]);
	}

	// Get all commands and classlimit ConVars for both teams
	for (new i; i < MAX_CLASS; i++)
	{
		AddCommandListener(OnAlliesClass, allies_cmds[i]);
		AddCommandListener(OnAxisClass,   axis_cmds[i]);

		// Initialize team-specified classlimits
		classlimit[TEAM_ALLIES][i] = GetConVarInt(FindConVar(allies_cvars[i]));
		classlimit[TEAM_AXIS][i]   = GetConVarInt(FindConVar(axis_cvars[i]));

		// Hook any changes for classlimit cvars, otherwise we may have some problems in a future usage (some maps have different classlimit configs you know)
		HookConVarChange(FindConVar(allies_cvars[i]), UpdateClassLimits);
		HookConVarChange(FindConVar(axis_cvars[i]),   UpdateClassLimits);
	}

	// Hook spawning and attacking events for every player
	HookEvent("player_spawn", OnPlayerSpawn, EventHookMode_Post);
	HookEvent("dod_stats_weapon_attack", OnPlayerAttack, EventHookMode_Post);
}

/* UpdateClasslimits()
 *
 * Called when value of classlimit convar is changed.
 * --------------------------------------------------------------------------------------- */
public UpdateClassLimits(Handle:convar, const String:oldValue[], const String:newValue[])
{
	for (new i; i < MAX_CLASS; i++)
	{
		// When classlimit value is changed (for any team/any class), just re-init variables again
		classlimit[TEAM_ALLIES][i] = GetConVarInt(FindConVar(allies_cvars[i]));
		classlimit[TEAM_AXIS][i]   = GetConVarInt(FindConVar(axis_cvars[i]));
	}
}

/* OnPlayerSpawn()
 *
 * Called when a player spawns.
 * --------------------------------------------------------------------------- */
public OnPlayerSpawn(Handle:event, const String:name[], bool:dontBroadcast)
{
	// Reset boolean on respawn
	ThrownGrenade[GetClientOfUserId(GetEventInt(event, "userid"))] = false;
}

/* OnPlayerAttack()
 *
 * Called when a player attacks with a weapon.
 * --------------------------------------------------------------------------- */
public OnPlayerAttack(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (Bazooka <= GetEventInt(event, "weapon") <= Riflegren_GER)
	{
		// Player has used an explosive - set the bool
		ThrownGrenade[GetClientOfUserId(GetEventInt(event, "attacker"))] = true;
	}
}

/* OnAlliesClass()
 *
 * Called when a player has executed a join class command for Allies team.
 * --------------------------------------------------------------------------------------- */
public Action:OnAlliesClass(client, const String:command[], argc)
{
	new mode = GetConVarInt(blockchange_mode);
	new team = GetClientTeam(client);

	// Make sure ConVar is initialized and player is alive, otherwise player may not respawn after selecting a team and a class (server may crash)
	if (IsPlayerAlive(client) && mode && team == TEAM_ALLIES)
	{
		new class = CLASS_INIT;
		new cvar  = CLASS_INIT;

		// Loop through available allies class commands
		for (new i; i < sizeof(allies_cmds); i++)
		{
			if (StrEqual(command, allies_cmds[i]))
			{
				class = cvar = i;
				break;
			}
		}

		// Make sure desired player class is available in allies team
		if (IsClassAvailable(client, team, class, cvar))
		{
			switch (mode)
			{
				case 1: // Dont allow player to be respawned if player was being hurt or has throw a grenade
				{
					if ((GetClientHealth(client) < MAX_HEALTH) || (ThrownGrenade[client] == true))
					{
						PrintUserMessage(client, class, command);
						SetEntProp(client, Prop_Send, "m_iDesiredPlayerClass", class);
						return Plugin_Handled;
					}
				}
				case 2: // Change only 'future class', and block the command
				{
					PrintUserMessage(client, class, command);
					SetEntProp(client, Prop_Send, "m_iDesiredPlayerClass", class);
					return Plugin_Handled;
				}
			}
		}
	}

	return Plugin_Continue;
}

/* OnAxisClass()
 *
 * Called when a player has executed a join class command for Axis team.
 * --------------------------------------------------------------------------------------- */
public Action:OnAxisClass(client, const String:command[], argc)
{
	new mode = GetConVarInt(blockchange_mode);
	new team = GetClientTeam(client);

	if (IsPlayerAlive(client) && mode && team == TEAM_AXIS)
	{
		// Initialize class and cvar numbers
		new class = CLASS_INIT;
		new cvar  = CLASS_INIT;

		for (new i; i < sizeof(axis_cmds); i++)
		{
			// Now assign a class and a convar numbers as same than command
			if (StrEqual(command, axis_cmds[i]))
			{
				class = cvar = i;
				break;
			}
		}

		if (IsClassAvailable(client, team, class, cvar))
		{
			// Block immediately player re-spawning depends on mode
			switch (mode)
			{
				case 1:
				{
					if ((GetClientHealth(client) < MAX_HEALTH) || (ThrownGrenade[client] == true))
					{
						// Notify client about respawning next time
						PrintUserMessage(client, class, command);
						SetEntProp(client, Prop_Send, "m_iDesiredPlayerClass", class);
						return Plugin_Handled;
					}
				}
				case 2: // Dont allow player to respawn at all
				{
					PrintUserMessage(client, class, command);
					SetEntProp(client, Prop_Send, "m_iDesiredPlayerClass", class);
					return Plugin_Handled;
				}
			}
		}
	}

	// Actually I wont block class commands at all
	return Plugin_Continue;
}

/* OtherClass()
 *
 * Called when a player has executed a random or other command to change class.
 * --------------------------------------------------------------------------------------- */
public Action:OtherClass(client, const String:command[], argc)
{
	// Block "joinclass/cls_random" commands if any mode is enabled
	return GetConVarInt(blockchange_mode) ? Plugin_Handled : Plugin_Continue;
}

/* IsClassAvailable()
 *
 * Checks whether or not desired class is available via limit cvars.
 * --------------------------------------------------------------------------------------- */
bool:IsClassAvailable(client, team, desiredclass, cvarnumber)
{
	// Initialize amount of classes
	new class = CLASS_INIT;

	// Lets loop through all clients from same team
	for (new i = 1; i <= MaxClients; i++)
	{
		// Make sure all clients is in game!
		if (IsClientInGame(i) && GetClientTeam(i) == team)
		{
			// If any classes which teammates are playing right now and matches with desired, increase amount of classes on every match
			if (m_iDesiredPlayerClass(i) == desiredclass) class++;
		}
	}

	if ((class >= classlimit[team][cvarnumber])         // Amount of classes in client's team is more OR same than value of appropriate ConVar
	&& (classlimit[team][cvarnumber] > -1)              // if ConVar value limit is obviously initialized (more than -1)
	|| (m_iDesiredPlayerClass(client)) == desiredclass) // or if current player's class is not a desired one
	{
		return false;
	}

	// Otherwise player may select/play as desired class
	return true;
}

/* PrintUserMessage()
 *
 * Prints default TextMsg usermessage with phrase.
 * --------------------------------------------------------------------------------------- */
PrintUserMessage(client, desiredclass, const String:command[])
{
	// Don't print message if player selected desired class more than once
	if (m_iDesiredPlayerClass(client) != desiredclass)
	{
		// Start a simpler TextMsg usermessage for one client
		new Handle:TextMsg = StartMessageOne("TextMsg", client);

		// Just to be safer
		if (TextMsg != INVALID_HANDLE)
		{
			// Write into a bitbuffer the stock 'You will respawn as' phrase
			decl String:buffer[128];
			Format(buffer, sizeof(buffer), "\x03#Game_respawn_as");
			BfWriteString(TextMsg, buffer);

			// Also write class string to properly show as which class you will respawn
			Format(buffer, sizeof(buffer), "#%s", command);

			// VALVe just called class names same as command names (check dod_english.txt or w/e), it makes name defines way easier
			BfWriteString(TextMsg, buffer);

			// End the TextMsg message. If message will not be sent, memory leak may occur - and PrintToChat* natives will not work
			EndMessage();
		}
	}
}