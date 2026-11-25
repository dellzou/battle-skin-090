import "%sqstd/string.nut" as string
from "%sqStdLibs/helpers/u.nut" import find_in_array, isDataBlock
from "%sqStdLibs/helpers/subscriptions.nut" import addListenersWithoutEnv
from "chard" import save_profile
from "%sqstd/datablock.nut" import blkFromPath
from "unitCustomization" import get_last_skin, set_last_skin, apply_skin
from "guiMission" import get_meta_mission_info_by_name
from "%scripts/offline/blkgetters.nut" import get_current_mission_info_cached, get_user_skins_blk
from "gameplayBinding" import isInFlight
from "%sqstd/math.nut" import floor, round, abs
from "%scripts/dagui_natives.nut" import save_online_single_job
from "%globalScripts/unitTypeConsts.nut" import *
from "app" import is_dev_version
from "%scripts/dagui_library.nut" import *

let { zero_money } = require("%scripts/money.nut")
let g_listener_priority = require("%scripts/g_listener_priority.nut")
let skinLocations = require("%scripts/customization/skinLocations.nut")
let unitTypes = require("%scripts/unit/unitTypesList.nut")
let { getDecorator } = require("%scripts/customization/decoratorGetters.nut")
let { getDownloadableSkins } = require("%scripts/customization/downloadableDecorators.nut")
let { isGuid } = require("%scripts/guidParser.nut")
let { isUnlockVisible } = require("%scripts/unlocks/unlocksModule.nut")
let { saveLocalAccountSettings, loadLocalAccountSettings } = require("%scripts/clientState/localProfile.nut")
let { decoratorTypes } = require("%scripts/customization/decoratorBaseType.nut")
let { Decorator } = require("%scripts/customization/decorator.nut")
let { getSkinId, DEFAULT_SKIN_NAME, getSkinNameBySkinId, approversUnitToPreviewLiveResource } = require("%scripts/customization/skinUtils.nut")
let { isSkinBanned } = require("%scripts/customization/bannedSkins.nut")
let { USEROPT_USER_SKIN } = require("%scripts/options/optionsExtNames.nut")
let { get_option } = require("%scripts/options/optionsExt.nut")
let { TANK_CAMO_ROTATION_SLIDER_FACTOR } = require("%scripts/customization/customizationConsts.nut")
let { unitNameForWeapons } = require("%scripts/weaponry/unitForWeapons.nut")
let { getSessionLobbyRoomId } = require("%scripts/matchingRooms/sessionLobbyState.nut")
let { findItemById } = require("%scripts/items/itemsManagerModule.nut")
let { getPrioritySkin } = require("%scripts/customization/prioritySkins.nut")

let previewedLiveSkinIds = []

function getMissionLevelPath(unit) {
  if (isInFlight())
    return get_current_mission_info_cached()?.level
  if (unit.testFlight == "")
    return null
  return get_meta_mission_info_by_name(unit.testFlight)?.level
}

function getTechnicsSkins(levelPath) {
  let levelBlk = blkFromPath($"{string.slice(levelPath, 0, -3)}blk")
  let technicsSkins = levelBlk?.technicsSkins
  return isDataBlock(technicsSkins)
    ? technicsSkins % "groundSkin"
    : []
}

function getBestSkinsList(unitName, isLockedAllowed, missionLevel = null) {
  let unit = getAircraftByName(unitName)
  if (!unit)
    return [DEFAULT_SKIN_NAME]

  let level = missionLevel ?? getMissionLevelPath(unit)
  if (!level)
    return [DEFAULT_SKIN_NAME]

  let skinsList = [DEFAULT_SKIN_NAME]
  foreach (skin in unit.getSkins()) {
    if (skin.name == "")
      continue
    if (isLockedAllowed) {
      skinsList.append(skin.name)
      continue
    }
    let decorator = getDecorator(getSkinId(unitName, skin.name), decoratorTypes.SKINS)
    if (decorator?.isUnlocked())
      skinsList.append(skin.name)
  }
  return skinLocations.getBestSkinsList(skinsList, unitName, level)
}


