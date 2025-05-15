static DynamicHook m_hShouldTransmit;
static DynamicHook m_hEventKilled;
static DynamicHook m_hPassesFilterImp1;
static DynamicHook m_hShouldGib;
static DynamicHook m_hAcceptInput;
static DynamicHook m_hForceRespawn;

#if defined NO_UPGRADE_TELEPORTER
static DynamicHook m_hCanBeUpgraded;
#endif

bool InitDHooks(GameData hGamedata)
{
	int failCount = 0;
	
	if (!RegisterDetour(hGamedata, "CTFBot::GetEventChangeAttributes", DHookCallback_GetEventChangeAttributes_Pre, DHookCallback_GetEventChangeAttributes_Post))
		failCount++;
	
	if (!RegisterDetour(hGamedata, "CBaseObject::FindSnapToBuildPos", DHookCallback_FindSnapToBuildPos_Pre, DHookCallback_FindSnapToBuildPos_Post))
		failCount++;
	
	if (!RegisterDetour(hGamedata, "CTFPlayer::CanBuild", DHookCallback_CanBuild_Pre, DHookCallback_CanBuild_Post))
		failCount++;
	
	if (!RegisterDetour(hGamedata, "CTFPlayer::CanBeForcedToLaugh", DHookCallback_CanBeForcedToLaugh_Pre))
		failCount++;
	
	if (!RegisterHook(hGamedata, m_hShouldTransmit, "CBaseEntity::ShouldTransmit"))
		failCount++;
	
	if (!RegisterHook(hGamedata, m_hEventKilled, "CBaseEntity::Event_Killed"))
		failCount++;
	
	if (!RegisterHook(hGamedata, m_hPassesFilterImp1, "CBaseFilter::PassesFilterImpl"))
		failCount++;
	
	if (!RegisterHook(hGamedata, m_hShouldGib, "CTFPlayer::ShouldGib"))
		failCount++;
	
	if (!RegisterHook(hGamedata, m_hAcceptInput, "CBaseEntity::AcceptInput"))
		failCount++;
	
	if (!RegisterHook(hGamedata, m_hForceRespawn, "CBasePlayer::ForceRespawn"))
		failCount++;
	
#if defined NO_UPGRADE_TELEPORTER
	if (!RegisterHook(hGamedata, m_hCanBeUpgraded, "CBaseObject::CanBeUpgraded"))
		failCount++;
#endif
	
	if (failCount > 0)
	{
		LogError("InitDHooks: found %d problems with gamedata!", failCount);
		return false;
	}
	
	return true;
}

public void DHooks_OnEntityCreated(int entity, const char[] classname)
{
	if (StrEqual(classname, "filter_tf_bot_has_tag"))
		m_hPassesFilterImp1.HookEntity(Hook_Pre, entity, DHookCallback_PassesFilterImp1_Pre);
	else if (StrEqual(classname, "bot_hint_sentrygun"))
		m_hAcceptInput.HookEntity(Hook_Post, entity, DHookCallback_AcceptInput_Post);
}

public void DHooks_OnClientPutInServer(int client)
{
	if (!IsRealPlayer(client))
		return;
	
	m_hShouldTransmit.HookEntity(Hook_Pre, client, DHookCallback_ShouldTransmit_Pre);
	m_hEventKilled.HookEntity(Hook_Pre, client, DHookCallback_EventKilled_Pre);
	m_hEventKilled.HookEntity(Hook_Post, client, DHookCallback_EventKilled_Post);
	m_hShouldGib.HookEntity(Hook_Pre, client, DHookCallback_ShouldGib_Pre);
	m_hForceRespawn.HookEntity(Hook_Pre, client, DHookCallback_ForceRespawn_Pre);
}

void DHooks_RobotTeleporter(int entity)
{
#if defined NO_UPGRADE_TELEPORTER
	m_hCanBeUpgraded.HookEntity(Hook_Pre, entity, DHookCallback_CanBeUpgraded_Pre);
#endif
}

static MRESReturn DHookCallback_GetEventChangeAttributes_Pre(int pThis, DHookReturn hReturn, DHookParam hParams)
{
	/* Firing input "ChangeBotAttributes" on point_populator_interface calls CPointPopulatorInterface::InputChangeBotAttributes
	which in MvM mode will collect all living players from BLUE team, but cast them as CTFBot for some reason
	THe problem occurs when it loops through the CUtlVector and calls CTFBot::GetEventChangeAttributes on a player
	The function is not part of the player's C++ class (CTFPlayer) and will crash the game as a result! */
	
	//To counter the oversight, return NULL on non-TFBots
	if (IsPlayingAsRobot(pThis))
	{
		hReturn.Value = 0; //Maybe one day we'll actually be able to return this kind of data
		return MRES_Supercede;
	}
	
	return MRES_Ignored;
}

