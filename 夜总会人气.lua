-- ============================================================
--  夜总会满人气   for StormPro Lua   v1.01
--
--  v1.01 修正(对照 LuaAPI文档 逐条):
--    · 角色槽检测升级为三档(文档1845 globals.get_int(1574927) / Stats.GetMPCharacterIndex / MPPLY_LAST_MP_CHAR)
--    · InputText 去掉文档未定义的第3个参数
--    · 写入后立即读回校验, 当场判断"真写入 / 假成功"
--    · read_int 增加 joaat 名字回退(文档1230: Stats.get_int(joaat(...)))
-- ============================================================
--  目标统计: CLUB_POPULARITY  (角色统计, 走 MP0_/MP1_ 槽位)
--  数值范围: 0 - 1000   (来源: 你提供的 GTAHaX 手册 "夜总会奖章奖杯代码")
--            $MP0_CLUB_POPULARITY 夜总会人气 / 0 - 1000
--
--  写入层与 车友会.lua 完全一致(你已实测成功, "成功 2 次"):
--      A) Stats.set_int("MPX_CLUB_POPULARITY", 值)              -- 菜单高层接口
--      B) STATS.STAT_SET_INT(joaat("MP0_/MP1_CLUB_POPULARITY"), 值, true)  -- native 直写
--      两者都是"只进不出"的输入型调用, 不涉及任何出参指针。
--
--  读取只用 Stats.get_int(名字), 不使用 STAT_GET_INT(它需要出参指针)。
--
--  人气会随时间衰减 -> 脚本提供"保持满人气"(定时重写, 默认关闭)。
--  生效: 切战局 / 重新进夜总会后查看人气条。
-- ============================================================

local S = {
    -- 写入范围
    slot_mode   = "auto",     -- auto / mp0 / mp1 / both
    detected    = nil,

    -- 数值
    lv_input    = "1000",     -- 主输入框(0-1000)
    rep_input   = "1000",     -- 自定义数值

    -- 保持人气
    hold        = false,
    hold_ms     = 5000,
    hold_value  = 1000,
    last_hold   = -999999,

    -- 状态
    cur         = nil,
    backup      = nil,
    backup_tag  = "",
    last_log    = "尚未写入",
    readback    = nil,
    detect_src  = "-",
    tick_err    = "无",
    ticks       = 0,
    frame       = 0,
}

local BASE = "CLUB_POPULARITY"
local VMAX = 1000

-- ============================================================
--  小工具
-- ============================================================
local function num(n)
    if type(n) ~= "number" then return "?" end
    local s = tostring(math.floor(n))
    while true do
        local out, cnt = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
        s = out
        if cnt == 0 then break end
    end
    return s
end

local function hash(name)
    if type(joaat) == "function" then
        local ok, h = pcall(joaat, name)
        if ok and type(h) == "number" then return h end
    end
    if natives then
        if type(natives.joaat) == "function" then
            local ok, h = pcall(natives.joaat, name)
            if ok and type(h) == "number" then return h end
        end
        if type(natives.invoke) == "function" then
            local ok, h = pcall(function()
                return natives.invoke(0xD24D37CC275948CC, name):get_int()  -- GET_HASH_KEY
            end)
            if ok and type(h) == "number" then return h end
        end
    end
    return nil
end

local function read_int(name)
    if Stats and type(Stats.get_int) == "function" then
        local ok, v = pcall(Stats.get_int, name)
        if ok and type(v) == "number" then return v end
        -- 文档1230: 名字读不到时用 joaat 哈希再试一次
        local h = hash(name)
        if h then
            local ok2, v2 = pcall(Stats.get_int, h)
            if ok2 and type(v2) == "number" then return v2 end
        end
    end
    return nil
end