function getAutoSkin(unitName, missionLevel = null) {
  local isPrioritySkinAvailable = false

  let prioritySkin = getPrioritySkin(unitName)
  if (prioritySkin != null) {
    let decorator = getDecorator(getSkinId(unitName, prioritySkin), decoratorTypes.SKINS)
    isPrioritySkinAvailable = isPrioritySkinAvailable || (decorator && decorator.isUnlocked())
  }

  local list = getBestSkinsList(unitName, false, missionLevel)
    .filter(@(s) !isSkinBanned($"{unitName}/{s}"))
  if (list.len() == 0)
    return isPrioritySkinAvailable ? prioritySkin : DEFAULT_SKIN_NAME
  else if(isPrioritySkinAvailable && list.contains(prioritySkin))
    return prioritySkin

  let couponSkins = list.filter(
    function(skin) {
      let decorator = getDecorator(getSkinId(unitName, skin), decoratorTypes.SKINS)
      return decorator?.getCouponItemdefId() != null
    }
  )

  if (couponSkins.len() > 0)
    list = couponSkins

  let levelPath = missionLevel ?? getMissionLevelPath(getAircraftByName(unitName))
  let technicsSkins = levelPath != null ? getTechnicsSkins(levelPath) : []

  foreach (skin in technicsSkins) {
    let locationTypeBit = skinLocations.getLocationTypeId(skin)
    foreach (unitSkin in list) {
      let skinLocationsMask = skinLocations.getSkinLocationsMask(unitSkin, unitName)
      if ((skinLocationsMask & locationTypeBit) != 0)
        return unitSkin
    }
  }

  return list[list.len() - 1 - (getSessionLobbyRoomId() % list.len())]
}

let getSkinSaveId = @(unitName) $"skins/{unitName}"

function isAutoSkinAvailable(unitName) {
  return unitTypes.getByUnitName(unitName).isSkinAutoSelectAvailable()
}

function getLastSkin(unitName) {
  let offline = require("%scripts/offline/profile.nut")
  if (offline.enabled) {
    // 本地设置优先：载具自带的原厂皮肤不在 ownedSkins 里，只认后端字段的话
    // 这类皮肤的选择永远存不下来，重开就退回自动涂装。
    let saved = loadLocalAccountSettings($"offlineSkins/{unitName}")
    if (saved != null)
      return saved == "" ? null : saved
    let selections = offline.getProfile()?.selectedSkins
    if (selections != null && unitName in selections)
      return selections[unitName]
  }
  let unit = getAircraftByName(unitName)
  // unit 可能为空（载具被隐藏/改名前查询），老代码直接解引用会抛异常。
  if (unit != null && !unit.isUsable() && unit.getPreviewSkinId() != "")
    return unit.getPreviewSkinId()
  if (!isAutoSkinAvailable(unitName))
    return get_last_skin(unitName)
  return loadLocalAccountSettings(getSkinSaveId(unitName))
}

function setLastSkin(unitName, skinName, needAutoSkin = true) {
  let offline = require("%scripts/offline/profile.nut")
  if (offline.enabled && offline.isOwned(unitName)) {
    // 本地先记一份：原厂皮肤/自定义皮肤不在 ownedSkins 里，后端 set_skin 会拒收，
    // 只靠后端字段的话这类选择根本存不下来。
    saveLocalAccountSettings($"offlineSkins/{unitName}", skinName ?? "")
    // 后端只接受"已购买的皮肤包"和 default，其它皮肤发过去会被拒绝并回滚；
    // 所以仍然按老条件过滤，命中时才同步给后端（计分板/装饰界面读的是它）。
    let owned = (offline.getProfile()?.ownedSkins ?? [])
    if (skinName == DEFAULT_SKIN_NAME || skinName == null || owned.indexof($"{unitName}/{skinName}") != null)
      if (offline.getProfile()?.selectedSkins?[unitName] != skinName)
        offline.applyCommand("set_skin", {unit = unitName, skin = skinName})
    set_last_skin(unitName, skinName || getAutoSkin(unitName))
    return
  }
  if (!isAutoSkinAvailable(unitName))
    return skinName && set_last_skin(unitName, skinName)
  if (needAutoSkin || getLastSkin(unitName))
    saveLocalAccountSettings(getSkinSaveId(unitName), skinName)
  if (!needAutoSkin || skinName)
    set_last_skin(unitName, skinName || getAutoSkin(unitName))
}