static MRESReturn DHookCallback_GetEventChangeAttributes_Post(int pThis, DHookReturn hReturn, DHookParam hParams)
{
	if (IsPlayingAsRobot(pThis))
	{
		//For right now, we assume RevertGateBotsBehavior is always what gets called here
		//Potentially, this could be moved to the input for point_populator_interface
		MvMRobotPlayer(pThis).OnEventChangeAttributes("RevertGateBotsBehavior");
	}
	
	return MRES_Ignored;
}

static MRESReturn DHookCallback_FindSnapToBuildPos_Pre(int pThis, DHookReturn hReturn, DHookParam hParams)
{
	//Allow robot players to be sapped
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i) && IsPlayingAsRobot(i) && IsPlayerAlive(i))
			SetClientAsBot(i, true);
	
	return MRES_Ignored;
}

static MRESReturn DHookCallback_FindSnapToBuildPos_Post(int pThis, DHookReturn hReturn, DHookParam hParams)
{
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i) && IsPlayingAsRobot(i) && IsPlayerAlive(i))
			SetClientAsBot(i, false);
	
	return MRES_Ignored;
}

static MRESReturn DHookCallback_CanBuild_Pre(int pThis, DHookReturn hReturn, DHookParam hParams)
{
	//Allow robot players to build multiple of each building type
	if (IsPlayingAsRobot(pThis))
	{
		TFObjectType type = hParams.Get(1);
		
		if (GameRules_GetRoundState() == RoundState_BetweenRounds)
		{
#if defined ALLOW_BUILDING_BETWEEN_ROUNDS
			if (type == TFObject_Sapper)
			{
				//Sappers should never be allowed at this time
				hReturn.Value = CB_CANNOT_BUILD;
				return MRES_Supercede;
			}
#else
			//Robots can't build anything at this time
			hReturn.Value = CB_CANNOT_BUILD;
			return MRES_Supercede;
#endif
		}
		
		switch (type)
		{
			case TFObject_Dispenser:
			{
				//Never allow dispensers
				hReturn.Value = CB_CANNOT_BUILD;
				return MRES_Supercede;
			}
			case TFObject_Teleporter:
			{
				if (MvMRobotPlayer(pThis).GetTeleportWhere().Length == 0)
				{
					//Robot must have TeleportWhere to build teleporters
					hReturn.Value = CB_CANNOT_BUILD;
					return MRES_Supercede;
				}
				
				TFObjectMode mode = hParams.Get(2);
				
				if (mode == TFObjectMode_Entrance)
				{
					//Never allow teleporter entrances
					hReturn.Value = CB_CANNOT_BUILD;
					return MRES_Supercede;
				}
			}
		}
		
		SetClientAsBot(pThis, true);
	}
	
	return MRES_Ignored;
}

static MRESReturn DHookCallback_CanBuild_Post(int pThis, DHookReturn hReturn, DHookParam hParams)
{
	if (IsPlayingAsRobot(pThis))
		SetClientAsBot(pThis, false);
	
	return MRES_Ignored;
}

static MRESReturn DHookCallback_CanBeForcedToLaugh_Pre(int pThis, DHookReturn hReturn)
{
	//Robot players cannot be forced to laugh
	if (IsPlayingAsRobot(pThis))
	{
		hReturn.Value = false;
		return MRES_Supercede;
	}
	
	return MRES_Ignored;
}

static MRESReturn DHookCallback_ShouldTransmit_Pre(int pThis, DHookReturn hReturn, DHookParam hParams)
{
	//Always transmit boss robots
	if (IsPlayingAsRobot(pThis) && MvMRobotPlayer(pThis).HasAttribute(CTFBot_USE_BOSS_HEALTH_BAR))
	{
		hReturn.Value = FL_EDICT_ALWAYS;
		return MRES_Supercede;
	}
	
	return MRES_Ignored;
}

