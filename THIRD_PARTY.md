# 来源与授权（THIRD_PARTY）

本文件记录 GoodTripPlus 每一部分代码的来源与授权状况，以及**公开发布前必须处理的事项**。
授权范围的正式声明见 `LICENSE`。

## 一览

| 来源 | 用到什么 | 授权 | 状态 |
| --- | --- | --- | --- |
| **Goodtrip MLX's Tweak**<br>(Steam 工坊 3749565569) | `scripts/gtrep.lua` 几乎是逐字副本（仅改注册名与配置键、加诊断命令） | **无许可证文件** → 默认保留所有权利 | ⚠️ **未获授权** |
| **GoodTrip**（原始版本，作者 tarako） | MLX's Tweak 本身就是它的二次开发，因此本条也在授权链上 | **无许可证文件** → 默认保留所有权利 | ⚠️ 间接依赖 |
| **Lazy Delver**<br>(作者 dokee，工坊 3751630929，[GitHub](https://github.com/dokee39/IsaacLazyDelver)) | `scripts/delver/`（const / geometry / log / state / map / room 原样移植）、`resources/gfx/goodtripplus/marker.anm2` 与 `marker.png` | **MIT** | ✅ 已合规 |
| **MinimapAPI**<br>(作者 TazTxUK，工坊 1978904635，[GitHub](https://github.com/TazTxUK/MinimapAPI)) | 仅在运行时调用其 API、读取其内部表结构（`MinimapAPI.Levels` 等）与配置项 | 仓库无许可证；但**本仓库未包含其任何代码或素材** | ✅ 无需许可（作为依赖） |
| `resources/gfx/goodtripplus/TintedSkull.*`<br>（深牢 II 愚者骷髅房的标记图标） | 16x16 PNG 由使用者自行绘制并提供；`TintedSkull.anm2` 是本项目自写 | 使用者自绘素材 | ✅ 使用者已确认来源 |
| 本项目自有代码 | rewind 掉落物图标修复、隐藏房标记的对接与渲染、深牢 II 骷髅房标记、部署脚本 | MIT（本仓库声明） | ✅ |

### 关于 TintedSkull.png（标记图标）

使用者于 2026-10-03 确认该素材由自己绘制；当前版本参考图像建议重新绘制，并调整了落点。
画布为 16x16，实际内容为 7x8，位于 `(3,2)–(9,9)`，其余区域透明，alpha 仅为 0 或 255。
配套动画为 `resources/gfx/goodtripplus/TintedSkull.anm2`，图标 ID 与动画名均为 `TintedSkull`。


## 关键问题：上游基底没有许可证

`scripts/gtrep.lua` 是 Goodtrip MLX's Tweak 的二次修改，而 MLX's Tweak 又是 tarako 的 GoodTrip 的二次开发。
**这两者都没有附带任何许可证文件。** 按通行版权规则（无许可证 = 保留所有权利 = 未授予你任何权利），
把它们复制、修改后再分发，需要取得权利人许可 —— 即使标注了出处、即使只是发在免费的创意工坊上。

另外，Steam 创意工坊本身也要求上传者对所上传内容拥有相应权利，未授权的二次上传可能被下架。

> 注意：社区里确实存在大量「fork 别人的 mod 再修 bug」的做法，[GoodTrip \[Fixed\]](https://steamcommunity.com/workshop/filedetails/?id=2916069863)
> 就是著名的例子，且公开了源码（[archibate/isaacmods](https://github.com/archibate/isaacmods)）。
> 但那些仓库同样**没有 LICENSE 文件**，属于「事实上的宽容惯例」而不是「你已获得许可」。
> 做法可以借鉴，风险要自己承担。

## 发布前的处理路线

### 路线 A（最稳）：先取得上游许可

1. 通过工坊页面私信 / 留言联系 **MLX's Tweak 的作者**，说明你要发布的是「修复 rewind bug」的二次开发版本，
   请求许可；同时**在描述里致谢 tarako（原始 GoodTrip 作者）**。
2. 拿到许可后即可发布完整包，`LICENSE` 只需覆盖本项目自有代码（且仍需携带 Lazy Delver 的 MIT 文本）。
3. 把对方的许可回复截图/文字留档（万一被举报时可自证）。

### 路线 B（不需要 MLX 许可）：只发布「附加模块」，把 MLX's Tweak 列为依赖

本项目**真正新增的两块功能本身都不含 MLX 的代码**，可以拆出来单独发布：

- `scripts/gtp_rewindfix.lua`（rewind 图标修复）：零 MLX 依赖，只用 MinimapAPI 和标准回调，天然干净。
- `scripts/gtp_delver.lua` + `scripts/delver/*`（隐藏房标记）：依赖 Lazy Delver（MIT，合规）；
  唯一需要处理的是渲染时调用的投影函数 `gt:gid_to_rtmap_pos()` —— 它定义在 `scripts/gtrep.lua` 里，
  属于 MLX 的代码，需要在自有模块中改写成不依赖它的实现
  （可以直接依托 MinimapAPI 房间对象的 `RenderOffset` 反推格子坐标，比复刻公式更稳）。

拆出来后发布一个「只含上述模块」的 mod，在工坊把它声明为依赖 MLX's Tweak / MinimapAPI 的附加组件。
代价是要重构投影那一小块（约 80 行），并且用户体验上多一步：需要同时订阅 MLX's Tweak。

### 路线 C：不公开

仅自用或私下小范围分享，风险自担。这种情况下 `LICENSE` 里的 MIT 只影响你自己的代码，无实际影响。

## 发布检查清单（无论走哪条路线）

- [ ] **上游许可已确认**（路线 A）或**已确认包里不含上游代码**（路线 B）。
- [ ] `scripts/delver/LICENSE-lazy-delver.txt` **随包分发**（MIT 要求：任何实质性副本都要带上版权与许可声明）。
      注意 `deploy.sh` 会把它一起同步到 `mods/goodtripplus/`，打 zip 时不要漏掉。
- [ ] 工坊「必需物品 / Required items」里勾选 **MiniMAPI**；路线 B 还要勾 MLX's Tweak。
- [ ] 描述里明确写出：原始 GoodTrip 作者 tarako、基底 MLX's Tweak、隐藏房标记来自 Lazy Delver (dokee, MIT)。
- [ ] 描述里提示：**GoodTripPlus 与 MLX's Tweak / 原版 Goodtrip 功能重叠，只能启用一个**；
      并提示「已合并 Lazy Delver，请禁用 Lazy Delver 本体」。
- [ ] 不要使用他人的封面图、截图；`resources/gfx/goodtripplus/TintedSkull.png` 已由使用者确认自行绘制
      （尺寸和落点见上文「关于 TintedSkull.png」；`marker.*` 来自 Lazy Delver，MIT 已合规）。
- [ ] mod 必须免费，不得以任何形式商业化。
- [ ] 上传时由 ModUploader 分配工坊 id，`metadata.xml` 里的 `<id>` 会被替换成它。
