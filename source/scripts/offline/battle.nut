from "%scripts/offline/playersession.nut" import getDirectory
from "%globalScripts/hangarMiscConsts.nut" import BULLETS_SETS_QUANTITY
import "DataBlock" as DataBlock
import "%sqstd/ecs.nut" as ecs
from "dagor.system" import get_arg_value_by_name
from "guiMission" import select_mission_full
from "mission" import set_game_mode, get_local_mplayer, get_game_type, get_mission_time
from "eventbus" import eventbus_subscribe, eventbus_send
from "%globalScripts/controls/shortcutActions.nut" import setShortcutOn, setShortcutOff
from "dagor.workcycle" import setTimeout, setInterval, clearTimer
from "dagor.time" import get_time_msec
from "math" import sqrt
from "app" import pauseGame
from "gameplayBinding" import isInFlight, closeIngameGui, disableFlightMenu, inFlightMenu
from "guiRespawn" import doRespawnPlayer, selectRespawnBase, highlightRespawnBase
from "unit" import get_player_unit_name
from "guiMission" import get_mission_status, MISSION_STATUS_SUCCESS, MISSION_STATUS_FAIL, get_mp_tbl_teams, quit_to_debriefing
from "guiOptions" import set_cd_preset, get_cd_preset
from "%globalScripts/difficultyConsts.nut" import DIFFICULTY_CUSTOM
from "warpoints" import stat_get_exp
from "%globalScripts/gameModeNativeConsts.nut" import GM_BUILDER
from "%globalScripts/gameTypeConsts.nut" import GT_VERSUS
from "%scripts/dagui_library.nut" import *
from "%scripts/offline/blkgetters.nut" import get_wpcost_blk
from "%scripts/dagui_natives.nut" import get_auto_refill
from "%scripts/options/optionsExtNames.nut" import USEROPT_AUTO_SQUAD, OPTIONS_MODE_GAMEPLAY

let profileStore = require("%scripts/offline/profile.nut")
let combat = require("%scripts/offline/combat.nut")
let savedResult = require("%scripts/offline/battleresults.nut")
let missionBuilder = require("%scripts/offline/missionbuilder.nut")
let worldBuilder = require("%scripts/offline/worldbuilder.nut")
let aiDirector = require("%scripts/offline/aidirector.nut")
let spawnPoints = require("%scripts/offline/spawnpoints.nut")
let crewReplenish = require("%scripts/offline/crewreplenish.nut")
let nuclearCinematic = require("%scripts/offline/nuclearcinematic.nut")
let nuclearControl = require("%scripts/offline/nuclearcontrol.nut")
let liveStats = require("%scripts/hud/hudLiveStats.nut")
require("%scripts/offline/battleawards.nut")
local smokeExitBattle = null
local combatPoll = null
local combatPollBattle = null
local respawnPending = false
local startPending = false
local pendingNativeBattle = null
local pendingNativeUnit = null
local pendingNativeTarget = null
local deploymentBattle = null
local deploymentReadyAt = 0
local launchedWeapon = ""
local releasedTeamsBattle = null
local deploymentQueue = null
local processDeploymentQueue = null
local nuclearBattle = null
local nuclearArmy = 0
local nuclearExitRequested = null
local nuclearStatisticsAt = 0
local settleBattle = null

function showNaturalResult(active) {
  if (!isInFlight() || active == null || (active?.deploymentPending ?? false))
    return
  let status = get_mission_status()
  if ((status == MISSION_STATUS_SUCCESS || status == MISSION_STATUS_FAIL)
      && (nuclearBattle != active.id || get_time_msec() >= nuclearStatisticsAt))
    settleBattle(active, nuclearBattle == active.id ? nuclearArmy == 1 : status == MISSION_STATUS_SUCCESS, true)
}

function getDeploymentQueue() {
  let active = profileStore.getProfile()?.activeBattle
  if (deploymentQueue != null && (deploymentQueue.battleId != active?.id || !(active?.deploymentPending ?? false)))
    deploymentQueue = null
  return deploymentQueue
}

function cancelDeploymentQueue() {
  deploymentQueue = null
  eventbus_send("offlineDeploymentQueueChanged", {})
}

function releaseTeams(active) {
  if (releasedTeamsBattle == active.id)
    return
  releasedTeamsBattle = active.id
  ecs.g_entity_mgr.createEntity("wtoffline_start_teams_request", {
    wtoffline_start_teams__grouped = active.mission == "WTOFFLINE_TankDomination",
    wtoffline_start_teams__airRadarHeight = active?.modeRules.id == "offline_aviation_realistic",
    wtoffline_start_teams__individualCount = active?.modeRules != null ? active.participantCount : 0
  })
  pauseGame(false)
}

function deploymentSeconds() {
  return (profileStore.getProfile()?.activeBattle.deploymentPending ?? false)
    ? max(0, ((deploymentReadyAt - get_time_msec() + 999) / 1000).tointeger()) : 0
}