-- 当前在线角色槽: 三档检测(与 车友会.lua v1.10 一致)
local function detect_slot()
    local function valid(d) return d == 0 or d == 1 end
    if Stats and type(Stats.GetMPCharacterIndex) == "function" then
        local ok, idx = pcall(Stats.GetMPCharacterIndex)
        if ok and type(idx) == "number" and valid(idx) then return idx, "Stats.GetMPCharacterIndex" end
    end
    if globals and type(globals.get_int) == "function" then
        local ok, v = pcall(globals.get_int, 1574927)   -- 文档1845行: 全局变量=当前在线角色槽
        if ok and type(v) == "number" and valid(v) then return v, "globals.get_int(1574927)" end
    end
    local d = read_int("MPPLY_LAST_MP_CHAR")
    if valid(d) then return d, "MPPLY_LAST_MP_CHAR" end
    return nil, "检测失败"
end

local function target_names(base)
    if S.slot_mode == "both" then
        return { "MP0_" .. base, "MP1_" .. base }
    elseif S.slot_mode == "mp0" then
        return { "MP0_" .. base }
    elseif S.slot_mode == "mp1" then
        return { "MP1_" .. base }
    end
    if S.detected == nil then
        return { "MP0_" .. base, "MP1_" .. base }
    end
    return { "MP" .. S.detected .. "_" .. base }
end

