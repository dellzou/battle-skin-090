import "DataBlock" as DataBlock
from "%scripts/offline/blkgetters.nut" import get_attachable_blk, get_decals_blk
from "%globalScripts/logs.nut" import log
let indexes = {}

function hasExtraDecalSlots(unit) {
  let profile = require("%scripts/offline/profile.nut")
  if (!profile.enabled || unit == null || unit == "")
    return false
  // 原来只认 PremiumAccount 这个 entitlement，离线账号永远没有它，
  // 结果是"高级贴花槽（3/4 号）永远灰着"。离线版改成看本地改装树里的
  // allowPremDecals 是否已拥有——和自定义界面里显示的解锁状态保持一致。
  return require("%scripts/dagui_natives.nut").has_entitlement("PremiumAccount")
    || (profile.getProfile()?.modifications?[unit]?.owned ?? []).contains("allowPremDecals")
}

function syncDecalSlots(unitName = null) {
  let store = require("%scripts/offline/profile.nut")
  if (!store.enabled)
    return
  let native = require("unitCustomization")
  let hangar = require("hangar")
  let unit = unitName ?? hangar.hangar_get_current_unit_name()
  if (unit == null)
    unit = ""
  // The UI entitlement adapter alone does not change the native renderer's
  // allowed-decal count. Keep its 3rd/4th slots on the same path as 1st/2nd.
  hangar.set_allowed_decals_count(hasExtraDecalSlots(unit) ? native.get_max_num_decal_slots()
    : unit == "" ? 2 : native.get_num_decal_slots(unit))
}

function includes(kind, id) {
  if (!(kind in indexes)) {
    let keys = {}
    let cfg = kind == "decal" ? DataBlock() : get_attachable_blk()
    if (kind == "decal")
      get_decals_blk(cfg)
    for (local i = 0; i < (cfg?.blockCount() ?? 0); i++)
      keys[cfg.getBlock(i).getBlockName()] <- true
    indexes[kind] <- keys
  }
  return id in indexes[kind]
}

function restoreDecals(layouts) {
  // 恢复贴花时机库还没换到目标载具，用存档里的当前选中载具算槽位，
  // 否则读到的永远是上一台车的槽数。
  syncDecalSlots(require("%scripts/offline/profile.nut").getProfile()?.selectedUnit)
  let directory = require("%scripts/offline/playersession.nut").getDirectory()
  let getters = require("blkGetters")
  if (directory != null && "get_local_attachables_profile_blk" in getters) {
    let cache = getters.get_local_attachables_profile_blk()
    log($"WTOFFLINE native attachable cache ready={cache != null}")
    let saved = DataBlock()
    if (cache != null && saved.tryLoad($"{directory}/native-attachables.blk", true)) {
      cache.setFrom(saved)
      log("WTOFFLINE restored complete native attachable layouts")
    }
  }
  let native = require("unitCustomization")
  foreach (unit, skins in layouts)
    foreach (skin, serialized in skins) {
      let data = DataBlock()
      try {
        if (data.loadFromText(serialized, serialized.len()))
          native.apply_skin_decals_blk(unit, skin, data)
      }
      catch (error) {
        log($"WTOFFLINE could not restore decal layout for {unit}/{skin}: {error}")
      }
    }
}

function saveAttachables() {
  let store = require("%scripts/offline/profile.nut")
  let directory = require("%scripts/offline/playersession.nut").getDirectory()
  let getters = require("blkGetters")
  if (!store.enabled || directory == null || !("get_local_attachables_profile_blk" in getters))
    return
  let cache = getters.get_local_attachables_profile_blk()
  if (cache == null)
    return
  let owned = DataBlock()
  for (local i = 0; i < cache.blockCount(); i++) {
    let unit = cache.getBlock(i)
    if (store.isOwned(unit.getBlockName()))
      owned.addBlock(unit.getBlockName()).setFrom(unit)
  }
  log($"WTOFFLINE native attachable layouts saved={owned.saveToTextFile($"{directory}/native-attachables.blk")} units={owned.blockCount()}")
}

function saveDecals(unit, skin) {
  let store = require("%scripts/offline/profile.nut")
  if (!store.enabled || !store.isOwned(unit))
    return
  // skin 可能是 null（调用方传了未选皮肤），老代码只判 ""，null 会被拼成 "null" 键。
  let skinKey = skin == null || skin == "" ? "default" : skin
  let native = require("unitCustomization")
  let data = native.get_skin_decals_blk(unit, skinKey)
    ?? (skinKey == "default" ? native.get_skin_decals_blk(unit, "") : null)
  if (data == null) {
    log($"WTOFFLINE no committed decal layout unit={unit} skin={skin}")
    return
  }
  let layout = data.formatAsString()
  if (layout == (store.getProfile()?.decalLayouts?[unit]?[skinKey] ?? ""))
    return
  store.applyCommand("save_decal_layout", {unit, skin = skinKey, layout}, function(ok, result) {
    log($"WTOFFLINE decal layout saved unit={unit} skin={skin} success={ok}")
    if (!ok)
      log($"WTOFFLINE decal save failed: {result}")
  })
}

return {includes, restoreDecals, saveDecals, saveAttachables, syncDecalSlots}