function armCombat() {
  let active = profileStore.getProfile()?.activeBattle
  if (!combat.isActive() || combatPollBattle == active.id)
    return
  if (combatPoll != null)
    clearTimer(combatPoll)
  combatPollBattle = active.id
  if (active?.spawnPoints.enabled ?? false) {
    let soundConfig = DataBlock()
    let soundLoaded = soundConfig.tryLoad("config/sound_studio.blk", true)
    log($"WTOFFLINE nuclear sound configuration loaded={soundLoaded}")
    if (soundLoaded) {
      let siren = soundConfig?.airDefenceSiren
      if (siren?.path != null && siren?.sound != null && (siren?.maxDist ?? 0.0) > 0.0)
        ecs.g_entity_mgr.createEntity("wtoffline_nuclear_warning", {
          wtoffline_siren__path = $"{siren.path}/{siren.sound}", wtoffline_siren__range = siren.maxDist
        })
      if (siren?.path != null && siren?.sound != null && (siren?.maxDist ?? 0.0) > 0.0)
        foreach (capture in active?.modeRules.map.captures ?? [])
          ecs.g_entity_mgr.createEntity("wtoffline_nuclear_warning", {
            wtoffline_siren__area = capture.name,
            wtoffline_siren__path = $"{siren.path}/{siren.sound}", wtoffline_siren__range = siren.maxDist
          })
    }
  }
  let world = active?.modeRules.map
  if (typeof world == "table" && world?.captures != null) {
    let captures = world.captures
    let radius = function(index) {
      let axis = captures?[index].tm[0]
      return axis == null ? 0.0 : sqrt(axis[0] * axis[0] + axis[2] * axis[2])
    }
    ecs.g_entity_mgr.createEntity("wtoffline_map_context", {
      wtoffline_map__radius0 = radius(0),
      wtoffline_map__radius1 = radius(1),
      wtoffline_map__radius2 = radius(2),
      wtoffline_map__capture0 = captures?[0].name ?? "",
      wtoffline_map__capture1 = captures?[1].name ?? "",
      wtoffline_map__capture2 = captures?[2].name ?? ""
    })
  }
  log($"WTOFFLINE native combat type={get_game_type()} versus={(get_game_type() & GT_VERSUS) != 0}")
  log("WTOFFLINE native shortcut mappings: statistics then tactical map")
  debugTableData(require("%scripts/controls/controlsCompatibility.nut").getShortcuts(["ID_MPSTATSCREEN", "ID_TACTICAL_MAP"]))
  if (get_arg_value_by_name("offlineSmokeStats") != null) {
    foreach (name, value in require("controls"))
      if (name.tolower().contains("shortcut") || name.tolower().contains("pressed"))
        log($"WTOFFLINE controls API {name} {typeof value}")
    setTimeout(5.0, function() {
      log("WTOFFLINE smoke native ID_MPSTATSCREEN down")
      setShortcutOn("ID_MPSTATSCREEN")
    })
    setTimeout(20.0, function() {
      log("WTOFFLINE smoke native ID_MPSTATSCREEN up")
      setShortcutOff("ID_MPSTATSCREEN")
    })
    setTimeout(25.0, function() {
      log("WTOFFLINE smoke native ID_TACTICAL_MAP down")
      setShortcutOn("ID_TACTICAL_MAP")
    })
    setTimeout(40.0, function() {
      log("WTOFFLINE smoke native ID_TACTICAL_MAP up")
      setShortcutOff("ID_TACTICAL_MAP")
    })
  }
  local deathShown = false
  local deathTimer = null
  local nextDefenseRoster = 0.0
  combatPoll = function() {
    if (!combat.isActive() || profileStore.getProfile()?.activeBattle.id != active.id) {
      combat.setNuclearWarning(false)
      clearTimer(combatPoll)
      if (deathTimer != null)
        clearTimer(deathTimer)
      combatPoll = null
      combatPollBattle = null
      return
    }
    nuclearControl.tick()
    showNaturalResult(profileStore.getProfile()?.activeBattle)
    if (savedResult.get()?.id == active.id)
      return
    if (nuclearBattle == active.id)
      return
    require("%scripts/offline/chat.nut").tick()
    if (active?.modeRules.cooperative ?? false) {
      let now = get_mission_time()
      if (now >= nextDefenseRoster) {
        combat.getPlayers()
        nextDefenseRoster = now + 2.0
      }
      crewReplenish.poll()
      require("%scripts/offline/crewphysical.nut").tick()
      return
    }
    processDeploymentQueue?()
    if (nuclearBattle != active.id)
      aiDirector.tick()
    crewReplenish.poll()
    require("%scripts/offline/crewphysical.nut").tick()
    combat.considerTransitions()
    // Native isDead may describe the owned tank during a temporary plane.
    // The dedicated exact-EID death/control watcher owns its return handoff.
    if (nuclearControl.isControlling()) {
      if (deathTimer != null) {
        clearTimer(deathTimer)
        deathTimer = null
      }
      deathShown = false
      return
    }
    // A changeUnit handoff briefly has no live native owner. It is neither a
    // new player death nor a reason to enter spectator/deploy a second time.
    if (respawnPending || (profileStore.getProfile()?.activeBattle.deploymentPending ?? false)) {
      if (deathTimer != null) {
        clearTimer(deathTimer)
        deathTimer = null
      }
      deathShown = false
      return
    }
    let dead = !combat.localControlledUnitIsAlive() && (get_local_mplayer()?.isDead ?? false)
    if (dead && !deathShown) {
      deathShown = true
      if (deathTimer != null)
        clearTimer(deathTimer)
      deathTimer = function() {
        deathTimer = null
        if (combat.isActive() && nuclearBattle != active.id && !nuclearControl.isControlling()
            && profileStore.getProfile()?.activeBattle.id == active.id && !combat.localControlledUnitIsAlive()
            && (get_local_mplayer()?.isDead ?? false))
          eventbus_send("gui_start_respawn")
      }
      setTimeout(6.0, deathTimer)
    }
    else if (!dead && deathShown && !respawnPending) {
      if (deathTimer != null) {
        clearTimer(deathTimer)
        deathTimer = null
      }
      deathShown = false
      disableFlightMenu(false)
      inFlightMenu(false)
      let resumed = doRespawnPlayer()
      closeIngameGui()
      eventbus_send("gui_start_hud")
      selectRespawnBase(-1)
      highlightRespawnBase(-1)
      log($"WTOFFLINE native crew control resumed={resumed}")
    }
  }
  setInterval(0.5, combatPoll)
}

function getBattleMode(unit) {
  return (unit?.isTank() ?? false) ? "tank" : (unit?.isAir() ?? false) ? "air"
    : (unit?.isShipOrBoat() ?? false) ? "naval" : (unit?.isHelicopter() ?? false) ? "helicopter" : null
}

function getSpawnPoint(unit, missionName, spawnName = "") {
  let active = profileStore.getProfile()?.activeBattle
  let hasWorld = typeof (active?.modeRules.map) == "table"
  if (hasWorld) {
    if (unit.isHelicopter())
      return spawnName.contains("spawn1") ? "player_heli_far" : "player_heli_near"
    if (unit.isAir() && spawnName.contains("airfield"))
      return "player_airfield_spawn"
    if (unit.isTank() && spawnName.contains("spawn_02"))
      return "player_ground_spawn_02"
    if (unit.isTank() && spawnName.contains("spawn_01"))
      return "player_ground_spawn_01"
    // 海战：原版地图把出生点分成大船（*_shipspawn_heavy*）和小船（*_shipspawn*）两族。
    // worldbuilder 已按后端的 shipSpawnZones 建出 player_ship_spawn_big / _small 两个区，
    // 这里把界面上选中的那个名字映射过去，选哪个区就在哪个区出生。
    if (unit.isShipOrBoat()) {
      let choice = (spawnName ?? "").tolower()
      local picked = "player_spawn"
      if (choice.contains("heavy") || choice.contains("big"))
        picked = "player_ship_spawn_big"
      else if (choice.contains("small") || choice.contains("light"))
        picked = "player_ship_spawn_small"
      // 打一行日志：界面上到底传了什么出生点名字、最后落在哪个区。
      // 如果部署窗口没有可选项，这行会显示 requested= 为空，据此判断是列表没生成。
      log($"WTOFFLINE ship spawn requested={spawnName} picked={picked}")
      return picked
    }
  }
  if (hasWorld && active.modeRules.group != "aviation")
    return unit.isHelicopter() ? "player_heli_spawn" : unit.isAir() ? "player_air_spawn" : "player_spawn"
  if (!(missionName ?? "").startswith("WTOFFLINE_Tank"))
    return "player_spawn"
  return unit.isHelicopter() ? "player_heli_spawn" : unit.isAir() ? "player_air_spawn" : "player_spawn"
}

function getDefaultWeapon(unitName) {
  let weapons = get_wpcost_blk()?[unitName].weapons
  local fallback = ""
  for (local index = 0; index < (weapons?.blockCount() ?? 0); index++) {
    let weapon = weapons.getBlock(index)
    let name = weapon.getBlockName()
    if (name.tolower().contains("default"))
      return name
    if (fallback == "" && name != "custom_presets")
      fallback = name
  }
  return fallback
}

