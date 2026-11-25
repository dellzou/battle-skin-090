from "blkGetters" import get_settings_blk
from "math" import max
from "dagor.system" import get_arg_value_by_name
from "dagor.http" import httpRequest, HTTP_SUCCESS
from "dagor.time" import get_time_msec, get_local_unixtime
import "DataBlock" as DataBlock
from "json" import parse_json, object_to_json_string
from "eventbus" import eventbus_send
from "%sqstd/json.nut" import loadJson
from "%globalScripts/logs.nut" import log
from "%globalScripts/shopItemConsts.nut" import *
from "%globalScripts/unitTypeConsts.nut" import *

let enabled = get_settings_blk()?.debug.disableNetwork ?? false
let session = require("%scripts/offline/playersession.nut")
let dataDir = session.getDirectory()
let loadOptions = { logger = null }
local runtime = enabled && dataDir != null ? loadJson($"{dataDir}/runtime.json", loadOptions) : null
let projectDir = get_arg_value_by_name("offlineProjectDir")
let catalog = enabled && projectDir != null
  ? loadJson($"{projectDir}/data/unit-catalog.json", loadOptions)?.units ?? {} : {}
catalog.__update(require("%scripts/offline/modregistry.nut").units)
let cosmetics = enabled && projectDir != null
  ? loadJson($"{projectDir}/data/cosmetic-catalog.json", loadOptions) ?? {} : {}
let crewCosts = enabled && projectDir != null
  ? loadJson($"{projectDir}/data/crew-slot-costs.json", loadOptions)?.slots ?? [] : []
let crewProgression = enabled && projectDir != null
  ? loadJson($"{projectDir}/data/profile-progression.json", loadOptions) ?? {} : {}
let crewQualificationRules = enabled && projectDir != null
  ? loadJson($"{projectDir}/data/crew-qualifications.json", loadOptions) ?? {} : {}
let researchRules = enabled && projectDir != null
  ? loadJson($"{projectDir}/data/research-rules.json", loadOptions) ?? {} : {}
let squadronVehicles = enabled && projectDir != null
  ? loadJson($"{projectDir}/data/squadron-vehicles.json", loadOptions) ?? {} : {}
let typeGroups = {
  [ES_UNIT_TYPE_AIRCRAFT] = "aviation", [ES_UNIT_TYPE_TANK] = "army",
  [ES_UNIT_TYPE_SHIP] = "ships", [ES_UNIT_TYPE_BOAT] = "boats", [ES_UNIT_TYPE_HELICOPTER] = "helicopters"
}
local snapshot = enabled && dataDir != null ? loadJson($"{dataDir}/profile.json", loadOptions) : null
let nativeMods = require("%scripts/offline/nativemods.nut")
if (enabled)
  nativeMods.sync(snapshot?.profile)

function bindAccount(dir) {
  let nextRuntime = loadJson($"{dir}/runtime.json", loadOptions)
  let nextSnapshot = loadJson($"{dir}/profile.json", loadOptions)
  if (nextRuntime?.token == null || nextSnapshot?.profile == null)
    return false
  runtime = nextRuntime
  snapshot = nextSnapshot
  nativeMods.sync(snapshot.profile)
  session.bind(dir)
  require("%scripts/offline/loadouts.nut").bind(dir)
  return true
}
let pending = []
local busy = false
local sequence = 0

function getProfile() {
  return snapshot?.profile ?? {}
}

function isOwned(unitName) {
  let master = catalog?[unitName].masterUnit ?? ""
  return (getProfile()?.ownedUnits ?? []).indexof(master != "" ? master : unitName) != null
}

function isMarketUnit(unitName) {
  let definition = catalog?[unitName]
  return (definition?.event ?? "") != "" || (definition?.marketplaceItemdefId ?? 0) != 0
}

