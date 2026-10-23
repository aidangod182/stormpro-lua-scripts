-- 隔离模拟：验证回调边界、筛选、投影出参和资源生命周期。
local function harness(path)
    local w = {time = 0, allocs = 0, frees = 0, draws = 0, labels = {}, scans = 0,
        mem = {}, settings = {}, phase = "tick", queries = 0, project_calls = 0,
        slot_reads = 0, health_reads = 0, bone_reads = 0, per_frame = {}, own = 1,
        slots = {[0] = 1, [1] = 2}, npcs = {1, 2, 3, 3}, rectangles = {}, project_scale = 1}
    w.entities = {
        [1] = {x = 0, y = 0, z = 10},
        [2] = {x = 0, y = 10, z = 10},
        [3] = {x = 0, y = 20, z = 10},
    }
    local env = setmetatable({}, {__index = _G})
    local function native(fn)
        return function(...)
            assert(w.phase ~= "menu" and w.phase ~= "init", "菜单/初始化调用游戏接口")
            w.queries = w.queries + 1
            return fn(...)
        end
    end
    local function entity(ped)
        local e = assert(w.entities[ped], "不存在的实体被查询")
        assert(not e.invalid, "失效实体被查询")
        return e
    end
    env.StormPro = {
        RegisterMenu = function(name) w.menu_name = name end,
        Checkbox = function(label, old)
            local v = w.settings[label]
            if v == nil then return old, false end
            return v, v ~= old
        end,
        SliderInt = function(label, old) return w.settings[label] or old end,
        SliderFloat = function(label, old) return w.settings[label] or old end,
        TextColored = function() end, Separator = function() end,
        Text = function(value) w.last_text = value end,
    }
    env.PLAYER = {
        PLAYER_PED_ID = native(function() return w.own end),
        GET_PLAYER_PED = native(function(slot) w.slot_reads = w.slot_reads + 1; return w.slots[slot] or 0 end),
        GET_PLAYER_NAME = native(function() return "~r~Alice\n" end),
    }
    env.Entity = {
        HandleToPtr = native(function(ped)
            return w.entities[ped] and not w.entities[ped].invalid and ped * 16 or 0
        end),
        GetAllEntityHandle = native(function()
            w.scans = w.scans + 1; return w.npcs
        end),
    }
    env.ENTITY = {
        GET_ENTITY_COORDS = native(function(ped) return entity(ped) end),
        GET_ENTITY_HEALTH = native(function(ped) w.health_reads = w.health_reads + 1; return entity(ped).hp or 150 end),
        GET_ENTITY_MAX_HEALTH = native(function() return 200 end),
    }
    env.PED = {
        IS_PED_A_PLAYER = native(function(ped) for _, p in pairs(w.slots) do if p == ped then return true end end; return false end),
        IS_PED_DEAD_OR_DYING = native(function(ped) return entity(ped).dead or false end),
        GET_PED_BONE_COORDS = native(function(ped)
            w.bone_reads = w.bone_reads + 1; local e = entity(ped); return {x = e.x, y = e.y, z = e.z + 0.9}
        end),
    }
    env.MISC = {GET_GAME_TIMER = native(function() return w.time end)}
    env.GRAPHICS = {
        GET_ASPECT_RATIO = native(function() return 16 / 9 end),
        GET_SCREEN_COORD_FROM_WORLD_COORD = native(function(x, y, z, px, py)
            w.project_calls = w.project_calls + 1
            if w.projection_error then error("projection failed") end
            if w.on_project then w.on_project() end
            if not w.no_write then
                w.mem[px], w.mem[py] = 0.5 + x / 100 * w.project_scale, 0.5 - (z - 10) / 10 * w.project_scale
            end
            return not w.projection_false
        end),
        DRAW_RECT = native(function(x, y, width, height)
            assert(x == x and y == y and width > 0 and height > 0)
            w.draws = w.draws + 1
            w.rectangles[#w.rectangles + 1] = {x = x, y = y, width = width, height = height}
        end),
    }
    env.HUD = {}
    for _, name in ipairs({"SET_TEXT_FONT", "SET_TEXT_SCALE", "SET_TEXT_COLOUR", "SET_TEXT_CENTRE",
        "SET_TEXT_RIGHT_JUSTIFY", "SET_TEXT_WRAP", "SET_TEXT_OUTLINE", "BEGIN_TEXT_COMMAND_DISPLAY_TEXT", "END_TEXT_COMMAND_DISPLAY_TEXT"}) do
        env.HUD[name] = native(function() end)
    end
    env.HUD.ADD_TEXT_COMPONENT_SUBSTRING_PLAYER_NAME = native(function(label) w.labels[#w.labels + 1] = label end)
    env.memory = {
        allocate = native(function(size) assert(size == 8 or size == 32); w.alloc_size = size; w.allocs = w.allocs + 1; return 4096 end),
        free = native(function(ptr) assert(ptr == 4096); w.frees = w.frees + 1 end),
        set_float = native(function(ptr, value) w.mem[ptr] = value end),
        get_float = native(function(ptr) return w.mem[ptr] end),
    }
    env.Utils = {Log = function(msg) w.error = msg end}
    assert(loadfile(path or "ESP透视.lua", "t", env))()
    function w:menu(settings)
        self.settings, self.phase = settings or {}, "menu"
        env.on_menu_render(); self.phase = "tick"
    end
    function w:tick()
        self.draws, self.labels, self.project_calls, self.slot_reads = 0, {}, 0, 0
        self.rectangles = {}
        local before = self.queries
        env.on_tick()
        self.frame_calls = self.queries - before
        self.per_frame[#self.per_frame + 1] = self.frame_calls
    end
    w.phase = "init"; env.on_init(); w.phase = "tick"
    assert(w.menu_name == "ESP透视")
    return w, env
end
local passed = 0
local function test(name, fn) fn(); passed = passed + 1; print("PASS " .. name) end
local function advance(w, until_time, step)
    step = step or 16
    while w.time < until_time do w.time = math.min(until_time, w.time + step); w:tick() end
end
local function enable(w, options)
    options = options or {}; options["启用 ESP"] = true; w:menu(options); w:tick()
end
test("disabled/menu/init do not query game", function()
    local w = harness(); w:menu(); w:tick(); assert(w.queries == 0)
end)
test("default draws four lines; cached frame uses no projection", function()
    local w = harness(); enable(w)
    assert(w.draws == 4 and #w.labels == 0 and w.project_calls == 2)
    w.time = 16; w:tick()
    assert(w.draws == 4 and w.project_calls == 0 and w.frame_calls == 5)
    assert(w.health_reads == 0 and w.bone_reads == 0 and w.allocs == 1 and w.alloc_size == 32)
end)
test("labels and health remain optional and refresh stats slowly", function()
    local w = harness(); enable(w, {["名字 / NPC 标签"] = true, ["距离"] = true, ["血条（原生生命值比例）"] = true})
    assert(w.draws == 6 and #w.labels == 1 and not w.labels[1]:find("~") and not w.labels[1]:find("\n"))
    advance(w, 240); assert(w.health_reads == 1)
    advance(w, 320); assert(w.health_reads == 2)
end)
test("NPC excludes players and duplicate handles", function()
    local w = harness(); enable(w, {["显示玩家"] = false, ["显示 NPC"] = true, ["名字 / NPC 标签"] = true})
    advance(w, 160)
    assert(w.draws == 4 and #w.labels == 1 and w.labels[1]:find("NPC"))
end)
test("dead and distant entities never project", function()
    local w = harness(); w.entities[2].dead = true; enable(w); assert(w.project_calls == 0)
    local other = harness(); other.entities[2].y = 300; enable(other); assert(other.project_calls == 0)
end)
test("stale handles are checked before resampling", function()
    local w = harness(); enable(w); w.entities[2].invalid = true
    advance(w, 64); assert(w.draws == 0 and not w.error)
end)
test("transient missing output preserves cached box up to 100ms", function()
    local w = harness(); enable(w); w.no_write = true
    advance(w, 64); assert(w.draws == 4)
    advance(w, 128); assert(w.draws == 0)
    w.no_write = false; advance(w, 192); assert(w.draws == 4)
end)
test("explicit projection false removes box at next sample", function()
    local w = harness(); enable(w); w.projection_false = true
    advance(w, 64); assert(w.draws == 0)
end)
test("partly visible box is clipped instead of discarded", function()
    local w = harness(); w.entities[2].z = 15; enable(w)
    assert(w.draws > 0 and w.draws < 4)
end)
test("fully offscreen targets produce no rectangles", function()
    local w = harness(); w.entities[2].x = 100; enable(w); assert(w.draws == 0)
end)
test("disable clears overlay with no native calls", function()
    local w = harness(); enable(w); w:menu({["启用 ESP"] = false})
    w:tick(); assert(w.draws == 0 and w.frame_calls == 0)
end)
test("timer wrap and pause clear stale data and restart scans", function()
    local w = harness(); enable(w); w.time = -2147483648; w:tick()
    assert(w.draws == 4 and w.slot_reads == 2 and not w.error)
    w.time = w.time + 2000; w:tick(); assert(w.draws == 4 and not w.error)
end)
test("local ped loss and respawn discard old cache", function()
    local w = harness(); enable(w); w.entities[1].invalid = true; advance(w, 64)
    assert(w.draws == 0 and not w.error)
    w.entities[4] = {x = 0, y = 2000, z = 10}; w.own = 4; advance(w, 128)
    assert(w.draws == 0 and not w.error)
end)
test("native Lua error disables and retry works", function()
    local w = harness(); w.projection_error = true; enable(w)
    assert(w.error and w.error:find("projection failed"))
    w:menu(); w:tick(); assert(w.draws == 0)
    w.projection_error = false; enable(w); assert(w.draws == 4)
end)
test("recursive tick does not reuse output buffer", function()
    local w, env = harness()
    w.on_project = function() env.on_tick() end
    enable(w); assert(w.project_calls == 2 and w.draws == 4 and not w.error)
end)
test("stop frees once and blocks late tick", function()
    local w, env = harness(); enable(w); env.on_stop(); env.on_stop()
    w:tick(); assert(w.allocs == 1 and w.frees == 1 and w.frame_calls == 0)
end)
test("stop during native defers free until tick exits", function()
    local w, env = harness()
    w.on_project = function()
        env.on_stop()
        assert(w.frees == 0, "buffer freed while projection is in progress")
    end
    enable(w)
    assert(w.frees == 1 and w.draws == 0 and not w.error)
    w:tick(); assert(w.frame_calls == 0)
end)
test("movement interpolates during frames with no fresh projection", function()
    local w = harness(); enable(w); w.entities[2].x = 10
    advance(w, 50)
    local first = w.rectangles[1].x
    assert(first > 0.5 and first < 0.6, "new sample snapped directly to target")
    w.time = 66; w:tick()
    assert(w.project_calls == 0 and w.rectangles[1].x > first and w.rectangles[1].x < 0.6)
    assert(w.frame_calls == 5, "smoothing introduced game API calls")
end)
test("smoothed position converges monotonically without overshoot", function()
    local w = harness(); enable(w); w.entities[2].x = 10
    local previous = 0.5
    for frame = 1, 30 do
        w.time = frame * 16; w:tick()
        local x = w.rectangles[1].x
        assert(x >= previous and x <= 0.6 + 1e-12)
        previous = x
    end
    assert(math.abs(previous - 0.6) < 0.0001)
end)
test("box width and height interpolate along with position", function()
    local w = harness(); enable(w)
    local old_width, old_height = w.rectangles[1].width, w.rectangles[3].height
    w.project_scale = 1.5; advance(w, 50)
    assert(w.rectangles[1].width > old_width and w.rectangles[1].width < old_width * 1.5)
    assert(w.rectangles[3].height > old_height and w.rectangles[3].height < old_height * 1.5)
    local mid_height = w.rectangles[3].height
    w.time = 66; w:tick(); assert(w.project_calls == 0 and w.rectangles[3].height > mid_height)
end)
test("constant target smoothing is independent of render frame rate", function()
    local function response(step)
        local w = harness(); enable(w); w.entities[2].x = 10
        w.time = 50; w:tick(); advance(w, 250, step)
        return w.rectangles[1].x
    end
    assert(math.abs(response(10) - response(20)) < 1e-10)
    assert(math.abs(response(20) - response(50)) < 1e-10)
end)
test("zero smoothing uses raw position immediately", function()
    local w = harness(); enable(w, {["平滑响应（毫秒）"] = 0})
    w.entities[2].x = 10; w.time = 50; w:tick()
    assert(math.abs(w.rectangles[1].x - 0.6) < 1e-12)
end)
test("large camera jump snaps instead of dragging a box across screen", function()
    local w = harness(); enable(w); w.entities[2].x = 40; w.time = 50; w:tick()
    assert(math.abs(w.rectangles[1].x - 0.9) < 1e-12)
end)
test("reappearing target resets old rendered position", function()
    local w = harness(); enable(w); w.projection_false = true; advance(w, 64)
    assert(w.draws == 0)
    w.projection_false = false; w.entities[2].x = 10; advance(w, 128)
    assert(math.abs(w.rectangles[1].x - 0.6) < 1e-12)
end)
test("smoothing setting changes do not clear target cache", function()
    local w = harness(); enable(w); w.time = 16; w:tick()
    w:menu({["平滑响应（毫秒）"] = 80})
    w.time = 32; w:tick(); assert(w.draws == 4 and w.project_calls == 0)
end)
local function crowd(w)
    w.npcs = {}
    for slot = 1, 31 do
        local ped = slot + 1
        w.slots[slot] = ped
        w.entities[ped] = {x = slot / 10, y = 10 + slot, z = 10}
    end
    for n = 1, 96 do
        local ped = 100 + n
        w.entities[ped] = {x = n / 20, y = 15 + n, z = 10}
        w.npcs[#w.npcs + 1] = ped
    end
end
test("crowded scene bounds scans/projections/draws and redraws continuously", function()
    local w = harness(); crowd(w); enable(w, {["显示 NPC"] = true})
    for frame = 1, 360 do
        w.time = frame * 16; w:tick()
        assert(not w.error, w.error)
        assert(w.slot_reads <= 2 and w.project_calls <= 8 and w.draws <= 48)
        if frame > 100 then assert(w.draws == 48, "cached overlay flickered at frame " .. frame) end
    end
    assert(w.scans <= 3 and w.bone_reads == 0 and w.health_reads == 0)
end)
test("all features obey draw cap and projection budget", function()
    local w = harness(); crowd(w)
    enable(w, {["显示 NPC"] = true, ["名字 / NPC 标签"] = true, ["距离"] = true, ["血条（原生生命值比例）"] = true})
    for frame = 1, 180 do
        w.time = frame * 16; w:tick()
        assert(not w.error and w.project_calls <= 8 and w.draws <= 72 and #w.labels <= 12)
    end
end)
local function benchmark(path, extras)
    local w = harness(path); crowd(w); enable(w, extras)
    local sum, peak = 0, 0
    for frame = 1, 360 do
        w.time = frame * 16; w:tick(); assert(not w.error, w.error)
        if frame > 120 then sum = sum + w.frame_calls; peak = math.max(peak, w.frame_calls) end
    end
    return sum / 240, peak
end
local old_path = "backups/ESP透视-v1.0-20261017-122339.lua.bak"
local new_mean, new_peak = benchmark(nil, {["显示 NPC"] = true})
local equal_options = {["显示 NPC"] = true, ["最大显示数量"] = 12, ["最大距离（米）"] = 150,
    ["名字 / NPC 标签"] = true, ["距离"] = true, ["血条（原生生命值比例）"] = true}
local equal_new, equal_new_peak = benchmark(nil, equal_options)
local previous_path = "backups/ESP透视-v1.1-20261017-130403.lua.bak"
-- 公开仓库不包含本地旧版备份；当前版本的调用预算仍始终验证。
assert(new_mean < 150 and equal_new < 300, "current API call budget exceeded")
print(string.format("CURRENT API calls/frame: default %.1f peak %d; all options %.1f peak %d",
    new_mean, new_peak, equal_new, equal_new_peak))
if loadfile(old_path, "t") then
    local old_mean, old_peak = benchmark(old_path, {["显示 NPC"] = true})
    local equal_old, equal_old_peak = benchmark(old_path, equal_options)
    print(string.format("DEFAULT crowd API calls/frame: v1.0 %.1f peak %d -> v1.2 %.1f peak %d", old_mean, old_peak, new_mean, new_peak))
    print(string.format("SAME SETTINGS API calls/frame: v1.0 %.1f peak %d -> v1.2 %.1f peak %d", equal_old, equal_old_peak, equal_new, equal_new_peak))
    assert(new_mean < old_mean * 0.3 and equal_new < equal_old * 0.5)
else
    print("SKIP optional v1.0 comparison: local backup unavailable")
end
if loadfile(previous_path, "t") then
    local previous_mean, previous_peak = benchmark(previous_path, equal_options)
    assert(previous_mean == equal_new and previous_peak == equal_new_peak, "smoothing increased game API calls")
    print(string.format("v1.1 -> v1.2 API calls unchanged: %.1f average / %d peak", previous_mean, previous_peak))
else
    print("SKIP optional v1.1 comparison: local backup unavailable")
end
print(string.format("ESP: %d tests passed", passed))