function selectedWeapon(unitName) {
  let selected = require("%scripts/weaponry/weaponryInfo.nut").getLastWeapon(unitName)
  return selected != null && selected != "" ? selected : getDefaultWeapon(unitName)
}

function deploymentWeapon(unitName, armament) {
  let requested = spawnPoints.offerFor(unitName)?.weapon ?? armament?.weapon ?? ""
  return requested != "" ? requested : selectedWeapon(unitName)
}

let enabledMods = @(unitName) ";".join(profileStore.getProfile()?.modifications?[unitName].enabled ?? [])

function carrierSpawnMode(armament) {
  let name = armament?.spawnName ?? ""
  let constants = require("%scripts/respawn/respawnConsts.nut")
  return name == constants.CATAPULT_CARRIER_SPAWN_NAME ? "catapult"
    : name == constants.TRAMPOLINE_CARRIER_SPAWN_NAME ? "trampoline" : ""
}

function requestNativeUnit(unitName, initial, armament = {}) {
  pendingNativeBattle = profileStore.getProfile()?.activeBattle.id
  pendingNativeUnit = unitName
  let unit = getAircraftByName(unitName)
  let mode = getBattleMode(unit)
  let selectedAirArea = unit.isAir() && !unit.isHelicopter()
    && !(armament?.spawnName ?? "").contains("airfield")
      ? worldBuilder.resolveAirSpawn(armament?.spawnPosition) : null
  let selectedGroundArea = unit.isTank() ? worldBuilder.resolveGroundSpawn(armament?.spawnPosition) : null
  let selectedHeliArea = unit.isHelicopter() ? worldBuilder.resolveHeliSpawn(armament?.spawnPosition) : null
  let fields = {wtoffline_request__unit = unitName,
    wtoffline_request__weapon = deploymentWeapon(unitName, armament),
    wtoffline_request__mods = enabledMods(unitName),
    wtoffline_request__kind = mode == "tank" ? "tank" : mode == "naval" ? "ship" : "plane",
    wtoffline_request__target = selectedGroundArea ?? selectedAirArea ?? selectedHeliArea
      ?? getSpawnPoint(unit, profileStore.getProfile()?.activeBattle.mission, armament?.spawnName ?? ""),
    wtoffline_request__initial = initial}
  if (spawnPoints.offerFor(unitName)?.airSpawn ?? false)
    fields.wtoffline_request__target = "player_nuclear_air_spawn"
  fields.wtoffline_request__airControl <- profileStore.getProfile()?.activeBattle.modeRules.id == "offline_aviation_realistic"
  log($"WTOFFLINE spawn base name={armament?.spawnName ?? ""} id={armament?.spawnId ?? -1} selected={armament?.spawnPosition} target={fields.wtoffline_request__target}")
  pendingNativeTarget = fields.wtoffline_request__target
  // Four fields belong to the legacy ECS fallback. The authoritative BLK
  // below carries every native ammo slot, including secondary weapons/CM.
  for (local i = 0; i < 4; i++) {
    fields[$"wtoffline_request__bullets{i}"] <- armament?[$"bullets{i}"]
      ?? require("%scripts/weaponry/savedWeaponry.nut").getSavedBullets(unitName, i) ?? ""
    fields[$"wtoffline_request__count{i}"] <- armament?[$"count{i}"] ?? 1000
  }
  let request = DataBlock()
  request.object = "player"
  request.object_type = initial ? "isAlive" : "isKilled"
  request.target = fields.wtoffline_request__target
  request.unit_class = unitName
  request.model = unitName
  request.weaponPreset = fields.wtoffline_request__weapon
  request.type = fields.wtoffline_request__kind
  if (unit.isTank()) {
    require("%scripts/customization/skins.nut").applyGroundBattleSkin(request, unitName,
      profileStore.getProfile()?.activeBattle.modeRules.map.level, false, armament?.skin)
    // 原生 changeUnit 解析器不读 props.skin，只认顶层 skin:t=
    // （2.59 里 Unit::changeUnitAsyncImpl 的日志 skin='%s' 就是这一路读出来的）。
    // 之前只写 props.skin，玩家的涂装因此在出生时被丢掉，只有 AI 走任务 actor
    // 的 props 路径才有涂装。这里把选中的皮肤名镜像到顶层。
    let battleSkin = request?.props?.skin
    if (battleSkin != null && battleSkin != "")
      request.skin = battleSkin
  }
  let carrierMode = carrierSpawnMode(armament)
  if (unit.isAir() && carrierMode != "") {
    // A carrier is a moving native runway, not the nearest static air volume.
    // The native initialization bridge resolves its actual actor/deck and
    // acknowledges that placement before closing the deployment page.
    request.offlineCarrierSpawnMode = carrierMode
    request.offlineCarrierSpawnBaseName = armament.spawnName
    request.offlineCarrierActors = ";".join(worldBuilder.getCarrierActors())
    if (armament?.spawnPosition != null)
      request.offlineCarrierSpawnPosition = armament.spawnPosition
  }
  else if (unit.isAir() && fields.wtoffline_request__airControl
      && fields.wtoffline_request__target == "player_airfield_spawn") {
    let fieldsOnMap = profileStore.getProfile()?.activeBattle.modeRules.map.airfields.t1 ?? []
    local nearest = null
    local bestDistance = null
    foreach (field in fieldsOnMap) {
      let pivot = field?.tm?[3]
      if (pivot == null || field?.name == null)
        continue
      let dx = (armament?.spawnPosition.x ?? pivot[0]) - pivot[0]
      let dz = (armament?.spawnPosition.z ?? pivot[2]) - pivot[2]
      let distance = dx * dx + dz * dz
      if (bestDistance == null || distance < bestDistance) {
        bestDistance = distance
        nearest = field.name
      }
    }
    if (nearest != null)
      request.offlineLandRunway = nearest
  }
  if (unit.isAir() || unit.isHelicopter()) {
    let fuel = armament?.fuelAmount ?? require("%scripts/offline/loadouts.nut").get(unitName, "fuelAmount") ?? 1000000
    // The native unitSetProperties fuel field is a percentage. The original
    // per-unit GUI option is stored in millionths of full fuel.
    request.fuel = fuel.tofloat() / 10000.0
  }
  let support = spawnPoints.offerFor(unitName)
  request.applyAllMods = support != null && request.weaponPreset == support.weapon
  foreach (mod in profileStore.getProfile()?.modifications?[unitName].enabled ?? [])
    request.addStr("modification", mod)
  for (local i = 0; i < BULLETS_SETS_QUANTITY; i++) {
    request[$"bullets{i}"] <- armament?[$"bullets{i}"]
      ?? require("%scripts/weaponry/savedWeaponry.nut").getSavedBullets(unitName, i) ?? ""
    request[$"bulletsCount{i}"] <- armament?[$"count{i}"] ?? 1000
    request[$"bulletsWeapon{i}"] <- armament?[$"bulletsWeapon{i}"] ?? ""
  }
  let loadouts = require("%scripts/offline/loadouts.nut")
  crewReplenish.appendSpawnModification(request, unitName)
  let custom = armament?.nativeCustomSnapshot ?? loadouts.getCustom(unitName, request.weaponPreset)
  if (armament?.nativeCustomSnapshot != null)
    loadouts.applyNativeCustom(unitName, request.weaponPreset, custom)
  if (custom != null)
    request.addBlock("custom_weapons").setFrom(custom)
  let payloadPath = $"{getDirectory()}/native-spawn-request.blk"
  if (!request.saveToTextFile(payloadPath)) {
    respawnPending = false
    log("WTOFFLINE native spawn payload could not be written")
    return
  }
  fields.wtoffline_request__payload <- payloadPath
  ecs.g_entity_mgr.createEntity("wtoffline_respawn_request", fields)
}