function isHiddenCollectible(unitName) {
  let unit = catalog?[unitName]
  if (unit?.inShop != true || (unit?.masterUnit ?? "") != "" || unitName.startswith("nt_"))
    return false
  if (unitName == "b_52h" || unitName == "tu_95m" || unitName == "fw_190a_8_mistel")
    return true
  return (unit?.marketplaceItemdefId ?? 0) == 0 && (unit?.event ?? "") != "nuclear_thunder"
    && ((unit?.gold ?? 0) > 0 || (unit?.event ?? "") != "")
}

function isRankAvailable(definition) {
  let required = definition?.previousRankRequired ?? 0
  if (required == 0)
    return true
  local count = 0
  foreach (name in getProfile()?.ownedUnits ?? []) {
    let owned = catalog?[name]
    if (owned?.country == definition?.country && owned?.rankType == definition?.rankType
        && owned?.rank == (definition?.rank ?? 1) - 1)
      count++
  }
  return count >= required
}

function getResearchStatus(unitName) {
  let profile = getProfile()
  let definition = catalog?[unitName]
  if ((definition?.masterUnit ?? "") != "" && !isOwned(definition.masterUnit))
    return ES_ITEM_STATUS_LOCKED
  if (isOwned(unitName)) {
    let mounted = (profile?.crewGroups[profile?.group ?? "army"] ?? []).indexof(unitName) != null
    return ES_ITEM_STATUS_OWNED | ES_ITEM_STATUS_RESEARCHED | (mounted ? ES_ITEM_STATUS_MOUNTED : 0)
  }
  if (definition?.normalResearch == false && (definition?.gold ?? 0) == 0
      && (definition?.gift ?? "") == "" && !isMarketUnit(unitName))
    return ES_ITEM_STATUS_LOCKED
  let required = definition?.requiredUnlock ?? ""
  if (required != "" && required in (profile?.ownershipUnlocks ?? {}) && !profile.ownershipUnlocks[required])
    return ES_ITEM_STATUS_LOCKED
  if (!(definition?.inShop ?? false))
    return ES_ITEM_STATUS_LOCKED
  if (unitName in squadronVehicles) {
    if (profile.unlockedUnits.contains(unitName))
      return ES_ITEM_STATUS_CAN_BUY | ES_ITEM_STATUS_RESEARCHED
    return profile?.squadron.target == unitName ? ES_ITEM_STATUS_IN_RESEARCH : ES_ITEM_STATUS_CAN_RESEARCH
  }
  if ((definition?.gold ?? 0) > 0 || (definition?.gift ?? "") != "")
    return ES_ITEM_STATUS_CAN_BUY | ES_ITEM_STATUS_RESEARCHED
  let previous = definition?.previousUnit ?? ""
  if (!isRankAvailable(definition) || (previous != "" && !isOwned(previous)))
    return ES_ITEM_STATUS_LOCKED
  if ((profile?.unlockedUnits ?? []).indexof(unitName) != null || (definition?.research ?? 0) == 0)
    return ES_ITEM_STATUS_CAN_BUY | ES_ITEM_STATUS_RESEARCHED
  let key = $"{definition.country}:{definition.shopGroup}"
  return profile?.researchTargets?[key] == unitName ? ES_ITEM_STATUS_IN_RESEARCH : ES_ITEM_STATUS_CAN_RESEARCH
}

function getStorePrices() {
  let prices = DataBlock()
  if (projectDir != null)
    prices.tryLoad($"{projectDir}/data/store-prices.blk", true)
  return prices
}

function getCrewSnapshot(crewId) {
  if (crewId == null || crewId <= 0)
    return null
  let countryIndex = (crewId - 1) / 100
  let slot = (crewId - 1) % 100
  let country = getProfile()?.availableCountries?[countryIndex]
  return country != null ? getProfile()?.crewSkillSnapshots?[$"{country}:{slot}"] : null
}

function getCrewSkillsBlock(crewId, _unitName = "") {
  let blk = DataBlock()
  foreach (member, skills in getCrewSnapshot(crewId)?.skills ?? {}) {
    let page = blk.addNewBlock(member)
    foreach (skill, value in skills)
      page[skill] = value
  }
  return blk
}