static MRESReturn DHookCallback_EventKilled_Pre(int pThis, DHookParam hParams)
{
	if (GameRules_GetRoundState() == RoundState_BetweenRounds)
		return MRES_Ignored;
	
	if (IsPlayingAsRobot(pThis))
	{
		/* This does several things for when the player dies, but most notably
		- player doesn't drop ammo pack
		- player doesn't drop reanimator
		- decrements the wavebar based on the player's class icon
		- scout never spawns a client-side bird when gibbed
		- stunned player fires event "mvm_adv_wave_killed_stun_radio"
		- sends TE particle effect "bot_death"
		- BLUE flag carrier fires event "mvm_bomb_carrier_killed" */
		SetClientAsBot(pThis, true);
		
#if defined MANUAL_DEATH_WAVEBAR_EDIT
		if (bwr3_edit_wavebar.BoolValue)
		{
			SetAsSupportEnemy(pThis, true);
			DecrementRobotPlayerClassIcon(pThis);
		}
#else
		//Don't decrement the class icon in the wavebar
		if (!bwr3_edit_wavebar.BoolValue)
			SetAsSupportEnemy(pThis, true);
#endif
		
		if (bwr3_drop_credits.IntValue > CREDITS_DROP_NONE)
		{
			/* The amount of money we are going to drop we stored as our currency when we became a robot
			We do this here instead of post because the game will set the property to 0 in this function
			This does not have happen if the player isn't seen as a bot though */
			int dropAmount = TF2_GetCurrency(pThis);
			
			if (dropAmount)
			{
				switch (bwr3_drop_credits.IntValue)
				{
					case CREDITS_DROP_NORMAL:
					{
						bool bDropPack = true;
						int moneyMaker = -1;
						
#if defined MOD_EXT_CBASENPC
						if (!hParams.IsNull(1))
						{
							CTakeDamageInfo info = CTakeDamageInfo(hParams.GetAddress(1));
							int attacker = info.GetAttacker();
							int inflictor = info.GetInflictor();
							
							if (inflictor > 0 && IsEntityATrigger(inflictor))
							{
								bDropPack = false;
								DistributeCurrencyAmount(dropAmount, -1, true, true);
							}
							else if (attacker > 0 && BaseEntity_IsPlayer(attacker) && TF2_GetPlayerClass(attacker) == TFClass_Sniper)
							{
								int nDamageCustom = info.GetDamageCustom();
								int killerWeapon = info.GetWeapon();
								
								if (nDamageCustom == TF_CUSTOM_BLEEDING || (killerWeapon > 0 && WeaponID_IsSniperRifleOrBow(TF2Util_GetWeaponID(killerWeapon))))
								{
									moneyMaker = attacker;
									
									if (TF2_IsHeadshot(nDamageCustom) || (BaseCombatCharacter_LastHitGroup(pThis) == HITGROUP_HEAD && killerWeapon > 0 && GetJarateTime(killerWeapon)))
									{
										Event hEvent = CreateEvent("mvm_sniper_headshot_currency");
										
										if (hEvent)
										{
											hEvent.SetInt("userid", GetClientUserId(attacker));
											hEvent.SetInt("currency", dropAmount);
											hEvent.Fire();
										}
									}
								}
							}
						}
#endif
						
						if (bDropPack)
							DropCurrencyPack(pThis, TF_CURRENCY_PACK_CUSTOM, dropAmount, false, moneyMaker);
					}
					case CREDITS_DROP_FORCE_DISTRIBUTE:
					{
						DropCurrencyPack(pThis, TF_CURRENCY_PACK_CUSTOM, dropAmount, true);
					}
				}
			}
		}
	}
	
	return MRES_Ignored;
}

static MRESReturn DHookCallback_EventKilled_Post(int pThis, DHookParam hParams)
{
	if (GameRules_GetRoundState() == RoundState_BetweenRounds)
		return MRES_Ignored;
	
	if (IsPlayingAsRobot(pThis))
	{
		SetClientAsBot(pThis, false);
		
#if !defined MANUAL_DEATH_WAVEBAR_EDIT
		if (bwr3_edit_wavebar.BoolValue)
		{
			if (IsValidEntity(g_iObjectiveResource))
			{
				char iconName[PLATFORM_MAX_PATH]; TF2_GetClassIconName(pThis, iconName, sizeof(iconName));
				int iFlags = MvMRobotPlayer(pThis).GetMission() >= CTFBot_MISSION_SNIPER ? MVM_CLASS_FLAG_MISSION : MVM_CLASS_FLAG_NORMAL;
				
				if (TF2_IsMiniBoss(pThis))
					iFlags |= MVM_CLASS_FLAG_MINIBOSS;
				
				//Remove our class icon from the wavebar entirely if it wasn't originally part of it and has zero count
				if (!IsClassIconUsedInCurrentWave(iconName) && OSLib_GetWaveIconSpawnCount(g_iObjectiveResource, iconName, iFlags) == 0)
					OSLib_SetWaveIconSpawnCount(g_iObjectiveResource, iconName, iFlags, 0, false);
			}
		}
#endif
	}
	
	return MRES_Ignored;
}

