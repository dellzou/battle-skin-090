from "%sqStdLibs/helpers/subscriptions.nut" import broadcastEvent
from "%appGlobals/ranks_common_shared.nut" import isUnitSpecial
from "eventbus" import eventbus_subscribe
from "hangar" import hangar_load_model, hangar_get_current_unit_name, hangar_get_loaded_unit_name, hangar_is_model_loaded, hangar_is_squad_loaded, set_master_unit_name
from "%scripts/dagui_library.nut" import *
let localHangarInspector = require("%scripts/offline/hangarinspect.nut")

enum HangarModelLoadState {
  LOADING
  LOADED
}

let isLoading = mkWatched(persist, "isLoading", false)

let hangarUnitName = Watched(hangar_get_current_unit_name())

function getLoadState() {
  
  
  return hangar_get_loaded_unit_name() == "" || isLoading.get() || !hangar_is_model_loaded()
    ? HangarModelLoadState.LOADING
    : HangarModelLoadState.LOADED
}

function loadFirearm(weaponName) {
  if (weaponName == hangar_get_current_unit_name() && hangar_is_squad_loaded())
    return
  isLoading.set(true)
  hangar_load_model(weaponName, false, true)
  broadcastEvent("HangarModelLoading", { modelName = weaponName })
}

function loadModel(modelName) {
  if (modelName == "" || (modelName == hangar_get_current_unit_name() && !hangar_is_squad_loaded()))
    return
  isLoading.set(true)
  let unit = getAircraftByName(modelName)
  let hasSlaves = unit?.slaveUnits
  let masterUnitName = hasSlaves ? modelName : unit?.masterUnit ?? ""
  set_master_unit_name(masterUnitName)
  let offline = require("%scripts/offline/profile.nut")
  if (offline.enabled) {
    require("%scripts/offline/nativemods.nut").sync(offline.getProfile())
    // 贴花槽数量要按"这台车"算，不能只看机库当前选中的那台。
    require("%scripts/offline/decorations.nut").syncDecalSlots(modelName)
    if (offline.isOwned(modelName))
      require("%scripts/customization/skins.nut").setCurSkinToHangar(modelName)
  }
  hangar_load_model(modelName, isUnitSpecial(unit) || unit.marketplaceItemdefId, false)
  broadcastEvent("HangarModelLoading", { modelName })
}

function onHangarModelLoaded() {
  let modelName = hangar_get_current_unit_name()
  if (hangar_get_loaded_unit_name() == modelName) {
    isLoading.set(false)
    hangarUnitName.set(modelName)
    // 顺序有讲究：先同步贴花槽，再把皮肤推给渲染器，最后回灌迷彩参数
    // （迷彩参数是按"当前皮肤"存的，皮肤没换过去之前读到的键是旧的）。
    require("%scripts/offline/decorations.nut").syncDecalSlots(modelName)
    require("%scripts/customization/skins.nut").applySavedSkinToHangar(modelName)
    require("%scripts/offline/camouflage.nut").restore(modelName)
    broadcastEvent("HangarModelLoaded", { modelName })
    require("%scripts/offline/weaponvisual.nut").restore(modelName)
    if (require("%scripts/offline/profile.nut").enabled)
      localHangarInspector.inspect()
  }
}

eventbus_subscribe("onHangarModelLoaded", @(_) onHangarModelLoaded())

return {
  loadModel
  loadFirearm
  hasLoadedModel = @() getLoadState() == HangarModelLoadState.LOADED
  hangarUnitName
}