function getCrewQualification(crewId, unitName) {
  let crew = getCrewSnapshot(crewId)
  return crew != null
    ? getProfile()?.crewQualifications?[$"{crew.country}:{crew.slot}"]?[unitName] : null
}

function getQualificationGold(fromCode, unitName, crewId = 0, experience = -1) {
  if (fromCode != 1)
    return 0
  let definition = crewQualificationRules?.units?[unitName]
  let required = definition?.aceExperience ?? 0
  if (definition == null || required <= 0)
    return 0
  let earned = experience >= 0 ? experience : getCrewQualification(crewId, unitName)?.aceExperience ?? 0
  if (earned >= required)
    return 0
  local discount = 0
  foreach (stage in crewQualificationRules?.aceDiscountStages ?? [])
    if (earned * 100 >= required * stage.percent)
      discount = stage.discount
  let price = definition.aceGold
  return price - (price * discount / 100)
}

function getCrews() {
  let profile = getProfile()
  let countries = profile?.availableCountries ?? [profile?.country ?? "country_usa"]
  return countries.map(function(country, countryIndex) {
    let groups = country == profile?.country ? profile?.crewGroups : profile?.countryCrews?[country]
    let selected = groups?[profile?.group ?? "army"] ?? ["", "", ""]
    let crews = selected.map(function(unitName, index) {
    let progression = profile?.crewSkillSnapshots?[$"{country}:{index}"]
    let trainingKey = $"{country}:{profile?.group ?? "army"}:{index}"
    let trained = clone (profile?.crewTraining?[trainingKey] ?? [])
    let qualifications = profile?.crewQualifications?[$"{country}:{index}"] ?? {}
    foreach (otherGroup in ["army", "aviation", "fleet", "helicopters"])
      foreach (trainedUnit in profile?.crewTraining?[$"{country}:{otherGroup}:{index}"] ?? [])
        if (trained.indexof(trainedUnit) == null)
          trained.append(trainedUnit)
    if (unitName != "" && trained.indexof(unitName) == null)
      trained.append(unitName)
    let trainedSpec = {}
    foreach (trainedUnit in trained)
      trainedSpec[trainedUnit] <- qualifications?[trainedUnit].code ?? 0
    if (unitName != "")
      trainedSpec[unitName] <- qualifications?[unitName].code ?? 0
    return {
      id = countryIndex * 100 + index + 1, idCountry = countryIndex, idInCountry = index,
      country, aircraft = unitName == "" ? null : unitName,
      isEmpty = unitName == "" ? 1 : 0, trainedSpec,
      trained, skillPoints = progression?.skillPoints ?? 0,
      skills = progression?.skills ?? {}, levels = progression?.levels ?? {},
      lockedTillSec = 0, isLocked = 0, crewSkillsPercent = 0
    }
    })
    if (country == profile?.country) {
      let support = require("%scripts/offline/spawnpoints.nut")
      foreach (index, offer in support.slotOffers()) {
        // These event-style rows exist only in this returned UI snapshot.
        // They never enter ownedUnits, crewGroups or crewTraining.
        crews.append({id = -10000 - index, idCountry = countryIndex, idInCountry = crews.len(),
          country, aircraft = offer.unit, isEmpty = 0,
          trainedSpec = {}, trained = [],
          skillPoints = 0, lockedTillSec = 0, isLocked = 0, crewSkillsPercent = 0,
          isUnitOverrided = true, offlineSupport = true})
      }
    }
    return {country, crews}
  })
}

