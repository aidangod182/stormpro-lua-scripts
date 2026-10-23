local DATA = {
    {"CLUB_SAFE_CASH_VALUE", 2708943}, {"ARCADE_SAFE_CASH_VALUE", 2708952},
    {"FIXER_SAFE_CASH_VALUE", 2708961}, {"SALVAGE_SAFE_CASH_VALUE", 2708970},
    {"BAIL_SAFE_CASH_VALUE", 2708979}, {"HDEN24_SAFE_CASH_VALUE", 2708994}, {"CWASH_SAFE_CASH_VALUE", 2709001},
}
local function harness()
    local w = {now = 0, slot = 0, thread = 1024, online = true, active = true, calls = 0,
        stats = {}, flags = {}, writes = {}, wallet = 1000, bank = 2000, logs = {}, ui = {}, phase = "tick"}
    for i, row in ipairs(DATA) do
        w.stats["MP0_" .. row[1]], w.stats["MP1_" .. row[1]] = i * 100, i * 200
    end
    local function api(fn)
        return function(...)
            assert(w.phase == "tick", "game call from UI or initialization")
            w.calls = w.calls + 1
            return fn(...)
        end
    end
    local env = setmetatable({}, {__index = _G})
    env.StormPro = {
        RegisterMenu = function(v) w.menu = v end,
        Text = function(v) w.ui[#w.ui + 1] = v end,
        TextColored = function() end, SameLine = function() end, Separator = function() end,
        Checkbox = function(label, old)
            if w.selection and w.selection[label] ~= nil then return w.selection[label], true end
            return old, false
        end,
        Button = function(label) return label == w.button end,
    }
    env.NETWORK = {NETWORK_IS_SESSION_STARTED = api(function() return w.online end)}
    env.script = api(function(name)
        assert(name == "freemode")
        return {is_active = function() return w.active end, get_script_thread = function() return w.thread end}
    end)
    env.Stats = {
        GetMPCharacterIndex = api(function() return w.slot end),
        get_int = api(function(name)
            if w.bad_stats then return nil end
            if name == "MPPLY_LAST_MP_CHAR" then return w.fallback_slot end
            assert(w.stats[name] ~= nil, "unknown stat " .. name)
            return w.stats[name]
        end),
        set_int = function() error("must not write money stats") end,
    }
    env.globals = {
        get_int = api(function(index) return w.flags[index] or 0 end),
        set_bool = api(function(index, value)
            assert(value == true or value == false)
            local found = false
            for _, row in ipairs(DATA) do if index == row[2] then found = true end end
            assert(found, "write outside known request flags")
            if w.write_error then error("write failed") end
            w.writes[#w.writes + 1] = {index = index, value = value, at = w.now}
            w.flags[index] = value and 1 or 0
            if w.on_write then w.on_write() end
        end),
    }
    env.MISC = {GET_GAME_TIMER = api(function() return w.now end)}
    env.MONEY = {
        NETWORK_GET_VC_WALLET_BALANCE = api(function(slot) assert(slot == w.slot); if w.no_balance then return nil end; return w.wallet end),
        NETWORK_GET_VC_BANK_BALANCE = api(function() if w.no_balance then return nil end; return w.bank end),
    }
    env.Utils = {Log = function(msg) w.logs[#w.logs + 1] = msg end}
    assert(loadfile("保险箱一键领取.lua", "t", env))()
    w.phase = "init"; env.on_init(); w.phase = "tick"
    assert(w.menu == "保险箱一键领取")
    function w:click(button, selection)
        self.phase, self.button, self.selection, self.ui = "menu", button, selection, {}
        env.on_menu_render()
        self.phase, self.button, self.selection = "tick", nil, nil
    end
    function w:tick(delta) self.now = self.now + (delta or 0); env.on_tick() end
    function w:count_requests()
        local n = 0; for _, v in ipairs(self.writes) do if v.value then n = n + 1 end end; return n
    end
    function w:complete(i, credit)
        local row = DATA[i]; local stat = "MP" .. self.slot .. "_" .. row[1]
        local amount = self.stats[stat]
        self.stats[stat], self.flags[row[2]], self.flags[row[2] + 1] = 0, 0, 0
        if credit ~= false then self.wallet = self.wallet + amount end
    end
    function w:messages()
        self:click(nil); return table.concat(self.ui, "\n")
    end
    return w, env
end
local passed = 0
local function test(name, fn) fn(); passed = passed + 1; print("PASS " .. name) end
local function start(w) w:click("一键领取勾选收益"); w:tick() end
test("idle and menu are free of game calls", function()
    local w = harness(); w:click(nil); for _ = 1, 100 do w:tick(16) end; assert(w.calls == 0)
end)
test("one click requests seven safes serially and confirms balance changes", function()
    local w = harness(); start(w)
    for i = 1, 7 do
        assert(w:count_requests() == i)
        assert(w.writes[#w.writes].index == DATA[i][2])
        w:complete(i); w:tick(250); w:tick(1000)
    end
    assert(w:messages():find("已确认 7 项 / %$2800"))
end)
test("refresh only reads and does not submit requests", function()
    local w = harness(); w:click("刷新全部余额")
    for _ = 1, 10 do w:tick(250) end
    assert(#w.writes == 0 and w:messages():find("余额刷新完成"))
end)
test("zero balance skips every trigger", function()
    local w = harness(); for key in pairs(w.stats) do w.stats[key] = 0 end; start(w)
    for _ = 1, 10 do w:tick(1000) end
    assert(#w.writes == 0 and w:messages():find("跳过 7 项"))
end)
test("repeated clicks do not overlap or resubmit", function()
    local w = harness(); start(w)
    for _ = 1, 10 do w:click("一键领取勾选收益"); w:tick(100) end
    assert(w:count_requests() == 1)
end)
test("offline and missing freemode cannot write", function()
    local w = harness(); w.online = false; start(w); assert(#w.writes == 0)
    w.online, w.active = true, false; start(w); assert(#w.writes == 0)
end)
test("unknown character prevents writes; MP1 uses its own stats", function()
    local w = harness(); w.slot = -1; start(w); assert(#w.writes == 0)
    w.slot = 1; start(w); w:complete(1); w:tick(250)
    assert(w:messages():find("已确认领取 %$200"))
end)
test("invalid stat or request flags halt before submission", function()
    local w = harness(); w.bad_stats = true; start(w); assert(#w.writes == 0)
    local b = harness(); b.flags[DATA[1][2]] = 42; start(b); assert(#b.writes == 0)
end)
test("preexisting game request is never cleared or duplicated", function()
    local w = harness(); w.flags[DATA[1][2]] = 1; start(w)
    assert(#w.writes == 0); w:tick(1000)
    assert(w.writes[1].index == DATA[2][2] and w.flags[DATA[1][2]] == 1)
end)
test("timeout withdraws only unconsumed request and stops batch", function()
    local w = harness(); start(w); w:tick(12000)
    assert(w:count_requests() == 1 and w.writes[2].value == false)
    assert(w:messages():find("领取超时"))
    w:tick(20000); assert(w:count_requests() == 1)
end)
test("safe decrease alone is not reported as credited", function()
    local w = harness(); start(w); w:complete(1, false); w:tick(250)
    assert(not w:messages():find("已确认领取"))
    w:tick(12000); assert(w:messages():find("到账未确认") and w:count_requests() == 1)
end)
test("wallet increase alone is not reported as collection", function()
    local w = harness(); start(w); w.wallet = w.wallet + 100; w:tick(12000)
    assert(w:messages():find("领取超时"))
end)
test("cancel does not clear a consumed request or processing state", function()
    local w = harness(); start(w); w.flags[DATA[1][2]], w.flags[DATA[1][2] + 1] = 0, 1
    w:click("停止后续领取"); w:tick()
    assert(#w.writes == 1 and w.flags[DATA[1][2] + 1] == 1)
end)
test("context change does not write cleanup into new session", function()
    local w = harness(); start(w); w.thread = 2048; w:tick(250)
    assert(#w.writes == 1 and w:messages():find("角色或战局已变化"))
end)
test("timer reset cancels instead of waiting forever", function()
    local w = harness(); start(w); w:tick(-1)
    assert(w:messages():find("计时已重置") and w:count_requests() == 1)
end)
test("native Lua error is reported without further requests", function()
    local w = harness(); w.write_error = true; start(w)
    assert(w:messages():find("write failed") and #w.writes == 0)
end)
test("unload retracts unconsumed request and blocks late tick", function()
    local w, env = harness(); start(w); env.on_stop(); local n = w.calls
    w:tick(250); assert(w.calls == n and #w.writes == 2 and w.writes[2].value == false)
end)
test("reentrant tick does not submit duplicate request", function()
    local w, env = harness(); w.on_write = function() env.on_tick() end
    start(w); assert(w:count_requests() == 1)
end)
test("missing wallet API does not turn safe decrease into success", function()
    local w = harness(); w.no_balance = true; start(w); w:complete(1); w:tick(12000)
    assert(w:messages():find("到账未确认") and w:count_requests() == 1)
end)
test("delayed balance sync confirms once without resubmission", function()
    local w = harness(); start(w); w:complete(1, false); w:tick(250)
    assert(w:count_requests() == 1 and not w:messages():find("已确认领取"))
    w.wallet = w.wallet + 100; w:tick(250)
    assert(w:messages():find("已确认领取 %$100") and w:count_requests() == 1)
end)
test("wallet bank transfer cannot count as income", function()
    local w = harness(); start(w); w:complete(1, false)
    w.wallet, w.bank = w.wallet + 100, w.bank - 100
    w:tick(12000); assert(w:messages():find("到账未确认"))
end)
print(string.format("Safe collection: %d tests passed", passed))