function respawn(unitName, armament = {}) {
  armament = clone armament
  if (!("autoRefillSupplies" in armament))
    armament.autoRefillSupplies <- crewReplenish.autoRefillEnabled(get_auto_refill(1))
  let active = profileStore.getProfile()?.activeBattle
  let initial = active?.deploymentPending ?? false
  if (nuclearCinematic.isActive() || nuclearControl.isControlling() || active?.nuclearDetonation != null || respawnPending
      || !combat.canSpawn(unitName) || (initial ? deploymentSeconds() > 0 : !(get_local_mplayer()?.isDead ?? false)))
    return
  respawnPending = true
  let ammunition = []
  for (local i = 0; i < BULLETS_SETS_QUANTITY; i++)
    if ((armament?[$"bullets{i}"] ?? "") != "")
      ammunition.append({module = armament[$"bullets{i}"], count = armament?[$"count{i}"] ?? 0})
  let loadout = armament?.loadout ?? spawnPoints.loadout(unitName, deploymentWeapon(unitName, armament),
    armament?.spawnBullets ?? ammunition.map(@(item) item.module))
  armament.weapon <- loadout.weapon
  if (initial) {
    profileStore.applyCommand("deploy_unit", {battleId = active.id, unit = unitName, ammunition, loadout, autoRefillSupplies = armament?.autoRefillSupplies ?? false}, function(success, _result) {
      if (!success || !isInFlight()) {
        respawnPending = false
        return
      }
      combat.markSpawned(unitName)
      releaseTeams(active)
      requestNativeUnit(unitName, true, armament)
      // Keep the deployment screen until the native replacement is positioned.
      // changeUnit becoming alive is not itself a completed spawn.
      log($"WTOFFLINE initial deployment accepted unit={unitName}")
    })
    return
  }
  let battleId = profileStore.getProfile().activeBattle.id
  let unit = getAircraftByName(unitName)
  let mode = getBattleMode(unit)
  let player = get_local_mplayer()
  let localResult = combat.getLocalResult()
  let kills = max(localResult.kills,
    (player?.kills ?? 0) + (player?.groundKills ?? 0) + (player?.navalKills ?? 0)
      + (player?.aiKills ?? 0) + (player?.aiGroundKills ?? 0) + (player?.aiNavalKills ?? 0))
  profileStore.applyCommand("begin_life", {battleId, unit = unitName, ammunition, loadout, spareUid = armament?.spareUid ?? "", autoRefillSupplies = armament?.autoRefillSupplies ?? false, kills, killCounts = localResult.killCounts, actionCounters = localResult.actionCounters},
    function(success, result) {
      if (!combat.isActive() || profileStore.getProfile()?.activeBattle.id != battleId) {
        respawnPending = false
        return
      }
      if (!success) {
        respawnPending = false
        scene_msg_box("offline_respawn_failed", null, $"无法重新出战：{result}", [["ok", @() null]], "ok")
        return
      }
      requestNativeUnit(unitName, false, armament)
      combat.markSpawned(unitName)
      log($"WTOFFLINE native crew respawn requested {unitName}")
  })
}

processDeploymentQueue = function() {
  let queued = getDeploymentQueue()
  if (queued == null || respawnPending || deploymentSeconds() > 0)
    return
  deploymentQueue = null
  respawn(queued.unit, queued.armament)
  eventbus_send("offlineDeploymentQueueChanged", {})
}

function armDeployment(unitName, armament) {
  let active = profileStore.getProfile()?.activeBattle
  if (!(active?.deploymentPending ?? false) || respawnPending || !combat.canSpawn(unitName))
    return false
  let frozen = clone armament
  frozen.autoRefillSupplies <- crewReplenish.autoRefillEnabled(armament?.autoRefillSupplies ?? get_auto_refill(1))
  let selected = armament?.loadout ?? spawnPoints.loadout(unitName, deploymentWeapon(unitName, armament), armament?.spawnBullets ?? [])
  frozen.loadout <- {weapon = selected.weapon, bullets = clone selected.bullets, custom = clone selected.custom}
  frozen.weapon <- selected.weapon
  if (armament?.spawnBullets != null)
    frozen.spawnBullets <- armament.spawnBullets.map(@(item) typeof item == "table" ? clone item : item)
  let exactCost = spawnPoints.cost(unitName, selected.weapon, frozen.loadout.bullets, null,
    {presetWeapons = frozen.loadout.custom})
  if (spawnPoints.enabled() && (exactCost == null || exactCost > spawnPoints.balance()))
    return false
  let custom = require("%scripts/offline/loadouts.nut").getCustom(unitName, selected.weapon)
  if (custom != null)
    frozen.nativeCustomSnapshot <- custom
  deploymentQueue = {battleId = active.id, unit = unitName, armament = frozen}
  log($"WTOFFLINE initial vehicle explicitly queued unit={unitName} seconds={deploymentSeconds()}")
  eventbus_send("offlineDeploymentQueueChanged", {})
  processDeploymentQueue()
  return true
}

eventbus_subscribe("WTOFFLINE.nuclearShortcut", function(data) {
  let active = profileStore.getProfile()?.activeBattle
  log($"WTOFFLINE nuclear shortcut source={data?.source ?? "native"} balance={spawnPoints.balance()} pending={respawnPending} deployment={active?.deploymentPending}")
  if (!isInFlight() || active?.modeRules.id != "offline_army_realistic"
      || !(active?.spawnPoints.enabled ?? false) || (active?.deploymentPending ?? true)
      || respawnPending || nuclearBattle == active.id)
    return
  let offer = spawnPoints.offers().findvalue(@(item) item.kind == "nuclear")
  if (offer == null || spawnPoints.balance() < offer.cost || !combat.canSpawn(offer.unit)) {
    log($"WTOFFLINE nuclear shortcut unavailable offer={offer?.unit} cost={offer?.cost}")
    return
  }
  if (get_local_mplayer()?.isDead ?? false) {
    respawn(offer.unit, {weapon = offer.weapon, spawnName = "airfield"})
    return
  }
  // The controller validates the actual living ground entity. The native
  // selected-unit string can lag behind the replacement/control handoff.
  nuclearControl.start(offer)
})