let isAutoSkinOn = @(unitName) !getLastSkin(unitName)
let getRealSkin  = @(unitName) getLastSkin(unitName) || getAutoSkin(unitName)

function applyGroundBattleSkin(actor, unitName, level, isBot, selectedSkin = null) {
  if (!level || !(getAircraftByName(unitName)?.isTank() ?? false))
    return
  local skin = selectedSkin
  if (isBot) {
    let matching = getBestSkinsList(unitName, true, level)
    skin = matching.findvalue(@(id) !isSkinBanned($"{unitName}/{id}")) ?? DEFAULT_SKIN_NAME
  }
  else
    skin = skin || getLastSkin(unitName) || getAutoSkin(unitName, level)
  let props = actor?.props ?? actor.addBlock("props")
  props.skin = skin
}

function setAutoSkin(unitName, needSwitchOn) {
  if (needSwitchOn != isAutoSkinOn(unitName))
    setLastSkin(unitName, needSwitchOn ? null : get_last_skin(unitName))
}

function setCurSkinToHangar(unitName) {
  // 老实现只在"自动涂装关闭"时下发；自动涂装开着时进机库模型完全拿不到皮肤，
  // 于是自定义界面里看到的永远是默认涂装。
  let skin = getLastSkin(unitName)
  if (skin)
    set_last_skin(unitName, skin)
}

// set_last_skin 只记住"这台车选了哪套皮"，新加载的机库模型仍然停在默认涂装上，
// 必须再调一次 apply_skin 推给渲染器，机库才会真的换成玩家选的那套。
function applySavedSkinToHangar(unitName) {
  let offline = require("%scripts/offline/profile.nut")
  if (!offline.enabled || !offline.isOwned(unitName))
    return
  let skin = getRealSkin(unitName)
  if (skin == null || skin == "")
    return
  apply_skin(skin)
}

function isPreviewingLiveSkin() {
  return hasFeature("EnableLiveSkins") && previewedLiveSkinIds.len() > 0
}

function addDownloadableLiveSkins(skins, unit) {
  let downloadableSkins = getDownloadableSkins(unit.name, decoratorTypes.SKINS)
  if (downloadableSkins.len() == 0)
    return skins

  skins = [].extend(skins)

  foreach (itemdefId in downloadableSkins) {
    let resource = findItemById(itemdefId)?.getMetaResource()
    if (resource == null)
      continue

    if (isGuid(resource)) { 
      let foundIdx = skins.findindex(@(s) s?.name == resource)
      let skin = (foundIdx != null)
        ? skins.remove(foundIdx) 
        : {
            name = resource
            nameLocId = ""
            descLocId = ""

            isDownloadable = true 
          }
      skin.forceVisible <- true
      skins.append(skin)
    }
    else { 
      let skinName = getSkinNameBySkinId(resource)
      let skin = skins.findvalue(@(s) s?.name == skinName)
      if (skin == null)
        continue
      skin.forceVisible <- true
    }
  }

  return skins
}

const COLORED_DROPRIGHT_TEXT_STYLE = "textStyle:t='textarea';"

