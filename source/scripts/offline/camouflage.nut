// 涂装/迷彩的本地持久化（0.9.0 移植版）。
//
// 原版把"坦克迷彩缩放/旋转/磨损"当成在线账号设置存在服务器上，离线版没有服务器，
// 所以关掉对局再回来，滑条永远回到默认值，表现为"涂装看起来没生效"。
// 这里把三项按 unit/skin 存进本地账号设置（client.blk 的 custom 段），
// 并在机库模型加载完成后回灌给原生渲染器。
from "dagor.workcycle" import clearTimer, resetTimeout
from "%appGlobals/login/loginState.nut" import isProfileReceived
from "unitCustomization" import get_last_skin, get_tank_skin_condition, get_tank_camo_scale, get_tank_camo_rotation
  , set_tank_skin_condition, set_tank_camo_scale, set_tank_camo_rotation
from "%scripts/customization/customizationConsts.nut" import TANK_CAMO_SCALE_SLIDER_FACTOR, TANK_CAMO_ROTATION_SLIDER_FACTOR

let pending = {}
let { getDirectory } = require("%scripts/offline/playersession.nut")
local pendingDirectory = null
let getSettings = @() require("%scripts/clientState/localProfile.nut")
// default 皮肤用固定键名，避免 "" 在 blk 路径里变成非法段。
let settingPath = @(unit, skin, name) $"camoSettings/{unit}/{skin == null || skin == "" ? "default" : skin}/{name}"

function getValue(unit, skin, name, fallback = null) {
  if (!require("%scripts/offline/profile.nut").enabled || !isProfileReceived.get())
    return fallback
  let path = settingPath(unit, skin, name)
  // 还没落盘的值先从待写队列里取，避免同一次操作内读到自己没写完的旧值。
  return (pendingDirectory == getDirectory() ? pending?[path] : null)
    ?? getSettings().loadLocalAccountSettings(path, fallback)
}

function flush() {
  clearTimer(flush)
  if (pendingDirectory != null && pendingDirectory == getDirectory())
    foreach (path, value in pending)
      getSettings().saveLocalAccountSettings(path, value)
  pending.clear()
  pendingDirectory = null
}

function saveValue(unit, skin, name, value) {
  let profile = require("%scripts/offline/profile.nut")
  let directory = getDirectory()
  // 只对自己拥有的载具存；切账号时目录会变，旧目录的待写值直接丢弃。
  if (!profile.enabled || directory == null || !profile.isOwned(unit) || value == getValue(unit, skin, name))
    return
  if (directory != pendingDirectory) {
    pending.clear()
    pendingDirectory = directory
  }
  pending[settingPath(unit, skin, name)] <- value
  // 滑条拖动会连续触发，节流到 0.4 秒后一次性写盘。
  resetTimeout(0.4, flush)
}

function restore(unit) {
  let profile = require("%scripts/offline/profile.nut")
  if (!profile.enabled || !isProfileReceived.get() || !profile.isOwned(unit))
    return
  let aircraft = require("%scripts/dagui_library.nut").getAircraftByName(unit)
  if (aircraft == null || !(aircraft.isTank() || aircraft.isShipOrBoat() || aircraft.isHuman()))
    return
  // 迷彩参数是按"当前皮肤"存的，所以要先拿到这个载具当前选中的皮肤名。
  let skin = get_last_skin(aircraft.masterUnit ?? unit)
  let condition = getValue(unit, skin, "condition")
  let scale = getValue(unit, skin, "scale")
  let rotation = getValue(unit, skin, "rotation")
  if (condition != null && get_tank_skin_condition() != condition)
    set_tank_skin_condition(condition)
  if (scale != null && (get_tank_camo_scale() * TANK_CAMO_SCALE_SLIDER_FACTOR).tointeger() != scale)
    set_tank_camo_scale(scale / TANK_CAMO_SCALE_SLIDER_FACTOR)
  if (rotation != null && (get_tank_camo_rotation() * TANK_CAMO_ROTATION_SLIDER_FACTOR).tointeger() != rotation)
    set_tank_camo_rotation(rotation / TANK_CAMO_ROTATION_SLIDER_FACTOR)
}

return {getValue, saveValue, flush, restore}