function exitNuclearBattle() {
  if (!isInFlight() || !nuclearCinematic.isActive() || nuclearExitRequested == nuclearBattle)
    return false
  nuclearExitRequested = nuclearBattle
  let active = profileStore.getProfile()?.activeBattle
  if (active?.id == nuclearBattle)
    settleBattle(active, nuclearArmy == 1, false)
  pauseGame(false)
  disableFlightMenu(false)
  inFlightMenu(false)
  quit_to_debriefing()
  return true
}

function onNuclearDetonation(army, data = null) {
  let active = profileStore.getProfile()?.activeBattle
  if (!combat.isActive() || (active?.deploymentPending ?? true) || nuclearBattle == active.id)
    return
  nuclearBattle = active.id
  nuclearExitRequested = null
  combat.setNuclearWarning(false)
  nuclearArmy = army
  let battleId = active.id
  nuclearControl.tick()
  nuclearCinematic.start(battleId)
  let playerActor = nuclearControl.controlledActor()
  ecs.g_entity_mgr.createEntity("wtoffline_nuclear_stop_request", {wtoffline_nuclear_stop__playerActor = playerActor})
  let detonation = {battleId, army, time = get_mission_time()}
  let observedOwner = nuclearControl.consumeOwner()
  if (typeof data?.ownerEid == "integer" && data.ownerEid > 0 && data.ownerEid <= 0xffffffff)
    detonation.ownerEid <- data.ownerEid
  else if (observedOwner != null)
    detonation.ownerEid <- observedOwner
  profileStore.applyCommand("record_nuclear_detonation", detonation)
  let timing = require("%scripts/offline/blkgetters.nut").get_game_params_blk()?.nuclearStreakParams
  let resultDelay = timing?.resultsDelay ?? 20.0
  let statisticsDelay = timing?.statisticsDelay ?? 35.0
  // Keep the completed native statistics panel visible before transitioning.
  let debriefDelay = max(timing?.debriefingDelay ?? 35.0, statisticsDelay + 5.0)
  nuclearStatisticsAt = get_time_msec() + (statisticsDelay * 1000).tointeger()
  log($"WTOFFLINE actual nuclear detonation army={army} resultsDelay={resultDelay}")
  setTimeout(resultDelay.tofloat(), function() {
    if (!combat.isActive() || profileStore.getProfile()?.activeBattle.id != battleId)
      return
    ecs.g_entity_mgr.createEntity("wtoffline_end_battle_request", {
      wtoffline_end__won = army == 1,
      wtoffline_end__debriefingDelay = max(0, debriefDelay - resultDelay).tointeger()})
  })
  // GM_BUILDER receives missionCompleted above, but has no multiplayer
  // session-result consumer to leave the flight after the nuclear sequence.
  // Use the same original exit API as FlightMenu, only after the full native
  // animation interval and an observed completed mission. The normal
  // onQuitToDebriefing handler records and pays this battle exactly once.
  setTimeout(debriefDelay.tofloat(), function() {
    if (!isInFlight() || nuclearBattle != battleId || nuclearExitRequested == battleId)
      return
    let status = get_mission_status()
    if (status != MISSION_STATUS_SUCCESS && status != MISSION_STATUS_FAIL) {
      log($"WTOFFLINE nuclear debrief blocked: mission not completed status={status}")
      return
    }
    exitNuclearBattle()
  })
}

eventbus_subscribe("WTOFFLINE_NuclearDetonatedArmy1", @(data) onNuclearDetonation(1, data))
eventbus_subscribe("WTOFFLINE_NuclearDetonatedArmy2", @(data) onNuclearDetonation(2, data))

function startNativeMission(full, mission) {
  require("%scripts/replays/replayMetadata.nut").captureOfflineActors(profileStore.getProfile())
  worldBuilder.queueBriefing(full)
  let states = require("%scripts/missions/missionsStates.nut")
  states.currentCampaignMission.set(mission.name)
  states.set_mission_settings("mission", mission)
  states.set_mission_settings("missionFull", full)
  states.set_mission_settings("coop", false)
  set_game_mode(GM_BUILDER)
  select_mission_full(mission, full)
  require("%scripts/missions/startMissionsList.nut").guiStartFlight()
}