function addSkinItemToOption(option, locName, value, decorator, shouldSetFirst = false, needIcon = false) {
  let idx = shouldSetFirst ? 0 : option.items.len()
  option.items.insert(idx, {
    text = locName
    textStyle = COLORED_DROPRIGHT_TEXT_STYLE
    image = needIcon ? decorator.getSmallIcon() : null
  })
  option.values.insert(idx, value)
  option.decorators.insert(idx, decorator)
  option.access.insert(idx, {
    isOwn          = true
    unlockId       = ""
    canBuy         = false
    price          = zero_money
    isVisible      = true
    isDownloadable = false
    isAutoSkin     = false
  })
  return option.access[idx]
}

function getSkinsOption(unitName, params = {}) {
  let { showLocked = false, needAutoSkin = true, showDownloadable = false,
    overridedUnitSkin = null } = params
  let descr = {
    items      = []
    values     = []
    access     = []
    decorators = []
    autoSkin   = null
    value      = 0
  }

  let unit = getAircraftByName(unitName)
  if (!unit)
    return descr

  let needIcon = unit.esUnitType == ES_UNIT_TYPE_TANK ||
    unit.esUnitType == ES_UNIT_TYPE_HUMAN

  local skins = unit.getSkins()
  if (showDownloadable)
    skins = addDownloadableLiveSkins(skins, unit)

  local hasOverridedSkin = false
  for (local skinNo = 0; skinNo < skins.len(); ++skinNo) {
    if (hasOverridedSkin)
      break
    let skin = skins[skinNo]
    let isDefault = skin.name.len() == 0
    
    let skinName = isDefault ? DEFAULT_SKIN_NAME : skin.name

    hasOverridedSkin = skinName == overridedUnitSkin
    if (overridedUnitSkin != null && !hasOverridedSkin)
      continue

    let skinBlockName = getSkinId(unitName, skinName)
    let isPreviewedLiveSkin = hasFeature("EnableLiveSkins")
      && isInArray(skinBlockName, previewedLiveSkinIds)
    local decorator = getDecorator(skinBlockName, decoratorTypes.SKINS)
    if (!decorator) {
      if (isPreviewedLiveSkin)
        decorator = Decorator(skinBlockName, decoratorTypes.SKINS)
      else
        continue
    }

    let isUnlocked = decorator.isUnlocked()
    let isOwn = isDefault || isUnlocked || hasOverridedSkin
    if (!isOwn && !showLocked)
      continue

    let forceVisible = skin?.forceVisible || isPreviewedLiveSkin
    if (!decorator.isVisible() && !forceVisible)
      continue

    let cost = decorator.getCost()
    let hasPrice = !cost.isZero()
    let isVisible = isDefault || isOwn || hasPrice || forceVisible
      || decorator.canBuyCouponOnMarketplace(unit)
      || isUnlockVisible(decorator.unlockBlk)
    if (!isVisible && !is_dev_version())
      continue

    let access = addSkinItemToOption(descr, decorator.getName(), skinName, decorator, false, needIcon)
    access.isOwn          = isOwn
    access.unlockId       = !isOwn && decorator.unlockBlk ? decorator.unlockId : ""
    access.canBuy         = decorator.canBuyUnlock(unit)
    access.price          = cost
    access.isVisible      = isVisible
    access.isDownloadable = skin?.isDownloadable ?? false
    access.isAutoSkin     = false
  }

  let hasAutoSkin = needAutoSkin && isAutoSkinAvailable(unitName)
  if (!hasOverridedSkin && hasAutoSkin) {
    let autoSkin = getAutoSkin(unitName)
    let decorator = getDecorator(getSkinId(unitName, autoSkin), decoratorTypes.SKINS)
    let locName = loc("skins/auto", { skin = (decorator?.getName() ?? "") })
    let access = addSkinItemToOption(descr, locName, null, decorator, true, needIcon)
    access.isAutoSkin = true
    descr.autoSkin = autoSkin
  }

  let curSkin = hasOverridedSkin ? overridedUnitSkin : getLastSkin(unit.name)
  descr.value = find_in_array(descr.values, curSkin, -1)
  if (descr.value != -1 || !descr.values.len())
    return descr

  descr.value = 0
  if (curSkin && curSkin != "") 
    setLastSkin(unit.name, descr.values[0], hasAutoSkin)

  return descr
}