local function apply_int(base, value)
    local log, okc = {}, 0
    if S.slot_mode == "auto" and Stats and type(Stats.set_int) == "function" then
        local ok, err = pcall(Stats.set_int, "MPX_" .. base, value)
        if ok then okc = okc + 1 else log[#log + 1] = "菜单接口: " .. tostring(err) end
    end
    for _, nm in ipairs(target_names(base)) do
        local h = hash(nm)
        if h and STATS and type(STATS.STAT_SET_INT) == "function" then
            local ok, err = pcall(STATS.STAT_SET_INT, h, value, true)
            if ok then okc = okc + 1 else log[#log + 1] = nm .. ": " .. tostring(err) end
        end
    end
    return okc, log
end

local function now_ms()
    local ok, t = pcall(MISC.GET_GAME_TIMER)   -- 零参数, 只返回 int, 无出参
    if ok and type(t) == "number" then return t end
    return 0
end

local function btn(label, fn)
    if StormPro.Button(label) then fn() end
end

local function slider_int(label, key, vmin, vmax)
    local a = StormPro.SliderInt(label, S[key], vmin, vmax)
    if type(a) == "number" then
        S[key] = math.floor(a + 0.5)
        if S[key] < vmin then S[key] = vmin elseif S[key] > vmax then S[key] = vmax end
    end
end

local function refresh()
    S.detected, S.detect_src = detect_slot()
    local v = read_int("MPX_" .. BASE)
    if v == nil then v = read_int("MP" .. (S.detected or 0) .. "_" .. BASE) end
    if v ~= nil then S.cur = v end
end

-- ============================================================
--  写入
-- ============================================================
local function do_write(value, tag, silent)
    if type(value) ~= "number" then return 0 end
    value = math.floor(value)
    if value < 0 then value = 0 elseif value > VMAX then value = VMAX end

    if S.backup == nil and S.cur ~= nil then
        S.backup = S.cur
        S.backup_tag = (tag or "写入") .. " 之前自动备份"
    end

    local okc, log = apply_int(BASE, value)
    S.cur = value

    -- ★v1.01: 写入后立即读回, 当场判断"真写入 / 假成功"
    local rb = read_int("MPX_" .. BASE)
    if rb == nil then rb = read_int("MP" .. (S.detected or 0) .. "_" .. BASE) end
    S.readback = rb
    local verdict
    if rb == nil then
        verdict = "读回不可用"
    elseif rb == value then
        verdict = "读回一致 ✔"
    else
        verdict = string.format("读回=%s ✘ 未生效(可能名字不对或需切战局)", num(rb))
    end

    S.last_log = string.format("人气 -> %s · 成功 %d 次 · %s%s", num(value), okc, verdict,
        (#log > 0) and (" · " .. table.concat(log, " | ")) or "")

    if not silent then
        if okc > 0 then
            StormPro.ShowNotification(string.format("[夜总会] 人气已写入 %s，切战局/重进夜总会后查看", num(value)))
        else
            StormPro.ShowNotification("[夜总会] 写入失败：未检测到可用的 Stats / natives 接口")
        end
    end
    return okc
end

local function set_hold_value(v)
    v = math.floor(tonumber(v) or 0)
    if v < 0 then v = 0 elseif v > VMAX then v = VMAX end
    S.hold_value = v
    S.last_hold = -999999
    StormPro.ShowNotification(string.format("[夜总会] 保持人气目标 = %s", num(v)))
end

-- ============================================================
--  生命周期
-- ============================================================
function on_init()
    StormPro.RegisterMenu("夜总会人气")
    refresh()
    StormPro.ShowNotification("[夜总会] 满人气模块已加载 (人气范围 0-1000)")
end

function on_stop()
    S.hold = false
end

function on_tick()
    S.ticks = S.ticks + 1
    if not S.hold then return end
    local ok, err = pcall(function()
        local now = now_ms()
        if (now - S.last_hold) >= S.hold_ms then
            -- 先读一次, 只有掉下来才重写(减少无谓写入)
            local cur = read_int("MPX_" .. BASE)
            if cur == nil or cur < S.hold_value then
                do_write(S.hold_value, "保持人气", true)
            end
            S.last_hold = now
        end
    end)
    if not ok then S.tick_err = tostring(err) end
end

function on_menu_render()
    S.frame = S.frame + 1
    if S.frame == 1 or S.frame % 60 == 0 then refresh() end

    StormPro.TextColored("夜总会 · 满人气 (CLUB_POPULARITY)", 1.0, 0.85, 0.2, 1.0)
    StormPro.Separator()

    -- 当前人气
    if S.cur ~= nil then
        local pct = math.floor((S.cur / VMAX) * 100 + 0.5)
        StormPro.Text(string.format("当前人气: %s / %d  (约 %d%%)", num(S.cur), VMAX, pct))
    else
        StormPro.Text("当前人气: 读取不可用 (不影响写入)")
    end
    StormPro.Spacing()

    -- 主写入
    StormPro.TextColored("[1] 写入人气", 0.4, 0.85, 1.0, 1.0)
    local txt = StormPro.InputText("人气数值 (0-1000):", S.lv_input)
    if type(txt) == "string" then S.lv_input = txt end
    local v = tonumber(S.lv_input)
    if v then
        v = math.floor(v)
        if v < 0 then v = 0 elseif v > VMAX then v = VMAX end
        if StormPro.Button(string.format("写入人气 %d", v)) then
            do_write(v, string.format("写入人气 %d", v))
        end
    else
        StormPro.TextDisabled("请输入 0 - 1000 的整数")
    end

    btn("满人气 (1000)", function() do_write(1000, "满人气") end)
    StormPro.SameLine()
    btn("半人气 (500)", function() do_write(500, "半人气") end)
    StormPro.SameLine()
    btn("低人气 (100)", function() do_write(100, "低人气") end)
    StormPro.Spacing()

    -- 保持
    StormPro.TextColored("[2] 保持满人气 (人气会自然衰减)", 0.4, 0.85, 1.0, 1.0)
    local mark = S.hold and "[开] 保持满人气 (点击关闭)" or "[关] 保持满人气 (点击开启)"
    if StormPro.Button(mark) then
        S.hold = not S.hold
        S.last_hold = -999999
        if S.hold then set_hold_value(S.lv_input) end
    end
    slider_int("检查间隔 (ms)", "hold_ms", 1000, 60000)
    if S.hold then
        StormPro.TextColored(string.format("  运行中: 保持 %s, 每 %d ms 检查一次", num(S.hold_value), S.hold_ms),
            0.45, 1.0, 0.45, 1.0)
    end
    StormPro.TextDisabled("  开启后每 N 秒检查一次, 只有掉下来才重写, 减少写入次数")
    StormPro.Spacing()

    -- 备份/恢复
    StormPro.Separator()
    if S.backup ~= nil then
        StormPro.Text(string.format("已备份原人气: %s", num(S.backup)))
        StormPro.TextDisabled("  " .. S.backup_tag)
        if StormPro.Button("恢复原人气") then
            local b = S.backup
            local okc = apply_int(BASE, b)
            S.cur = b
            S.last_log = string.format("已恢复原人气 %s · 成功 %d 次", num(b), okc)
            StormPro.ShowNotification(string.format("[夜总会] 已恢复原人气 %s", num(b)))
        end
    else
        StormPro.TextDisabled("尚未备份原人气 (首次写入前会自动读取并备份)")
    end
    StormPro.Spacing()

    -- 写入范围
    StormPro.Separator()
    StormPro.TextColored("[3] 写入范围", 0.4, 0.85, 1.0, 1.0)
    local mode_name = "自动(当前角色)"
    if S.slot_mode == "mp0" then mode_name = "仅角色1 (MP0)"
    elseif S.slot_mode == "mp1" then mode_name = "仅角色2 (MP1)"
    elseif S.slot_mode == "both" then mode_name = "两个角色 (MP0+MP1)" end
    StormPro.Text("当前: " .. mode_name)
    if S.slot_mode == "auto" then
        if S.detected == nil then
            StormPro.TextDisabled("  未检测到当前角色 -> 实际按双角色兜底写入")
        else
            StormPro.TextDisabled(string.format("  检测到当前为角色%d (MP%d, 来源: %s)", S.detected + 1, S.detected, tostring(S.detect_src)))
        end
    end
    btn("自动", function() S.slot_mode = "auto" end)
    StormPro.SameLine()
    btn("角色1", function() S.slot_mode = "mp0" end)
    StormPro.SameLine()
    btn("角色2", function() S.slot_mode = "mp1" end)
    StormPro.SameLine()
    btn("双角色", function() S.slot_mode = "both" end)
    StormPro.Spacing()

    -- 配套(可选)
    StormPro.Separator()
    StormPro.TextColored("[4] 配套 (可选, 与奖杯/折扣有关)", 0.4, 0.85, 1.0, 1.0)
    btn("玩家访问量 = 100", function()
        local okc = apply_int("NIGHTCLUB_PLAYER_APPEAR", 100)
        S.last_log = string.format("玩家访问量 -> 100 · 成功 %d 次", okc)
    end)
    StormPro.SameLine()
    btn("名流到访 = 100", function()
        local okc = apply_int("NIGHTCLUB_VIP_APPEAR", 100)
        S.last_log = string.format("名流到访 -> 100 · 成功 %d 次", okc)
    end)
    btn("跳舞时间 = 46800", function()
        local okc = apply_int("DANCE_COMBO_DURATION_MINS", 46800)
        S.last_log = string.format("跳舞时间 -> 46800 · 成功 %d 次", okc)
    end)
    StormPro.SameLine()
    btn("黄金跳舞奖杯 = 40320000", function()
        local okc = apply_int("NIGHTCLUB_HOTSPOT_TIME_MS", 40320000)
        S.last_log = string.format("黄金跳舞奖杯时间 -> 40320000 · 成功 %d 次", okc)
    end)
    btn("夜总会差事 = 10 (patriot2/blimp3 折扣)", function()
        local okc = apply_int("NIGHTCLUB_JOBS_DONE", 10)
        S.last_log = string.format("夜总会差事 -> 10 · 成功 %d 次", okc)
    end)
    StormPro.TextDisabled("  这些是手册上的配套项, 不改钱、只影响奖杯和购买折扣")
    StormPro.Spacing()

    -- 日志
    StormPro.Separator()
    StormPro.TextDisabled("最近: " .. S.last_log)
    if S.readback ~= nil then
        StormPro.TextDisabled(string.format("写入后读回: %s", num(S.readback)))
    end
    if S.tick_err ~= "无" then
        StormPro.TextColored("tick 异常: " .. S.tick_err, 1.0, 0.4, 0.4, 1.0)
    end
    StormPro.Spacing()
    StormPro.TextDisabled("【生效】写入 -> 切战局 或 重新进夜总会 -> 看人气条")
    StormPro.TextDisabled("【范围】手册标注 0-1000; 若你的版本上限是 100, 用 [低人气100] 那个按钮")
    StormPro.TextDisabled("【安全】与 车友会.lua 同一套写入接口(已实测可用), 无出参 native")
end
