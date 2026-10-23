# StormPro Lua Scripts

为 StormPro 整理的 GTA V Lua 脚本源码、使用说明和模拟测试。

## 脚本

| 文件 | 版本 | 功能与状态 |
| --- | --- | --- |
| [马克兔倒飞.lua](马克兔倒飞.lua) | 3.2 | 一键倒飞、自动横滚平衡；修复离地判定，提供手动高度兼容。[说明](马克兔倒飞说明.md) |
| [ESP透视.lua](ESP透视.lua) | 1.2 | 玩家/NPC 方框、平滑跟随及节流更新。[说明](ESP说明.md) |
| [扳机自瞄.lua](扳机自瞄.lua) | 2.1 | 自瞄与扳机，附原生接口兼容和诊断选项。[说明](重写说明.md) |
| [扳机子弹追踪.lua](扳机子弹追踪.lua) | 2.04 | 弹道相关实验与诊断；默认只观察，部分功能被锁定 |
| [导弹锁定玩家.lua](导弹锁定玩家.lua) | 2.1 | 通过本地辅助目标接入载具原生导弹锁定。[说明](导弹锁定说明.md) |
| [保险箱一键领取.lua](保险箱一键领取.lua) | 1.0 | 串行请求领取七类资产现有保险箱余额。[说明](保险箱领取说明.md) |
| [车友会.lua](车友会.lua) | 1.10 | 洛圣都车友会奖品、声望和解锁 |
| [夜总会人气.lua](夜总会人气.lua) | 1.01 | 夜总会人气设置及读回校验 |
| [自定义等级.lua](自定义等级.lua) | — | 自定义等级与经验计算；以当前文件为准 |

## 安装

将需要的 `.lua` 文件放入 `%AppData%\stormpro\lua\`，在 StormPro 中加载。更新时先卸载已运行的旧版，再加载新版；只替换磁盘文件不等于更新了运行中的脚本。

脚本使用 StormPro 提供的宿主接口和 GTA native，不能直接作为 Stand、Lexis、FiveM 或普通 Lua 程序运行。API 参考和运行时由宿主提供，不包含在此仓库中。

## 验证

本仓库的模拟测试在隔离环境中验证逻辑、调用约束及资源清理，不连接游戏。安装 Node.js 后可运行：

```powershell
npx --yes --package=fengari-node-cli fengari tests/inverted_mk2_spec.lua
npx --yes --package=fengari-node-cli fengari tests/esp_spec.lua
npx --yes --package=fengari-node-cli fengari tests/trigger_aim_spec.lua
npx --yes --package=fengari-node-cli fengari tests/missile_lock_spec.lua
npx --yes --package=fengari-node-cli fengari tests/safe_collect_spec.lua
```

2026-10-23 发布检查：9 个 Lua 语法解析通过，5 套测试共 122 项通过。ESP 测试在缺少本地历史备份时跳过旧版性能对比，仍执行当前版本的全部功能测试与调用预算检查。

后续倒飞 v3.2 修复新增 5 项测试；倒飞相关 32 项模拟测试通过。

实际兼容性依赖游戏版本、StormPro 的 native 调用器及接口返回行为。模拟测试通过不表示游戏内效果已全部验证；各说明文件记录已知范围。包含 Global/Stat 索引的功能需要随游戏更新重新核对。

## 来源与整理范围

本仓库收录九个可读源码脚本，以及对应测试和说明。研究参考链接保留在各脚本说明中；保险箱索引来源记录在 [source.json](research/safe_collection/source.json)。

历史备份、游戏截图、调试图片、第三方混淆脚本及大体积研究资料保留在本地，未放入本仓库。说明中提到的 `backups/` 路径属于开发时的本地记录，并非仓库内可下载的历史版本。