let getCurUnitUserSkins = @() get_user_skins_blk()?[unitNameForWeapons.get()]

function getCurUserSkin() {
  let userSkins = getCurUnitUserSkins()
  if (userSkins == null)
    return null
  let opt = get_option(USEROPT_USER_SKIN)
  let curVal = opt.value
  let curUserSkinName = opt.values?[curVal] ?? ""
  return (userSkins % "skin").findvalue(@(s) s.name == curUserSkinName)
}

let getSkinConditionByPercent = @(val) 2 * val - 100
function getUserSkinCondition() {
  let { condition = null} = getCurUserSkin()
  if (condition == null)
    return null
  return getSkinConditionByPercent(condition)
}

function getSkinRotationByDeg(deg) {
  local estimatedVal = round(TANK_CAMO_ROTATION_SLIDER_FACTOR * abs(deg) * 100 / 180)
  let calculatedDegrees = floor(((estimatedVal * 180) / 100) / TANK_CAMO_ROTATION_SLIDER_FACTOR)

  if (calculatedDegrees < abs(deg))
    estimatedVal += 1
  else if (calculatedDegrees > abs(deg))
    estimatedVal -= 1

  return deg >= 0 ? estimatedVal : -estimatedVal
}

function getUserSkinRotation() {
  let { rotation = null} = getCurUserSkin()
  if (rotation == null)
    return null
  return getSkinRotationByDeg(rotation)
}

function getSkinScaleByRawPercent(val) {
  const minTankCamoScale = 0.2
  const maxTankCamoScale = 2
  const scaleRange = 10

  if (val < minTankCamoScale || val > maxTankCamoScale)
    return 0
  
  if (val > 1)
    return ((val - 1.0) / (maxTankCamoScale - 1.0)) * scaleRange
  if (val < 1)
    return -(val - 1.0) / (minTankCamoScale - 1.0) * scaleRange
  return 0
}

function getUserSkinScale() {
  let { scale = null} = getCurUserSkin()
  if (scale == null)
    return null
  return getSkinScaleByRawPercent(scale)
}

function applyPreviewSkin(unitName) {
  let unit = getAircraftByName(unitName)
  if (!unit)
    return

  let previewSkinId = unit.getPreviewSkinId()
  if (previewSkinId == "")
    return

  setLastSkin(unit.name, previewSkinId, false)

  save_online_single_job(3210)
  save_profile(false)
}

function clearLivePreviewParams() {
  previewedLiveSkinIds.clear()
  approversUnitToPreviewLiveResource.set(null)
}

addListenersWithoutEnv({
  DecorCacheInvalidate = @(_) clearLivePreviewParams()
  LoginComplete = @(_) clearLivePreviewParams()
  SignOut = @(_) clearLivePreviewParams()
  UnitBought = @(p) applyPreviewSkin(p?.unitName)
  UnitRented = @(p) applyPreviewSkin(p?.unitName)
}, g_listener_priority.CONFIG_VALIDATION)

return {
  getAutoSkin
  applyGroundBattleSkin
  setAutoSkin
  getLastSkin
  setLastSkin
  getRealSkin
  setCurSkinToHangar
  applySavedSkinToHangar
  isAutoSkinOn
  isAutoSkinAvailable
  getSkinsOption
  getBestSkinsList
  clearLivePreviewParams
  isPreviewingLiveSkin
  previewedLiveSkinIds
  getCurUnitUserSkins
  getCurUserSkin
  getUserSkinCondition
  getUserSkinRotation
  getUserSkinScale
}
