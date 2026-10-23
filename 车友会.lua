-- ============================================================
--  洛圣都车友会 · 奖品载具 / 声望 / 全套解锁   v1.10
--  for StormPro Lua   (已按官方 LuaAPI文档.md 校正)
-- ============================================================
--  v1.10 新增: 用官方高层接口 Stats.set_packed_bool(index, value) 一键解锁
--              车友会全套 244 条 packed bool:
--                · 15 台改装车 (31810-31824)
--                · 6 项权限/改装铺能力 (追击系列/Quick Fix/Diversion/
--                  Private Takeover/Setup/Wingman)
--                · Tuned For Speed 赛车服 (32224)
--                · 服装 / 涂装 / 轮毂 (其余 222 条)
--              全程只调官方高层函数, 不涉及任何出参指针与内存操作。
--
--  [1] 奖品载具   MPX_CARMEET_PV_CHLLGE_CMPLT (bool)   —— 你已实测可用
--  [2] 车友会声望 MPX_CAR_CLUB_REP            (int)
--      等级换算: 累计(L) = 100 + Σ(c=1..L-1) min(5c+100, 1100)
--      Lv20=2950 Lv30=5175 Lv50=11125 Lv100=34750
--      Lv200=119500 Lv250=174500 Lv500=449500 Lv1000=999500
--      车友会.txt 原表值 998527 = 等级 999
--
--  文档依据: Stats.get/set_int, Stats.set_bool, Stats.set_packed_bool,
--            Stats.GetMPCharacterIndex, natives (输入型)
-- ============================================================

local S = {
    slot_mode   = "auto",     -- auto / mp0 / mp1 / both
    detected    = nil,
    lv_input    = "30",
    rep_input   = "34750",
    guard_max   = true,
    max_armed   = false,
    cur_rep     = nil,
    prize_state = nil,
    backup_rep  = nil,
    backup_tag  = "",
    last_log    = "尚未写入",
    frame       = 0,

    -- packed bool 队列
    queue       = {},
    queue_total = 0,
    queue_done  = 0,
    per_frame   = 10,
    packed_ok   = 0,
    packed_err  = 0,
}

local REP_BASE   = "CAR_CLUB_REP"
local PRIZE_BASE = "CARMEET_PV_CHLLGE_CMPLT"
local REP_MAX    = 999500
local REP_TABLE  = 998527
local LV_CAP     = 1000

-- ============================================================
--  车友会 packed bool 索引表 (来自 车友会.txt, 244 条, 压成 44 个区间)
-- ============================================================
local RANGES = {
    {31810, 31824}, {31826, 31858}, {31860, 31863}, {31865, 31868},
    {31870, 31928}, {31930, 31933}, {31935, 31938}, {31940, 31943},
    {31945, 31948}, {31950, 31953}, {31955, 31958}, {31960, 31963},
    {31965, 31968}, {31970, 31973}, {31975, 31978}, {31980, 31983},
    {31985, 31988}, {31990, 31993}, {31995, 31998}, {32000, 32003},
    {32005, 32008}, {32010, 32013}, {32015, 32018}, {32020, 32023},
    {32025, 32028}, {32030, 32033}, {32035, 32038}, {32040, 32043},
    {32045, 32048}, {32050, 32053}, {32055, 32058}, {32060, 32063},
    {32065, 32074}, {32084, 32084}, {32094, 32094}, {32104, 32104},
    {32114, 32114}, {32124, 32124}, {32134, 32134}, {32144, 32144},
    {32154, 32154}, {32164, 32164}, {32174, 32174}, {32224, 32224},
}

local CARS  = { 31810, 31811, 31812, 31813, 31814, 31815, 31816, 31817,
                31818, 31819, 31820, 31821, 31822, 31823, 31824 }
local PERKS = { 31829, 31834, 31839, 31844, 31849, 31854, 32224 }
local TEST3 = { 31826, 31827, 32224 }