static MRESReturn DHookCallback_PassesFilterImp1_Pre(int pThis, DHookReturn hReturn, DHookParam hParams)
{
	int entity = hParams.Get(2); //The entity being filtered
	
	//Only want to check players
	if (entity > MaxClients)
		return MRES_Ignored;
	
	//Must be a robot player
	if (!IsPlayingAsRobot(entity))
		return MRES_Ignored;
	
	char tags[BOT_TAGS_BUFFER_MAX_LENGTH]; GetEntPropString(pThis, Prop_Data, "m_iszTags", tags, sizeof(tags));
	bool bRequiresAllTags = GetEntProp(pThis, Prop_Data, "m_bRequireAllTags") == 1;
	
	//This entity can parse multiple tags, if separated by a blank space
	char splitTags[MAX_BOT_TAG_CHECKS][BOT_TAG_EACH_MAX_LENGTH];
	int splitTagsCount = ExplodeString(tags, " ", splitTags, sizeof(splitTags), sizeof(splitTags[]));
	
	bool bPasses = false;
	for (int i = 0; i < splitTagsCount; i++)
	{
		if (MvMRobotPlayer(entity).HasTag(splitTags[i]))
		{
			bPasses = true;
			
			if (!bRequiresAllTags)
				break;
		}
		else if (bRequiresAllTags)
		{
			//Requires all tags but we're missing one, does not pass filter!
			// hReturn.Value = false;
			
			return MRES_Ignored;
		}
	}
	
	hReturn.Value = bPasses;
	
	return MRES_Supercede;
}

static MRESReturn DHookCallback_ShouldGib_Pre(int pThis, DHookReturn hReturn, DHookParam hParams)
{
	//Allow robot players to gib like MvM bots
	if (IsPlayingAsRobot(pThis))
	{
		if (TF2_IsMiniBoss(pThis) || BaseAnimating_GetModelScale(pThis) > 1.0)
		{
			hReturn.Value = true;
			return MRES_Supercede;
		}
	}
	
	return MRES_Ignored;
}

static MRESReturn DHookCallback_AcceptInput_Post(int pThis, DHookReturn hReturn, DHookParam hParams)
{
	if (hReturn.Value == true)
	{
		char inputName[8]; hParams.GetString(1, inputName, sizeof(inputName));
		
		//If the hint is being told to disable, disable all BLUE sentry guns
		if (StrEqual(inputName, "Disable", false))
			DisableAllTeamObjectsByClassname(TFTeam_Blue, "obj_sentrygun");
	}
	
	return MRES_Ignored;
}

static MRESReturn DHookCallback_ForceRespawn_Pre(int pThis)
{
	//Somewhere, we said this player is not allowed to respawn at this time
	if (g_bAllowRespawn[pThis] == false)
	{
#if defined DEBUG_DETOURS
		PrintToServer("DHookCallback_ForceRespawn_Pre: BLOCKED RESPAWN ON %N", pThis);
#endif
		
		return MRES_Supercede;
	}
	
	return MRES_Ignored;
}

static MRESReturn DHookCallback_CanBeUpgraded_Pre(int pThis, DHookReturn hReturn, DHookParam hParams)
{
	//For now, this is only hooked on blue teleporters
	
	if (IsPlayingAsRobot(hParams.Get(1)))
	{
		//Robot players cannot upgrade any robot teleporters
		hReturn.Value = false;
		return MRES_Supercede;
	}
	
	return MRES_Ignored;
}

static bool RegisterDetour(GameData gd, const char[] fnName, DHookCallback pre = INVALID_FUNCTION, DHookCallback post = INVALID_FUNCTION)
{
	DynamicDetour hDetour;
	hDetour = DynamicDetour.FromConf(gd, fnName);
	
	if (hDetour)
	{
		if (pre != INVALID_FUNCTION)
			hDetour.Enable(Hook_Pre, pre);
		
		if (post != INVALID_FUNCTION)
			hDetour.Enable(Hook_Post, post);
	}
	else
	{
		delete hDetour;
		LogError("Failed to detour \"%s\"!", fnName);
		
		return false;
	}
	
	delete hDetour;
	
	return true;
}

static bool RegisterHook(GameData gd, DynamicHook &hook, const char[] fnName)
{
	hook = DynamicHook.FromConf(gd, fnName);
	
	if (hook == null)
	{
		LogError("Failed to setup DynamicHook for \"%s\"!", fnName);
		return false;
	}
	
	return true;
}