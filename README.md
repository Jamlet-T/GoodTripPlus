# GoodTripPlus

GoodTripPlus 是《以撒的结合：忏悔+》的 MiniMAPI 外置传送插件，基于 Goodtrip MLX's Tweak 开发。

## 安装

- 安装必需依赖 **MiniMAPI**，并将模组放入 `mods/goodtripplus`。
- 可选安装 **Mod Config Menu** 以调整游戏内设置。
- 停用 Goodtrip、Goodtrip MLX's Tweak 和 Lazy Delver，避免重复功能。
- 安装或更新后重启游戏。

## 使用

按住地图键并用射击方向键移动光标，松开地图键传送；也可移动鼠标控制光标并左键点击目标房间。

默认只能传送到相邻房间。可在 MCM 中选择相邻房间、已探索房间或任意房间；任意房间模式会绕过多项传送限制，可能显著影响游戏平衡。

## 功能

- **传送判定**：统一处理传送范围、房间状态、诅咒房限制和奖励门限制。
- **相邻房门自动解锁**：可支付资源解锁当前相邻房门后传送，默认关闭。
- **鼠标传送**：支持鼠标移动光标和点击传送，并与键盘操作共享判定规则。
- **地图记忆**：保存并恢复当前楼层的掉落物图标、门图和隐藏房探索状态。
- **rewind 修复**：修复使用控制台 `rewind` 后地图上的掉落物图标消失。
- **隐藏房标记**：显示并随探索更新隐藏房候选位置，标记布局与 MiniMAPI 对齐。
- **特殊房间标记**：标记深牢 II / XL 的愚者骷髅房及矿洞 II 的黄色轨道按钮房。
- **地图边界高亮**：按住地图键时显示地图边界房间。
- **战斗地图设置**：支持配置战斗时隐藏地图，以及在战斗中保留大地图。

传送过场保留淡入淡出和传送动画两档；改用原生快照保存入口，修复传送回滚的快照时机。

## 独立模组集成

**Secret Candidate Outlines** 是独立模组，以 GoodTripPlus 为运行时依赖，读取 `scripts/delver/` 的隐藏房候选数据，并调用现有的门位撞击判定；它不随包分发 GoodTripPlus 的代码或素材。

GoodTripPlus 自有代码与所移植的 Lazy Delver 组件分别按 [LICENSE](LICENSE) 与 [THIRD_PARTY.md](THIRD_PARTY.md) 中列出的 MIT 条款提供。独立模组可以在遵守对应许可的前提下使用这些部分；`scripts/gtrep.lua` 所基于的上游 GoodTrip 代码有单独的授权范围，本节不扩大该范围。这里记录的是上述模组的集成方式，不承诺内部 Lua 模块将保持稳定接口。

## 打包

开发者可在模组目录运行 `./pack.sh`，生成 `dist/goodtripplus-<版本>.zip`。分发时请保留包内许可证文件。

## 授权

本项目包含不同来源和授权的代码与素材。详情见 [LICENSE](LICENSE) 和 [THIRD_PARTY.md](THIRD_PARTY.md)。如需讨论上游代码，请通过 [GitHub Issues](https://github.com/Jamlet-T/GoodTripPlus/issues) 联系维护者。