local function all_indices()
    local t = {}
    for _, r in ipairs(RANGES) do
        for i = r[1], r[2] do t[#t + 1] = i end
    end
    return t
end

local function in_list(list, v)
    for _, x in ipairs(list) do if x == v then return true end end
    return false
end

-- 除"车辆 + 权限/赛车服"以外的部分
local function rest_indices()
    local t = {}
    for _, r in ipairs(RANGES) do
        for i = r[1], r[2] do
            if not in_list(CARS, i) and not in_list(PERKS, i) then t[#t + 1] = i end
        end
    end
    return t
end

-- ============================================================
--  等级 <-> 声望
-- ============================================================
local function rep_for_level(L)
    if L <= 1 then return 0 end
    local k = L - 1
    local s
    if k <= 200 then s = 5 * k * (k + 1) / 2 + 100 * k
    else s = 120500 + (k - 200) * 1100 end
    return math.floor(100 + s)
end

local function level_for_rep(r)
    if type(r) ~= "number" then return nil end
    if r < 100 then return 1 end
    if r >= REP_MAX then return LV_CAP end
    local lo, hi = 1, LV_CAP
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if rep_for_level(mid) <= r then lo = mid else hi = mid - 1 end
    end
    return lo
end

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
    return nil
end

local function read_int(name)
    if Stats and type(Stats.get_int) == "function" then
        local ok, v = pcall(Stats.get_int, name)
        if ok and type(v) == "number" then return v end
    end
    return nil
end

local function read_bool(name)
    if Stats and type(Stats.get_bool) == "function" then
        local ok, v = pcall(Stats.get_bool, name)
        if ok and type(v) == "boolean" then return v end
    end
    local v = read_int(name)
    if v ~= nil then return v ~= 0 end
    return nil
end

-- 当前角色槽: 优先用官方 Stats.GetMPCharacterIndex()
local function detect_slot()
    if Stats and type(Stats.GetMPCharacterIndex) == "function" then
        local ok, idx = pcall(Stats.GetMPCharacterIndex)
        if ok and (idx == 0 or idx == 1) then return idx end
    end
    local d = read_int("MPPLY_LAST_MP_CHAR")
    if d == 0 or d == 1 then return d end
    return nil
end

local function target_names(base)
    if S.slot_mode == "both" then return { "MP0_" .. base, "MP1_" .. base }
    elseif S.slot_mode == "mp0" then return { "MP0_" .. base }
    elseif S.slot_mode == "mp1" then return { "MP1_" .. base } end
    if S.detected == nil then return { "MP0_" .. base, "MP1_" .. base } end
    return { "MP" .. S.detected .. "_" .. base }
end

local function apply_int(base, value)
    local log, okc = {}, 0
    if S.slot_mode == "auto" and Stats and type(Stats.set_int) == "function" then
        local ok, err = pcall(Stats.set_int, "MPX_" .. base, value)
        if ok then okc = okc + 1 else log[#log + 1] = "Stats.set_int: " .. tostring(err) end
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

local function apply_bool(base, value)
    local log, okc = {}, 0
    if S.slot_mode == "auto" then
        if Stats and type(Stats.set_bool) == "function" then
            local ok, err = pcall(Stats.set_bool, "MPX_" .. base, value)
            if ok then okc = okc + 1 else log[#log + 1] = "Stats.set_bool: " .. tostring(err) end
        end
    end
    for _, nm in ipairs(target_names(base)) do
        local h = hash(nm)
        if h and STATS and type(STATS.STAT_SET_BOOL) == "function" then
            local ok, err = pcall(STATS.STAT_SET_BOOL, h, value, true)
            if ok then okc = okc + 1 else log[#log + 1] = nm .. ": " .. tostring(err) end
        end
    end
    return okc, log
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
    S.detected = detect_slot()
    local r = read_int("MPX_" .. REP_BASE)
    if r == nil then r = read_int("MP" .. (S.detected or 0) .. "_" .. REP_BASE) end
    if r ~= nil then S.cur_rep = r end
    local p = read_bool("MPX_" .. PRIZE_BASE)
    if p ~= nil then S.prize_state = p end
end

-- ============================================================
--  packed bool 队列 (官方接口, 分帧写入避免卡顿)
-- ============================================================
local function start_unlock(list, label)
    S.queue = {}
    for i = 1, #list do S.queue[i] = list[i] end
    S.queue_total = #S.queue
    S.queue_done = 0
    S.packed_ok = 0
    S.packed_err = 0
    S.last_log = string.format("开始解锁[%s] %d 条 (每帧 %d 条)", label or "自定义", S.queue_total, S.per_frame)
end

local function process_queue()
    if #S.queue == 0 then return end
    local n = math.max(1, S.per_frame)
    for _ = 1, n do
        local idx = table.remove(S.queue, 1)
        if idx == nil then break end
        local ok = false
        if Stats and type(Stats.set_packed_bool) == "function" then
            local rok = pcall(Stats.set_packed_bool, idx, true)
            ok = rok and true or false
        end
        if ok then S.packed_ok = S.packed_ok + 1 else S.packed_err = S.packed_err + 1 end
        S.queue_done = S.queue_done + 1
    end
    if #S.queue == 0 then
        S.last_log = string.format("解锁完成: 成功 %d 条, 失败 %d 条", S.packed_ok, S.packed_err)
        if S.packed_err == 0 then
            StormPro.ShowNotification(string.format("[车友会] 已解锁 %d 条, 切战局后生效", S.packed_ok))
        else
            StormPro.ShowNotification(string.format("[车友会] 解锁完成: 成功 %d / 失败 %d (看日志)", S.packed_ok, S.packed_err))
        end
    end
end

-- ============================================================
--  动作
-- ============================================================
local function do_rep(value, tag)
    if type(value) ~= "number" then return end
    value = math.floor(value)
    if value < 0 then value = 0 end
    if S.backup_rep == nil and S.cur_rep ~= nil then
        S.backup_rep = S.cur_rep
        S.backup_tag = (tag or "写入") .. " 之前自动备份"
    end
    local okc, log = apply_int(REP_BASE, value)
    S.cur_rep = value
    local lv = level_for_rep(value)
    S.last_log = string.format("声望 -> %s (等级 %s) · 成功 %d 次%s", num(value), tostring(lv), okc,
        (#log > 0) and (" · " .. table.concat(log, " | ")) or "")
    if okc > 0 then
        StormPro.ShowNotification(string.format("[车友会] 声望已写入 %s (等级 %s)", num(value), tostring(lv)))
    else
        StormPro.ShowNotification("[车友会] 声望写入失败: 无可用接口")
    end
end

local function do_prize(state)
    local okc = apply_bool(PRIZE_BASE, state)
    S.prize_state = state
    S.last_log = string.format("奖品载具 -> %s · 成功 %d 次", state and "已完成" or "未完成", okc)
    if okc > 0 then
        StormPro.ShowNotification(state and "[车友会] 已标记奖品载具挑战完成, 切战局后去提车"
                                        or "[车友会] 已撤销奖品载具标记")
    else
        StormPro.ShowNotification("[车友会] 写入失败: 无可用接口")
    end
end

-- ============================================================
--  生命周期
-- ============================================================
function on_init()
    StormPro.RegisterMenu("洛圣都车友会")
    refresh()
    local hint = ""
    if not (Stats and type(Stats.set_packed_bool) == "function") then
        hint = " (未检测到 Stats.set_packed_bool, 全套解锁不可用)"
    end
    StormPro.ShowNotification("[车友会] v1.10 已加载" .. hint)
end

function on_tick()
    local ok, err = pcall(process_queue)
    if not ok then S.last_log = "队列异常: " .. tostring(err) end
end

function on_menu_render()
    S.frame = S.frame + 1
    if S.frame == 1 or S.frame % 60 == 0 then refresh() end

    StormPro.TextColored("洛圣都车友会 v1.10", 1.0, 0.85, 0.2, 1.0)
    StormPro.Separator()

    -- [1] 奖品载具
    StormPro.TextColored("[1] 本周奖品载具 (Prize Ride)", 0.4, 0.85, 1.0, 1.0)
    local ptxt
    if S.prize_state == nil then ptxt = "未知 (读取不可用)"
    elseif S.prize_state then ptxt = "已完成 —— 可去车友会提车"
    else ptxt = "未完成" end
    StormPro.Text("挑战状态: " .. ptxt)
    btn("解锁本周奖品载具", function() do_prize(true) end)
    StormPro.SameLine()
    btn("撤销该标记", function() do_prize(false) end)
    StormPro.TextDisabled("生效: 切一次战局 -> 车友会内走到奖品车平台按提示领取")
    StormPro.Spacing()

    -- [2] 声望
    StormPro.Separator()
    StormPro.TextColored("[2] 车友会声望 (Rep)", 0.4, 0.85, 1.0, 1.0)
    if S.cur_rep ~= nil then
        StormPro.Text(string.format("当前: %s  ->  等级 %s / %d", num(S.cur_rep), tostring(level_for_rep(S.cur_rep)), LV_CAP))
    else
        StormPro.Text("当前: 读取不可用 (不影响写入)")
    end
    local lv_txt, lv_chg = StormPro.InputText("目标等级 (1-1000):", S.lv_input)
    if lv_chg then S.lv_input = lv_txt end
    local lv = tonumber(S.lv_input)
    if lv then
        lv = math.floor(lv)
        if lv < 1 then lv = 1 elseif lv > LV_CAP then lv = LV_CAP end
        StormPro.TextDisabled(string.format("  = 需要声望 %s", num(rep_for_level(lv))))
        btn(string.format("写入等级 %d", lv), function() do_rep(rep_for_level(lv), "写入等级") end)
    else
        StormPro.TextDisabled("请输入 1 - 1000 的整数")
    end
    btn("等级 30 (改装铺能力)", function() do_rep(rep_for_level(30), "等级30") end)
    StormPro.SameLine()
    btn("等级 100 (全车折扣)", function() do_rep(rep_for_level(100), "等级100") end)
    StormPro.SameLine()
    btn("等级 250", function() do_rep(rep_for_level(250), "等级250") end)

    local rep_txt, rep_chg = StormPro.InputText("自定义声望数值:", S.rep_input)
    if rep_chg then S.rep_input = rep_txt end
    local rep_v = tonumber(S.rep_input)
    if rep_v then btn("写入该声望数值", function() do_rep(rep_v, "自定义") end) end

    StormPro.TextColored("满级会连带大量升级奖励入账(累计约 4095 万), 风险自负", 1.0, 0.45, 0.45, 1.0)
    local max_label = "写入满级 999500 (等级 1000)"
    if S.guard_max and S.max_armed then max_label = ">>> 再次点击确认 <<<" end
    btn(max_label, function()
        if S.guard_max and not S.max_armed then
            S.max_armed = true
        else
            S.max_armed = false
            do_rep(REP_MAX, "满级")
        end
    end)
    StormPro.SameLine()
    btn("原表值 998527 (等级 999)", function() do_rep(REP_TABLE, "原表值") end)
    btn(S.guard_max and "满级保护: 开" or "满级保护: 关", function()
        S.guard_max = not S.guard_max
        S.max_armed = false
    end)
    StormPro.Spacing()

    -- [3] 全套解锁 (packed bool)
    StormPro.Separator()
    StormPro.TextColored("[3] 全套解锁 (官方 Stats.set_packed_bool)", 0.4, 0.85, 1.0, 1.0)
    if Stats and type(Stats.set_packed_bool) == "function" then
        StormPro.TextDisabled("接口就绪: 纯高层函数, 无出参、无内存操作")
    else
        StormPro.TextColored("未检测到 Stats.set_packed_bool, 本节不可用", 1.0, 0.4, 0.4, 1.0)
    end

    if #S.queue > 0 then
        StormPro.TextColored(string.format("进行中: %d / %d  (成功 %d, 失败 %d)",
            S.queue_done, S.queue_total, S.packed_ok, S.packed_err), 0.45, 1.0, 0.45, 1.0)
        btn("中止队列", function()
            S.queue = {}
            S.last_log = "已中止解锁队列"
        end)
    else
        btn("① 先测试 3 条 (帽子/鞋/赛车服)", function() start_unlock(TEST3, "测试3条") end)
        btn("② 解锁 15 台改装车", function() start_unlock(CARS, "15台车") end)
        StormPro.SameLine()
        btn("③ 6 项权限 + 赛车服", function() start_unlock(PERKS, "权限+赛车服") end)
        btn("④ 服装 / 涂装 / 轮毂", function() start_unlock(rest_indices(), "服装涂装轮毂") end)
        StormPro.SameLine()
        btn("⑤ 全部 244 条", function() start_unlock(all_indices(), "全部") end)
    end
    slider_int("每帧写入条数", "per_frame", 1, 50)
    StormPro.TextDisabled("  建议先点①测试: 去衣柜看有没有 Emperor 前进帽 / 米色针织运动鞋")
    StormPro.TextDisabled("  测试通过再点②③④⑤, 队列分帧写入, 不会卡菜单")
    StormPro.TextDisabled(string.format("  数据来源: 车友会.txt (244 条, 44 个区间) · 本次成功 %d / 失败 %d",
        S.packed_ok, S.packed_err))
    StormPro.Spacing()

    -- 备份 / 恢复
    StormPro.Separator()
    if S.backup_rep ~= nil then
        StormPro.Text(string.format("已备份原声望: %s (等级 %s)", num(S.backup_rep), tostring(level_for_rep(S.backup_rep))))
        StormPro.TextDisabled("  " .. S.backup_tag)
        btn("恢复原声望", function()
            local b = S.backup_rep
            local okc = apply_int(REP_BASE, b)
            S.cur_rep = b
            S.last_log = string.format("已恢复原声望 %s · 成功 %d 次", num(b), okc)
        end)
    else
        StormPro.TextDisabled("尚未备份原声望 (首次写入前会自动备份)")
    end
    StormPro.Spacing()

    -- [4] 写入范围
    StormPro.Separator()
    StormPro.TextColored("[4] 写入范围 (影响奖品载具/声望)", 0.4, 0.85, 1.0, 1.0)
    local mode_name = "自动(当前角色)"
    if S.slot_mode == "mp0" then mode_name = "仅角色1 (MP0)"
    elseif S.slot_mode == "mp1" then mode_name = "仅角色2 (MP1)"
    elseif S.slot_mode == "both" then mode_name = "两个角色 (MP0+MP1)" end
    StormPro.Text("当前: " .. mode_name)
    if S.slot_mode == "auto" then
        if S.detected == nil then
            StormPro.TextDisabled("  未检测到当前角色 -> 按双角色兜底")
        else
            StormPro.TextDisabled(string.format("  检测到当前为角色%d (MP%d, 来自 Stats.GetMPCharacterIndex)", S.detected + 1, S.detected))
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

    StormPro.Separator()
    StormPro.TextDisabled("最近: " .. S.last_log)
    StormPro.Spacing()
    StormPro.TextDisabled("【生效】写入 -> 切一次战局 -> 回来看结果")
    StormPro.TextDisabled("【安全】只用官方 Stats 高层接口 + 输入型 native, 无出参指针")
end