function launch() {
  let profile = profileStore.getProfile()
  let unitName = profile?.activeBattle.unit ?? profile?.selectedUnit ?? "us_m2a4"
  let unit = getAircraftByName(unitName)
  let mode = profile?.activeBattle.modeRules.kind ?? getBattleMode(unit)
  if (!profileStore.isOwned(unitName) || mode == null) {
    scene_msg_box("offline_battle_unit", null, "请选择本地库存中的载具", [["ok", @() null]], "ok")
    return
  }
  let projectDir = get_arg_value_by_name("offlineProjectDir")
  if (profile?.activeBattle.modeRules.cooperative ?? false) {
    launchedWeapon = selectedWeapon(unitName)
    let full = require("%scripts/offline/defensemission.nut").prepare(profile.activeBattle, launchedWeapon, getDefaultWeapon)
    let mission = full.mission_settings.mission
    let difficulty = require("%scripts/difficulty.nut").g_difficulty.ARCADE
    mission.setInt("_gameMode", GM_BUILDER)
    mission.difficulty = difficulty.name
    set_cd_preset(difficulty.cdPresetValue)
    log($"WTOFFLINE starting original defense mission {mission.name} level={mission.level}")
    startNativeMission(full, mission)
    return
  }
  let domination = mode == "tank" && (profile?.activeBattle.modeRules != null || profile?.options.gameplayMode == "domination")
  let template = profile?.activeBattle.modeRules.template ?? (domination ? "tank_domination" : $"{mode}_skirmish")
  let captureFixture = domination && get_arg_value_by_name("offlineSmokeCapture") != null
  let respawnFixture = domination && get_arg_value_by_name("offlineSmokeRespawn") != null
  let gunFixture = domination && get_arg_value_by_name("offlineSmokeGun") != null
  let attributionFixture = domination && get_arg_value_by_name("offlineSmokeAttribution") != null
  let missionPath = attributionFixture ? $"{projectDir}/work/missions/attribution-fixture.blk"
    : gunFixture ? $"{projectDir}/work/missions/gun-fixture.blk"
    : respawnFixture ? $"{projectDir}/work/missions/respawn-fixture.blk"
    : captureFixture ? $"{projectDir}/work/missions/capture-fixture.blk"
    : $"{projectDir}/data/missions/{template}.blk"
  let full = DataBlock()
  if (projectDir == null || !full.tryLoad(missionPath, true)) {
    log("WTOFFLINE local battle template unavailable")
    return
  }
  let botCount = profile?.activeBattle.botPlan.teams.reduce(@(count, team) count + team.count, 0) ?? 15
  let botSkill = {rookie = 1, normal = 2, veteran = 3, ace = 4}?[profile?.options.botDifficulty ?? "normal"] ?? 2
  let teams = profile?.activeBattle.botPlan.teams ?? []
  for (local index = 0; index < full.units.blockCount(); index++) {
    let actor = full.units.getBlock(index)
    if (actor.name == "player") {
      actor.unit_class = unitName
      actor.weapons = selectedWeapon(unitName)
      if (unit.isTank())
        require("%scripts/customization/skins.nut").applyGroundBattleSkin(actor, unitName, profile?.activeBattle.modeRules.map.level, false)
      launchedWeapon = actor.weapons
      let custom = require("%scripts/offline/loadouts.nut").getCustom(unitName, actor.weapons)
      if (custom != null) {
        actor.addBlock("custom_weapons").setFrom(custom)
        full.mission_settings.mission.addBlock("customWeaponPresetForTraining").setFrom(custom)
      }
      actor.applyAllMods = false
      foreach (mod in profileStore.getProfile()?.modifications?[unitName].enabled ?? [])
        actor.addStr("modification", mod)
      crewReplenish.appendSpawnModification(actor, unitName)
    }
    else {
      if (profile?.activeBattle.deploymentPending ?? false)
        actor.props.isDelayed = true
      let teamName = actor.name.startswith("enemy") ? "enemy" : "ally"
      let plan = teams.findvalue(@(team) team.name == teamName)
      let skill = plan?.skill ?? botSkill
      let count = plan?.count ?? (teamName == "enemy" ? (botCount + 1) / 2 : botCount / 2)
      let groupIndex = domination ? actor.name.slice(-1).tointeger() : 0
      actor.props.count = domination ? count / 3 + (groupIndex < count % 3 ? 1 : 0) : count
      actor.props.skill = skill
      actor.crewSkillK = 1.0
      if (plan?.vehicle != null) {
        actor.unit_class = plan.vehicle
        actor.weapons = getDefaultWeapon(plan.vehicle)
      }
    }
  }
  let mission = full.mission_settings.mission
  if (profile?.activeBattle.modeRules != null) {
    let originalWorld = worldBuilder.prepare(full, profile.activeBattle)
    missionBuilder.configure(full, profile.activeBattle)
    worldBuilder.appendEnvironment(full, originalWorld, profile.activeBattle)
    missionBuilder.configureAirStart(full, profile.activeBattle)
    nuclearControl.appendActor(full, profile.activeBattle)
  }
  mission.gt_versus = true
  mission.gt_cooperative = false
  if (full.triggers?.player_respawn != null)
    full.triggers.player_respawn.is_enabled = false
  if (full.triggers?.victory != null)
    full.triggers.victory.is_enabled = botCount > 0 && profile?.activeBattle.modeRules == null
  mission.setInt("_gameMode", GM_BUILDER)
  let difficulties = require("%scripts/difficulty.nut").g_difficulty
  let difficulty = profile?.activeBattle.difficulty == "realistic" ? difficulties.REALISTIC
    : profile?.activeBattle.difficulty == "simulator" ? difficulties.SIMULATOR : difficulties.ARCADE
  mission.difficulty = difficulty.name
  set_cd_preset(difficulty.cdPresetValue)
  // ===== 街机空战：打开原生 multiplayer 票数通道 =====
  // 以前只有历史空战设了 gt_mp_tickets，街机空战没设。后果是"扣票完全无效"：
  // DAS 里扣票的唯一入口 change_mp_tickets_for_team（unit_spawn_and_route.das:515，
  // 由 wtoffline_team_ticket_request 触发）在非 mp-tickets 的 builder 场次里是空转，
  // 实测整局 setMpTickets 只出现过初始值 5400-5400（608 次采样全一样），
  // 即使我们已经判定"基地被摧毁、应当 -5%"也打不动票数。
  //
  // allowEmptyTeams 同时要打开：离线对手全是 AI，原生不把它们算成真人玩家，
  // 于是 check_for_empty_teams 会在几分钟后按"对面没有活人"直接判负
  // （日志：calling mp_game_over from check_for_empty_teams due live is zero）。
  // 历史空战一直是这么做的，街机这里补齐。
  if (profile?.activeBattle.modeRules.id == "offline_aviation_arcade") {
    mission.gt_mp_tickets = true
    mission.allowEmptyTeams = true
  }
  if (profile?.activeBattle.modeRules.id == "offline_aviation_realistic") {
    mission.gt_mp_tickets = true
    mission.addBlock("ranks").max = profile.activeBattle.modeRules?.sessionEconomicRank
      ?? ((profile.activeBattle.modeRules.maxBattleRating - 1.0) * 3.0 + 0.5).tointeger()
    // These participants are real mission aircraft, not native online slots.
    // The native empty-online-team penalty would drain team B despite live AI.
    mission.allowEmptyTeams = true
    // Builder missions omit the network-mode defaults. Use the native mission
    // visibility policy, including AI teammates in collective detection.
    mission.useAIForCollectiveDetection = true
    mission.isAlwaysShowCollectiveDetectedUnits = true
    full.addBlock("variables").ctaPenaltyInactive = 0
    let penalty = full.triggers.battle_start.actions.addNewBlock("varSetInt")
    penalty.var = "ctaPenaltyInactive"
    penalty.value = 0
    let rules = mission.addBlock("netDifficultyBlk")
    let preset = get_cd_preset(difficulty.diffCode)
    if (typeof preset == "table")
      foreach (key, value in preset)
        if (typeof key == "string" && ["integer", "float", "bool", "string"].contains(typeof value))
          rules[key] = value
    rules.setDifficulty = DIFFICULTY_CUSTOM
    rules.baseDifficulty = difficulty.diffCode
    rules.hudMarkers = 2
    // The shipped Air RB preset uses maximum (3), not far/10km (2).
    rules.hudAircraftMarkersMaxDist = 3
    rules.collectiveDetection = true
    // Keep the original detection transition/decay and native blink renderer.
    // Do not continually reset per-unit indication timers on every HUD poll.
    rules.hudMarkersBlink = true
    rules.hudIndicators = true
    rules.hudRadar = true
    mission.difficulty = "custom"
    mission.isLimitedFuel = true
    mission.isLimitedAmmo = true
  }
  if (profile?.activeBattle.modeRules.id == "offline_army_realistic") {
    if (profile?.activeBattle.spawnPoints.enabled ?? false) {
      // The GUI is a builder session; explicitly supply the shipped RB cost
      // parameters instead of enabling native multiplayer spawn accounting.
      let costs = mission.addBlock("customSpawnScore")
      costs.setFrom(require("%scripts/offline/blkgetters.nut").get_warpoints_blk().respawn_points.TankHistorical)
      costs.useSpawnCostMulForWeapon = true
      costs.useSpawnCostMulForBullet = true
      mission.addBlock("ranks").max = profile.activeBattle.modeRules.sessionEconomicRank
    }
    // Native mission files use a netDifficultyBlk child, with the RB rules as
    // base difficulty. DataBlock does not accept the lobby's custDifficulty table.
    let rules = mission.addBlock("netDifficultyBlk")
    let preset = get_cd_preset(difficulty.diffCode)
    if (typeof preset == "table")
      foreach (key, value in preset)
        if (typeof key == "string" && ["integer", "float", "bool", "string"].contains(typeof value))
          rules[key] = value
    rules.setDifficulty = DIFFICULTY_CUSTOM
    rules.baseDifficulty = difficulty.diffCode
    rules.hudMarkers = 1
    rules.hudMapGroundMarkers = 1
    rules.hudMapAircraftMarkers = 1
    // get_cd_preset exports control/HUD toggles, not the game-parameter
    // preset name. The native scout ability reads this string when a custom
    // difficulty is built; without it the tank's scout preset is -1.
    rules.scoutPreset = "realistic"
    rules.keepDeadTankOnMap = true
    rules.keepDeadShipOnMap = true
    mission.difficulty = "custom"
  }
  if (profile?.activeBattle.modeRules != null)
    foreach (name in ["victory", "defeat", "player_respawn"])
      if (full.triggers?[name] != null)
        full.triggers[name].is_enabled = false
  log($"WTOFFLINE starting native AI battle mode={mode} template={template} unit={unitName} bots={botCount}")
  startNativeMission(full, mission)
}

