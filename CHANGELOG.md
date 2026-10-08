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
