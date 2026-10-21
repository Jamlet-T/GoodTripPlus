后续更新（基于 2.6.9，待发布）

- 新增“单邻房普通隐藏房候选”设置：可始终显示白金双候选，或在整层房间位置公开且多邻房候选均被有效排除后恢复单邻房的普通隐藏房可能性（默认）。已排除的位置不会重新出现。
- 修复硫酸、地球、水果蛋糕及数据破解的破墙效果变为激光后，命中假隐藏房门位却不排除候选的问题；直线光束和圆环分别按接触位置检测。
- 修复小地图最高可见房间上方的超级隐藏房候选星号被屏幕顶边裁掉、而房内金色门框仍显示的问题。

Upcoming changes (after 2.6.9, unreleased)

- Added a one-neighbor Secret Room candidate setting: always show both white/gold possibilities, or restore the regular Secret Room possibility after the full layout is visible and every multi-neighbor candidate has been ruled out (default). Excluded locations stay excluded.
- Fixed false Secret Room candidates remaining after wall-breaking laser attacks hit their doorway; linear beams and rings now use their actual contact positions.
- Fixed Super Secret Room candidate stars above the topmost visible minimap room being clipped off-screen while the gold doorway outline remained visible.

---

GoodTripPlus 2.6.6（待发布）
自 2.5.0 以来的累计更新

新增与调整：

- 在房间内绘制普通、超级、究极隐藏房的白色、金色、红色候选门框；普通／超级两种可能并存时平滑换色，真实隐藏房入口打开前保留门框。
- 小地图星号和房间门框共用候选信息。候选随探索、公开的特殊房图标、藏宝图和世界牌更新；特殊房入口、Boss 房、L 型房间与窄房长边使用更细的排除规则。未探索灰色房间不会提前暴露真实类型或门位。
- 狗牙、“嘿，听好！”、红钥匙原版门框，以及已确认来源的踩踏、破墙泪弹、岩石波和整房间效果可排除假候选。真实隐藏房门位在入口打开前受保护。
- 增强红钥匙、碎裂钥匙和该隐魂卡的原版红色门框显示，修正镜中世界的门框位置与朝向，并覆盖回溯线／家园中实际存在的红钥匙门框。
- Mod Config Menu 新增候选门框开关、迷失诅咒显示开关和 0%–100% 不透明度选项；打开菜单时门框暂时隐藏。
- 奖励房门传送限制拆为恶魔／天使房门和 Boss Rush／蓝子宫门两组默认关闭的开关。对应限时内的 Boss Rush／蓝子宫门及持有山羊头／圣餐的玩家可获豁免，其他传送条件仍适用。

修复与优化：

- 已访问且出口开放的无怪普通房、完成的挑战房，在本模组的地图与传送规则中视作已清理，不修改游戏房间状态。
- 地图操作期间屏蔽堕化遗骸及其灵魂的投掷方向输入；释放地图键及已按住的方向键后恢复正常操作。
- 候选门框使用固定帧绘制，仅双类型候选逐帧换色；破墙泪弹与岩石波按来源和场景追踪。三美元纸币经实测不能开隐藏房，已从破墙泪弹来源移除。
- 同步门框、小地图星号与已检查门位的排除记录，减少换房或继续游戏后的错误候选。

升级提示：更新后完全退出并重启游戏。门框和星号标记的是候选位置，不保证每处都是真实隐藏房。正式发布前仍需完成最新规则的游戏内回归。

Changes since 2.5.0 (2.6.6, unreleased)

- Added in-room white, gold, and red candidate doorways for regular, super, and ultra secret rooms. Ambiguous regular/super candidates cycle smoothly; revealed real entrances stay marked until opened.
- Kept minimap stars and doorways on the same candidate data. Exploration, public room icons, Treasure Map, and The World update candidates without exposing hidden room types or door layouts.
- Improved candidate filtering around special rooms, boss rooms, L-shaped rooms, and narrow room walls; clues and verified wall-opening effects exclude false candidates while protecting real entrances.
- Improved native Red Key doorway visibility, including Cracked Key and Soul of Cain, mirror-world alignment, and existing Red Key doorways on the Ascent and Home floors.
- Added doorway visibility, Curse of the Lost, and opacity controls to Mod Config Menu. Doorways hide while the menu is open.
- Added separate travel settings for Devil/Angel and Boss Rush/Blue Womb doors, with matching time-window and Goat Head/Eucharist exceptions.
- Treated visited enemy-free rooms with an open exit as cleared for this mod's map and travel logic, and prevented The Forgotten's body throw during map controls.
- Reduced irrelevant doorway and wall-breaking checks; removed 3 Dollar Bill from the wall-breaking tear source list after in-game testing.