function start() {
  if (isInFlight() || startPending)
    return
  respawnPending = false
  pendingNativeBattle = null
  pendingNativeUnit = null
  savedResult.set(null)
  let profile = profileStore.getProfile()
  let unitName = require("%scripts/slotbar/playerCurUnit.nut").getPlayerCurUnit()?.name
    ?? profile?.selectedUnit ?? "us_m2a4"
  let mode = getBattleMode(getAircraftByName(unitName))
  if (!profileStore.isOwned(unitName) || mode == null) {
    scene_msg_box("offline_battle_unit", null, "请选择本地库存中的载具", [["ok", @() null]], "ok")
    return
  }
  let missionName = mode == "tank" && profile?.options.gameplayMode == "domination"
    ? "WTOFFLINE_TankDomination" : {tank = "WTOFFLINE_TankSkirmish", air = "WTOFFLINE_AirSkirmish", naval = "WTOFFLINE_NavalSkirmish", helicopter = "WTOFFLINE_HelicopterSkirmish"}[mode]
  // 模式必须跟玩家实际选中的载具兵种一致：以前这里用 modes.current(profile)，
  // 它优先读存档里的 options.modeId（上一次玩的模式），于是"选了战舰却进了空战、
  // 选了飞机却进陆战"。改为按载具的 shopGroup 反推模式，只有找不到时才回退。
  let modes = require("%scripts/offline/modes.nut")
  let unitGroup = profileStore.getUnitGroup(unitName)
  let wantGroup = (unitGroup == "ships" || unitGroup == "boats") ? "fleet"
    : (unitGroup == "helicopters") ? "army" : unitGroup
  let wantDifficulty = profile?.options.difficulty ?? "arcade"
  let selectedMode = modes.items.findvalue(@(item)
      item.group == wantGroup && item.difficulty == wantDifficulty)
    ?? modes.items.findvalue(@(item) item.group == wantGroup)
    ?? modes.current(profile)
  let payload = {unit = unitName, mission = missionName, actionRewards = true, modeId = selectedMode.id,
    initialDeployment = true, nativeWorlds = true}
  payload.autoSquad <- require("%scripts/options/optionsExt.nut").get_option_in_mode(USEROPT_AUTO_SQUAD, OPTIONS_MODE_GAMEPLAY).value
  if (selectedMode.id == "offline_army_realistic")
    payload.spawnPoints <- true
  if (profile?.activeBattle != null)
    payload.interruptedBattleId <- profile.activeBattle.id
  if (mode == "tank" || get_arg_value_by_name("offlineSmokeDeployment") != null)
    payload.initialDeployment <- true
  if (get_arg_value_by_name("offlineBattleProbe") != null)
    payload.diagnosticBotCount <- profile?.options.botCount ?? 15
  startPending = true
  profileStore.applyCommand("begin_battle", payload,
    function(success, _result) {
      startPending = false
      if (success) {
        require("%scripts/offline/chat.nut").reset()
        require("%scripts/offline/loadouts.nut").clearBotCustom()
        try {
          launch()
        }
        catch (error) {
          log($"WTOFFLINE native launch rejected before mission entry: {error}")
          scene_msg_box("offline_launch_failed", null, "任务未能启动，请保留程序并报告本次错误。", [["ok", @() null]], "ok")
        }
      }
      else {
        log("WTOFFLINE local sortie could not be saved; launch cancelled")
        scene_msg_box("offline_match_failed", null, $"无法开始匹配：{_result}", [["ok", @() null]], "ok")
      }
    })
}

eventbus_subscribe("offlineNativeRespawnReady", function(data) {
  if (!isInFlight() || nuclearCinematic.isActive()
      || profileStore.getProfile()?.activeBattle.id != pendingNativeBattle || data?.unit != pendingNativeUnit)
    return
  respawnPending = false
  let airportSpawn = pendingNativeTarget == "player_airfield_spawn"
  let spawnBattle = pendingNativeBattle
  pendingNativeUnit = null
  pendingNativeTarget = null
  doRespawnPlayer()
  disableFlightMenu(false)
  inFlightMenu(false)
  closeIngameGui()
  // The live M-map can drag its center while visible. Never leave that native
  // input mode armed after deployment or transfer it into the flight camera.
  require("guiTacticalMap").setAllowMoveCenter(false)
  require("guiTacticalMap").setPointSettingMode(false)
  require("%scripts/hud/hudAirWeaponSelector.nut")
  eventbus_send("offlinePlayerDeploymentFinished", {unit = data.unit})
  eventbus_send("gui_start_hud")
  selectRespawnBase(-1)
  highlightRespawnBase(-1)
  // Native doRespawnPlayer/HUD activation may select its default base later
  // in the same frame. Clear after that work too, without reopening the map.
  foreach (delay in [0.1, 0.5])
    setTimeout(delay, function() {
      if (isInFlight() && profileStore.getProfile()?.activeBattle.id == spawnBattle
          && !(get_local_mplayer()?.isDead ?? true)) {
        selectRespawnBase(-1)
        highlightRespawnBase(-1)
        eventbus_send("offlinePlayerDeploymentFinished", {unit = data.unit})
      }
    })
  if (airportSpawn) {
    setTimeout(0.1, function() {
      if (!isInFlight() || profileStore.getProfile()?.activeBattle.id != spawnBattle
          || get_player_unit_name() != data.unit)
        return
      let states = require_optional("hudAircraftStates")
      if (states != null && "get_gears_current_state" in states
          && states.get_gears_current_state() == states.MechState.OFF) {
        setShortcutOn("ID_GEAR")
        setTimeout(0.15, @() setShortcutOff("ID_GEAR"))
        log($"WTOFFLINE airport landing gear lowered unit={data.unit}")
      }
    })
  }
  log($"WTOFFLINE native spawn confirmed unit={data.unit}")
})