function publish(action, previous = null) {
  if (["equip_modifications", "purchase_modification", "purchase_all_modifications", "buy_unit", "buy_store_item", "reset_profile", "record_battle"].contains(action))
    nativeMods.sync(snapshot?.profile)
  eventbus_send("WTOFFLINE.profileChanged", {revision = snapshot?.revision ?? -1, action})
  if (["assign_crews", "select_lineup", "delete_lineup", "select_country", "select_unit", "set_options", "reset_profile"].contains(action))
    require("%sqStdLibs/helpers/subscriptions.nut").broadcastEvent("OfflineLineupChanged")
  if (action == "join_squadron" || action == "leave_squadron")
    require("%sqStdLibs/helpers/subscriptions.nut").broadcastEvent("RequestUpdateGamercards")
  if (["open_silver_crates", "activate_vehicle_coupon", "buy_crate_vehicle"].contains(action)) {
    let before = previous?.profile.ownedUnits ?? []
    let subscriptions = require("%sqStdLibs/helpers/subscriptions.nut")
    foreach (unitName in snapshot?.profile.ownedUnits ?? [])
      if (!before.contains(unitName))
        subscriptions.broadcastEvent("UnitBought", {unitName, receivedFromTrophy = action != "buy_crate_vehicle", needSelectCrew = false})
  }
  if (["open_silver_crates", "activate_vehicle_coupon", "recycle_items", "craft_recycled_items", "activate_wager"].contains(action))
    require("%sqStdLibs/helpers/subscriptions.nut").broadcastEvent("InventoryUpdate")
  if (["train_crew_skills", "purchase_crew_points", "purchase_full_crew", "purchase_crew_qualification", "train_crew_unit", "record_battle", "reset_profile", "refresh"].contains(action)) {
    let crews = require("%scripts/slotbar/crewsList.nut")
    crews.invalidateCrewsList(true)
    let refreshed = crews.getCrewsList()
    // The training handler publishes its success only after its in-flight
    // flag is cleared. Original listeners require an actual crew identity;
    // a global points-only event throws before all crew views can refresh.
    if (action != "train_crew_skills") {
      let subscriptions = require("%sqStdLibs/helpers/subscriptions.nut")
      foreach (countryData in refreshed)
        foreach (crew in countryData.crews) {
          if (crew.id <= 0)
            continue
          let key = $"{crew.country}:{crew.idInCountry}"
          let old = previous?.profile.crewSkillSnapshots?[key]
          let current = getProfile()?.crewSkillSnapshots?[key]
          if (action == "reset_profile" || old == null
              || object_to_json_string(old) != object_to_json_string(current))
            subscriptions.broadcastEvent("CrewSkillsChanged", {crew,
              isOnlyPointsChanged = ["record_battle", "purchase_crew_points"].contains(action)})
        }
    }
  }
}