Restart the game after updating. The latest candidate and travel rules still need final in-game regression checks before release.

---

GoodTripPlus 2.5.0
自 2.4.0 以来的累计更新

调整：

- 新增鼠标传送：按住地图键，移动鼠标选择房间，左键点击传送。鼠标选房按小地图实际绘制位置和房间形状识别。
- 支持键盘与鼠标光标自动切换。按方向键切回键盘时，光标从当前房间重新起步；再次移动鼠标即可切回鼠标控制。
- 新增“每次移动一格”选项，默认关闭。开启后，每次方向键按下移动一个 1×1 房间格距，长按不重复；关闭时仍按光标速度连续移动。

修复与优化：

- 修复小地图房间距离不刷新、走过或传送过的房间距离一直保留为 0 的问题，同时修复最远房间高亮错误。
- 修复残损铁镐、地球和硫酸泪弹揭露隐藏房后，Lazy Delver 候选标记要等换房才刷新的问题。攻击命中假候选门位后，也会及时排除该位置；兼容未加载 REPENTOGON 的普通游戏。
- 改进完全退出游戏后的地图记忆：统一保存当前楼层的掉落物图标、门图、隐藏房候选排除结果和已检查门位，继续游戏时恢复。定期检查变更并在正常退出时再次保存，各类数据互不覆盖。
- 修复同层房间数量变化导致门图存档失效的问题。使用稳定的楼层身份，保留换层、新局与楼层重新生成时的数据隔离。
- 减少隐藏房刷新开销：正常更新只检查真实隐藏房，候选列表仅在重建时扫描；普通攻击提前过滤，铁镐排障探针仅在调试模式运行。
- 游戏控制台提示和诊断改为 ASCII 英文，避免 rewind 恢复提示等中文输出乱码。

升级提示：

- 鼠标模式下松开地图键只关闭地图；左键点击才传送。键盘模式仍保留松开地图键传送，所有操作沿用现有传送准入与冷却规则。
- “每次移动一格”位于“光标速度”下方，开启时不使用光标速度，鼠标操作不受影响。
- 地图记忆从新版运行后开始记录，之前已经丢失的信息无法补回。已经拾取的掉落物不会因恢复图标而重新出现；当前房间以实时扫描为准。
- 更新后请重启游戏，使新的 Lua 代码生效。

Changes since 2.4.0

Changes:

- Added mouse teleport controls: hold the map button, move the mouse to select a room, and left-click to teleport. Mouse selection follows the minimap's rendered positions and room shapes.
- Added automatic switching between keyboard and mouse cursors. Switching back with a direction key starts the keyboard cursor at the current room; moving the mouse again restores mouse control.
- Added "Move One Grid Cell at a Time", disabled by default. Each direction press moves one 1×1 room cell without repeating while held. When disabled, continuous movement still uses Cursor Speed.

Fixes and Improvements:

- Fixed stale minimap room distances that left previously visited or teleported rooms at 0, along with incorrect furthest-room highlighting.
- Fixed Lazy Delver candidates waiting for a room change to refresh after secret doors are revealed using Notched Axe, Terra, or Sulfuric Acid tears. Hits on false candidate door positions now exclude those positions promptly. Also works without REPENTOGON loaded.
- Improved map memory after fully closing the game: current-floor pickup icons, door graphs, excluded secret-room candidates, and checked entrances are saved together and restored when continuing. Changes are checked periodically and saved again on normal exit, without one data section overwriting another.
- Fixed door saves becoming invalid when the room count changes on the same floor. Stable floor identities preserve isolation across floors, new runs, and regenerated layouts.
- Reduced secret-marker update overhead: regular updates check only real secret rooms, and candidate lists are scanned only when rebuilt. Ordinary attacks return early; axe diagnostic probes run only in debug mode.
- Changed game-console messages and diagnostics to ASCII English to prevent garbled output, including rewind restoration messages.

Upgrade Notes:

- Releasing the map button in mouse mode only closes the map; left-click to teleport. Keyboard mode still teleports on map-button release. All controls use the existing teleport admission and cooldown rules.
- "Move One Grid Cell at a Time" is below "Cursor Speed". It ignores Cursor Speed when enabled and does not affect mouse controls.
- Map memory starts recording after the new version runs; information already lost cannot be recovered. Restoring icons does not bring back collected pickups, and the current room uses its live pickup scan.
- Restart the game after updating so the new Lua code takes effect.