settleBattle = function(active, won, showStats) {
  let previous = savedResult.get()
  if (previous?.id == active.id && (previous.pending || previous.after != null))
    return
  let stats = stat_get_exp() ?? {}
  let player = get_local_mplayer()
  let nativeKills = (player?.groundKills ?? 0) + (player?.kills ?? 0) + (player?.navalKills ?? 0)
    + (player?.aiGroundKills ?? 0) + (player?.aiKills ?? 0) + (player?.aiNavalKills ?? 0)
  let rewardKills = (stats?.numGroundKills ?? 0) + (stats?.numAirKills ?? 0) + (stats?.numNavalKills ?? 0)
  let kills = max(0, max(nativeKills, rewardKills))
  let eventResult = combat.getLocalResult()
  let recordedKills = max(kills, eventResult.kills)
  let snapshot = {id = active.id, unit = active.unit, mission = active.mission,
    pending = true, startRequested = false, won, duration = get_mission_time(),
    stats = eventResult, players = combat.getPlayers(), before = profileStore.getProfile(), after = null,
    silver = 0, experience = 0}
  savedResult.set(snapshot)
  let unitsUsed = []
  foreach (life in active.lives ?? [])
    if (!unitsUsed.contains(life.unit))
      unitsUsed.append(life.unit)
  log($"WTOFFLINE native sortie counters kills={nativeKills} rewardKills={rewardKills}")
  profileStore.applyCommand("record_battle", {battleId = active.id, kills = recordedKills, deaths = eventResult.deaths, won,
    killCounts = eventResult.killCounts,
    score = max(eventResult.actionCounters.score, max(0, player?.score ?? 0)).tointeger(),
    actionCounters = eventResult.actionCounters,
    participants = snapshot.players.map(@(row) {
      id = row.isLocal ? "player" : row?.offlineBotId ?? row.userId,
      isLocal = row.isLocal, team = row.team,
      airKills = row?.kills ?? 0, groundKills = row?.groundKills ?? 0, navalKills = row?.navalKills ?? 0,
      assists = row?.assists ?? 0, captures = row?.captureZone ?? 0, score = row?.score ?? 0, deaths = row?.deaths ?? 0}),
    silver = recordedKills * 250 + (won ? 1000 : 100), experience = recordedKills * 100 + (won ? 300 : 25)},
    function(success, result) {
      snapshot.pending = false
      if (success) {
        snapshot.after = result.profile
        let paid = result.profile.battleHistory.findvalue(@(item) item.id == snapshot.id)
        snapshot.silver = paid?.silver ?? 0
        snapshot.experience = paid?.experience ?? 0
        if (showStats && isInFlight() && !snapshot.startRequested && savedResult.get() == snapshot
            && nuclearExitRequested != snapshot.id)
          liveStats.showOfflineFinal(snapshot.players, unitsUsed, paid?.battleAwards ?? [], nuclearBattle == snapshot.id)
      }
      log($"WTOFFLINE local sortie result saved={success} kills={recordedKills} won={won}")
      require("%scripts/debriefing/debriefingFull.nut").gatherDebriefingResult()
      if (snapshot.startRequested)
        eventbus_send("gui_start_debriefing")
    })
}

eventbus_subscribe("onQuitToDebriefing", function(_) {
  liveStats.clearOfflineFinal()
  let active = profileStore.getProfile()?.activeBattle
  if (active == null)
    return
  if (active?.deploymentPending ?? false) {
    pauseGame(false)
    profileStore.applyCommand("cancel_deployment", {battleId = active.id})
    return
  }
  settleBattle(active, nuclearBattle == active.id ? nuclearArmy == 1 : get_mission_status() == MISSION_STATUS_SUCCESS, false)
})

eventbus_subscribe("gui_start_debriefing", @(_) liveStats.clearOfflineFinal())

function armSmokeExit() {
  armCombat()
  let pending = profileStore.getProfile()?.activeBattle
  if ((pending?.deploymentPending ?? false) && deploymentBattle != pending.id) {
    deploymentBattle = pending.id
    deploymentReadyAt = get_time_msec() + 10000
    setTimeout(10.0, function() {
      if (isInFlight() && profileStore.getProfile()?.activeBattle.id == pending.id)
        releaseTeams(profileStore.getProfile().activeBattle)
    })
    setTimeout(0.1, function() {
      if (isInFlight() && (profileStore.getProfile()?.activeBattle.deploymentPending ?? false)) {
        pauseGame(true)
        eventbus_send("gui_start_respawn")
        log("WTOFFLINE initial deployment original respawn screen opened")
      }
    })
  }
  let exitValue = get_arg_value_by_name("offlineSmokeExit")
  let active = profileStore.getProfile()?.activeBattle
  if (exitValue == null || active == null || smokeExitBattle == active.id)
    return
  let seconds = exitValue.tointeger()
  if (seconds <= 0 || seconds > 1200)
    return
  smokeExitBattle = active.id
  let expectedBattle = active.id
  log($"WTOFFLINE smoke exit scheduled in {seconds} seconds")
  setTimeout(5.0, function() {
    if (isInFlight() && profileStore.getProfile()?.activeBattle.id == expectedBattle) {
      let roster = combat.getPlayers()
      log($"WTOFFLINE diagnostic roster actual={roster.len()} expected={active?.participantCount} team1={roster.filter(@(p) p.team == 1).len()} team2={roster.filter(@(p) p.team == 2).len()}")
    }
  })
  if (get_arg_value_by_name("offlineSmokeRespawn") != null)
    foreach (delay in [5.0, 17.0, 25.0, 45.0])
      setTimeout(delay, function() {
        if (!isInFlight() || profileStore.getProfile()?.activeBattle.id != expectedBattle)
          return
        let player = get_local_mplayer()
        log($"WTOFFLINE respawn smoke player dead={player?.isDead} deaths={player?.deaths} aircraft={player?.aircraftName}")
      })
  if (get_arg_value_by_name("offlineSmokeRespawn") != null && get_arg_value_by_name("offlineSmokeManualRespawn") == null)
    setTimeout(20.0, function() {
      if (!isInFlight() || profileStore.getProfile()?.activeBattle.id != expectedBattle || !(get_local_mplayer()?.isDead ?? false))
        return
      let unitName = profileStore.getProfile()?.crewGroups.army?[1]
      if (unitName == null || !profileStore.isOwned(unitName))
        return
      respawn(unitName)
      log($"WTOFFLINE respawn smoke requested owned crew vehicle {unitName}")
    })
  if (get_arg_value_by_name("offlineSmokeCapture") != null)
    foreach (delay in [5.0, 45.0, 90.0, 150.0])
      setTimeout(delay, function() {
        if (!isInFlight() || profileStore.getProfile()?.activeBattle.id != expectedBattle)
          return
        let teams = get_mp_tbl_teams()
        log($"WTOFFLINE capture smoke native tickets A={teams?[0].tickets} B={teams?[1].tickets}")
      })
  setTimeout(seconds.tofloat(), function() {
    if (isInFlight() && profileStore.getProfile()?.activeBattle.id == expectedBattle) {
      log("WTOFFLINE smoke ending sortie through original quit flow")
      require("%scripts/hud/startHud.nut").quitMission()
    }
  })
}

return {start, armSmokeExit, respawn, deploymentSeconds, armDeployment, cancelDeploymentQueue, getDeploymentQueue, exitNuclearBattle,
  isRespawnPending = @() respawnPending}