local sendNext = null
sendNext = function() {
  if (busy || pending.len() == 0)
    return
  let operation = pending.remove(0)
  if (runtime?.baseUrl == null || runtime?.token == null || snapshot == null) {
    operation.callback?(false, "Local profile service is not ready")
    sendNext()
    return
  }
  busy = true
  sequence++
  let operationId = $"gui-{runtime.token.slice(0, 8)}-{get_time_msec()}-{sequence}"
  let sentAt = get_time_msec()
  let refresh = operation.action == "refresh"
  let request = {
    url = $"{runtime.baseUrl}{refresh ? "/v1/profile" : "/v1/command"}"
    method = refresh ? "GET" : "POST"
    headers = { ["X-WTOFFLINE-Token"] = runtime.token, ["Content-Type"] = "application/json",
      ["X-WTOFFLINE-Combat-Delta"] = "2", ["X-WTOFFLINE-Profile-Delta"] = "1" }
    callback = function(response) {
      let arrivedAt = get_time_msec()
      busy = false
      local result = null
      try {
        result = response?.body != null ? parse_json(response.body.as_string()) : null
      } catch (error) {
        log($"WTOFFLINE local response parse failed: {error}")
      }
      let serverMs = result?.serverMs ?? "unknown"
      let unchanged = (result?.profileUnchanged ?? false) && result.revision == snapshot?.revision
      if (unchanged)
        result = snapshot
      else if (result?.profileChanges != null && result.baseRevision == snapshot?.revision) {
        let profile = snapshot.profile.__merge(result.profileChanges)
        foreach (key in result.profileRemoved)
          profile.$rawdelete(key)
        result = {schemaVersion = result.schemaVersion, revision = result.revision, profile}
      }
      // Frequent combat events only modify the active battle. Reuse the
      // unchanged inventory, research, and historical data in this snapshot.
      if (result?.baseRevision == snapshot?.revision && "activeBattle" in result) {
        let activeBattle = result.activeBattle
        if ((result?.retainBattleSetup ?? false) && activeBattle?.id == snapshot.profile?.activeBattle.id) {
          foreach (key in ["modeRules", "hudRewardQuotes"])
            if (key in snapshot.profile.activeBattle)
              activeBattle[key] <- snapshot.profile.activeBattle[key]
        }
        let nextProfile = snapshot.profile.__merge({activeBattle})
        if ("npcDailyBackups" in result)
          nextProfile.npcDailyBackups <- result.npcDailyBackups
        result = {schemaVersion = result.schemaVersion, revision = result.revision, profile = nextProfile}
      }
      let success = response?.status == HTTP_SUCCESS && response?.http_code == 200 && result?.profile != null
      if (success) {
        let previous = snapshot
        snapshot = result
        if (!unchanged)
          publish(operation.action, previous)
        if (operation.action == "record_battle") {
          let completed = (result.profile?.unlockedUnits ?? []).filter(@(unit)
            (previous?.profile.unlockedUnits ?? []).indexof(unit) == null
              && (result.profile?.ownedUnits ?? []).indexof(unit) == null)
          let history = result.profile.battleHistory.findvalue(@(battle) battle.id == operation.payload.battleId)
          let modules = (history?.moduleProgress ?? []).filter(@(item) item.before < item.required && item.after >= item.required)
          if (completed.len() > 0 || modules.len() > 0)
            eventbus_send("WTOFFLINE.researchCompleted", {units = completed, modules})
        }
      }
      else if (result?.current?.profile != null) {
        let previous = snapshot
        snapshot = result.current
        publish("refresh", previous)
      }
      operation.callback?(success, success ? result : (result?.error ?? "Local profile request failed"))
      let elapsed = get_time_msec() - sentAt
      let queueMs = sentAt - operation.enqueuedAt
      if (elapsed + queueMs >= 1000) {
        let responseWait = arrivedAt - sentAt
        let guiWork = get_time_msec() - arrivedAt
        log($"WTOFFLINE slow local command action={operation.action} elapsedMs={elapsed} queueMs={queueMs} responseWaitMs={responseWait} guiWorkMs={guiWork} serverMs={serverMs} queued={pending.len()}")
      }
      sendNext()
    }
  }
  if (refresh)
    request.headers["X-WTOFFLINE-Profile-Revision"] <- snapshot.revision.tostring()
  if (!refresh)
    request.data <- object_to_json_string({operationId, revision = snapshot.revision,
      action = operation.action, payload = operation.payload})
  httpRequest(request)
}

function applyCommand(action, payload, callback = null) {
  let enqueuedAt = get_time_msec()
  if (action == "record_bot_action" && callback == null) {
    let previous = pending.len() > 0 ? pending.top() : null
    // Merge only adjacent, unsent credits. Never cross an advance_bot boundary:
    // every earned point must be committed before that actor's next-life debit.
    if (previous?.action == "record_bot_actions" && previous.payload.battleId == payload.battleId
        && previous.payload.events.len() < 128)
      previous.payload.events.append(payload)
    else
      pending.append({action = "record_bot_actions", payload = {battleId = payload.battleId, events = [payload]}, callback, enqueuedAt})
  }
  else
    pending.append({action, payload, callback, enqueuedAt})
  sendNext()
}

function getCrewCount(country = null) {
  return getProfile()?.crewSlotCounts?[country ?? getProfile()?.country] ?? 3
}

function getCrewSlotCost(country = null) {
  return crewCosts?[getCrewCount(country)]
}

function makeNativeAdapters(nativeFunctions) {
  let mods = require("%scripts/offline/modifications.nut")
  let getOriginalRank = nativeFunctions.get_cur_rank_info
  let originalHaveSkin = nativeFunctions.player_have_skin
  let originalHaveDecal = nativeFunctions.player_have_decal
  let originalHaveAttachable = nativeFunctions.player_have_attachable
  let originalSpawnScore = nativeFunctions.shop_get_spawn_score
  let originalAutoRefill = nativeFunctions.get_auto_refill
  return {
    // Research completion is driven by the local transactional history.
    // The unhydrated online character's automatic list is unrelated to it.
    shop_get_countries_list_with_autoset_units = @() []
    shop_get_units_list_with_autoset_modules = @() []
    clan_get_researching_unit = @() getProfile()?.squadron.target ?? ""
    clan_get_exp = @() getProfile()?.squadron.reserve ?? 0
    player_have_decal = @(id) require("%scripts/offline/decorations.nut").includes("decal",id) || originalHaveDecal(id)
    player_have_attachable = @(id) require("%scripts/offline/decorations.nut").includes("attachable",id) || originalHaveAttachable(id)
    get_auto_refill = function(mode) {
      let saved = getProfile()?.options.autoRefillSupplies
      return mode == 1 && typeof saved == "bool" ? saved : originalAutoRefill(mode)
    }
    get_cur_rank_info = function() {
      local rankBase = {}
      try { rankBase = getOriginalRank() } catch (_error) {}
      let profile = getProfile()
      return rankBase.__merge({name = profile?.name ?? "离线玩家", wp = profile?.silver ?? 0,
        gold = profile?.gold ?? 0, country = profile?.country ?? "country_usa",
        aircrafts = (profile?.ownedUnits ?? []).len(), pilotIcon = profile?.pilotIcon ?? "cardicon_default",
        exp = profile?.playerExperience ?? 0, rank = profile?.playerLevel ?? 0})
    }
    get_player_user_id = @() 1
    get_player_user_id_str = @() "1"
    get_local_player_country = @() getProfile()?.country ?? "country_usa"
    is_crew_slot_was_ready_at_host = @(_slot, name, _check = false) isOwned(name)
      || require("%scripts/offline/spawnpoints.nut").offerFor(name) != null
    shop_get_spawn_score = function(...) {
      let localCost = require("%scripts/offline/spawnpoints.nut").cost(
        vargv?[0], vargv?[1], vargv?[2], vargv?[3])
      return localCost ?? originalSpawnScore.acall([null].extend(vargv))
    }
    get_crew_info = getCrews
    get_aircraft_crew_by_id = getCrewSkillsBlock
    get_aircraft_crew_blk = getCrewSkillsBlock
    get_crew_count = getCrewCount
    get_crew_slot_cost = getCrewSlotCost
    wp_get_skill_points_cost_gold = @(name, _country)
      crewProgression?.crewSkillPointPacks?[name].gold ?? 0
    wp_get_specialization_cost = @(fromCode, name, _crewId, _experience)
      fromCode == 0 ? crewQualificationRules?.units?[name].expertSilver ?? 0 : 0
    wp_get_specialization_cost_gold = getQualificationGold
    expert_to_ace_get_unit_exp = @(crewId, name)
      getCrewQualification(crewId, name)?.aceExperience ?? 0
    shop_is_aircraft_purchased = isOwned
    shop_is_player_has_unit = isOwned
    shop_get_module_research_status = mods.status
    is_tier_available = mods.tierAvailable
    shop_get_module_exp = mods.experience
    shop_get_researchable_module_name = mods.target
    wp_get_modification_cost = mods.cost
    wp_get_modification_cost_gold = mods.goldCost
    wp_get_modification_max_count = mods.maxCount
    wp_get_modification_open_cost_gold = mods.openGoldCost
    shop_get_modification_baseval = mods.purchased
    shop_is_weapon_available = function(unit, weapon, checkMods = true, checkAmmo = false) {
      let offer = require("%scripts/offline/spawnpoints.nut").offerFor(unit)
      return (offer != null && offer.weapon == weapon) || mods.weaponAvailable(unit, weapon, checkMods, checkAmmo)
    }
    shop_is_weapon_purchased = function(unit, weapon) {
      let offer = require("%scripts/offline/spawnpoints.nut").offerFor(unit)
      return ((offer != null && offer.weapon == weapon) || mods.weaponAvailable(unit, weapon)) ? 10000 : 0
    }
    // 原来只认 ownedSkins（买过的皮肤包），载具自带的原厂皮肤因此被判成"没有"，
    // 出生时原生会把皮肤名丢掉、退回默认涂装。这里补上两条原生来源：
    // 皮肤配置表里登记过的，以及载具自己 blk 里的 skin 块。
    player_have_skin = function(unit, skin) {
      let skinId = $"{unit}/{skin}"
      let skins = require("%scripts/offline/blkgetters.nut").get_skins_blk()
      if (skins?[skinId] != null)
        return true
      let aircraft = require("%scripts/dagui_library.nut").getAircraftByName(unit)
      return aircraft?.getSkinBlockById(skin) != null
        || (getProfile()?.ownedSkins ?? []).contains(skinId) || originalHaveSkin(unit, skin)
    }
    shop_is_unit_rented = @(_unitName) false
    shop_get_free_exp = @() getProfile()?.freeExperience ?? 0
    wp_get_exp_convert_exp_for_gold_rate = @(_country) researchRules?.researchPointsPerGoldenEagle ?? 45
    shop_get_unit_exp = @(name) getProfile()?.researchExperience?[name] ?? 0
    shop_unit_research_status = getResearchStatus
    wp_get_cost = @(name) catalog?[name].silver ?? 0
    wp_get_cost_gold = @(name) catalog?[name].gold ?? 0
    shop_get_researchable_unit_name = @(country, unitType)
      getProfile()?.researchTargets?[$"{country}:{typeGroups?[unitType] ?? ""}"] ?? ""
    shop_get_country_excess_exp = @(country, unitType)
      getProfile()?.researchOverflow?[$"{country}:{typeGroups?[unitType] ?? ""}"] ?? 0
    is_era_available = function(country, rank, unitType) {
      if (rank <= 1)
        return true
      let group = typeGroups?[unitType] ?? ""
      let definition = catalog.findvalue(@(value) value.country == country && value.shopGroup == group && value.rank == rank)
      return definition != null && isRankAvailable(definition)
    }
    get_training_cost = function(crewId, name) {
      let countryIndex = (crewId - 1) / 100
      let slot = (crewId - 1) % 100
      let country = getProfile()?.availableCountries?[countryIndex] ?? ""
      let trained = ["army", "aviation", "fleet", "helicopters"].findindex(@(group)
        (getProfile()?.crewTraining?[$"{country}:{group}:{slot}"] ?? []).indexof(name) != null) != null
      return {cost = trained ? 0 : catalog?[name].trainingSilver ?? 0}
    }
    get_shop_prices = @(output) output.setFrom(getStorePrices())
    get_entitlements_price_blk = getStorePrices
    is_entitlements_price_actual = @() true
    is_price_actual = @() true
    get_entitlement_cost_gold = @(_name) 0
    shop_get_premium_account_ent_name = @() "PremiumAccount"
    entitlement_expires_in = @(name) name == "PremiumAccount"
      ? max(0, ((getProfile()?.premiumUntil ?? 0) - get_local_unixtime()) / 60) : 0
    has_entitlement = @(name) name == "PremiumAccount"
      ? (getProfile()?.premiumUntil ?? 0) > get_local_unixtime()
      : (getProfile()?.claimedProducts ?? []).indexof(name) != null
    is_country_available = @(country) (getProfile()?.availableCountries ?? ["country_usa"]).indexof(country) != null
  }
}

function getBotBattleContext() {
  return getProfile()?.activeBattle ?? getProfile()?.lastBattleBotContext
}

function getBotProfile(botId, callback) {
  if (!enabled || runtime?.baseUrl == null || runtime?.token == null)
    return callback(null)
  let expected = getBotBattleContext()?.id
  let accountRuntime = runtime
  httpRequest({
    url = $"{runtime.baseUrl}/v1/bots/profile/{botId}"
    method = "GET"
    headers = { ["X-WTOFFLINE-Token"] = runtime.token }
    callback = function(response) {
      local record = null
      if (response?.status == HTTP_SUCCESS && response?.http_code == 200) {
        try { record = parse_json(response.body.as_string()) } catch (_error) {}
      }
      if (botId.startswith("roster-"))
        callback(runtime == accountRuntime && record?.rosterKey == botId ? record : null)
      else
        callback(record?.battleId == expected && getBotBattleContext()?.id == expected ? record : null)
    }
  })
}

if (enabled)
  log($"WTOFFLINE profile snapshot loaded revision={snapshot?.revision} owned={(getProfile()?.ownedUnits ?? []).len()}")

function squadronCost(name) {
  let entry = squadronVehicles?[name]
  if (entry == null)
    return 0
  let remaining = max(0,entry.rp - (getProfile()?.researchExperience?[name] ?? 0))
  if (remaining == 0)
    return 0
  local divisor = entry.rp
  local remainder = entry.fullGE
  while (remainder > 0) {
    let next = divisor % remainder
    divisor = remainder
    remainder = next
  }
  let denominator = entry.rp / divisor
  return max(entry.minimumGE, ((entry.fullGE / divisor) * remaining + denominator - 1) / denominator)
}

function modRequest(payload, callback) {
  if (!enabled || runtime?.baseUrl == null || runtime?.token == null)
    return callback(false, {error = "本地服务尚未就绪"})
  let expected = runtime
  let request = {
    url = $"{runtime.baseUrl}/v1/mods{payload == null ? "" : "/config"}"
    method = payload == null ? "GET" : "POST"
    headers = {["X-WTOFFLINE-Token"] = runtime.token, ["Content-Type"] = "application/json"}
    callback = function(response) {
      if (runtime != expected)
        return
      local data = null
      try { data = parse_json(response.body.as_string()) } catch (_error) {}
      callback(response?.status == HTTP_SUCCESS && response?.http_code == 200 && data != null,
        data ?? {error = "无法读取模组管理器"})
    }
  }
  if (payload != null)
    request.data <- object_to_json_string(payload)
  httpRequest(request)
}

return {enabled, bindAccount, getProfile, getCrews, getCrewSnapshot, isOwned, isMarketUnit, isHiddenCollectible, applyCommand, makeNativeAdapters, getResearchStatus, squadronCost, cosmetics, getBotProfile, getBotBattleContext, modRequest,
  isSquadronUnit = @(name) name in squadronVehicles
  fullCrewPrice = crewProgression?.fullCrewTrainingGE ?? 0
  squadronDirectory = runtime?.squadronDirectory
  getMarketUrl = @(unit = "") $"{runtime.baseUrl}/shop/market.html#token={runtime.token}&unit={unit}",
  getShopUrl = @(chapter = null) $"{runtime.baseUrl}/shop/#token={runtime.token}&chapter={chapter ?? "bonuses"}",
  getUnitCountry = @(name) catalog?[name].country ?? getProfile()?.country ?? "country_usa",
  getUnitGroup = @(name) catalog?[name].shopGroup ?? "",
  getUnitClass = @(name) catalog?[name]?["class"] ?? "",
  getUnitRating = @(name, difficulty, group = null) catalog?[name].battleRatingsByMode?[group ?? ""]?[difficulty]
    ?? catalog?[name].battleRatings?[difficulty] ?? catalog?[name].battleRating ?? 1.0,
  getLinkedUnits = @() catalog.filter(@(unit) (unit?.masterUnit ?? "") != "" || (unit?.slaveUnits ?? []).len() > 0),
  getRevision = @() snapshot?.revision ?? -1}
