-- 在隔离的 Lua 环境中模拟游戏接口，验证重写后的行为边界。
local function near(a, b, eps, message)
    assert(math.abs(a - b) <= eps, (message or "数值不符") .. ": " .. a .. " / " .. b)
end
local function harness()
    local w = {time = 0, ads = true, hit = 11, yaw = 0, pitch = 0, heading = 0,
        fires = 0, turns = 0, allocs = 0, frees = 0, searches = 0, enums = 0, calls = 0,
        memory = {}, entities = {}, slots = {[1] = 11}, npcs = {11}}
    w.entities[1] = {x = 100, y = 100, z = 10, ped = true}
    w.entities[11] = {x = 100 - math.sin(math.rad(20)) * 30, y = 100 + math.cos(math.rad(20)) * 30, z = 10, ped = true}
    w.entities[12] = {x = 100, y = 130, z = 10, ped = true}
    w.entities[20] = {x = 100, y = 125, z = 10, ped = false}
    local env = setmetatable({}, {__index = _G})
    local function native(fn)
        return function(...) w.calls = w.calls + 1; return fn(...) end
    end
    env.PLAYER = {
        PLAYER_PED_ID = native(function() return 1 end),
        PLAYER_ID = native(function() return 0 end),
        IS_PLAYER_FREE_AIMING = native(function() return w.ads end),
        GET_PLAYER_PED = native(function(slot) w.searches = w.searches + 1; return w.slots[slot] or 0 end),
        GET_ENTITY_PLAYER_IS_FREE_AIMING_AT = native(function(_, ptr)
            if w.hit then w.memory[ptr] = w.hit end
            return false -- 已知运行时可能返回 false，同时仍写入有效句柄。
        end),
    }
    env.Ped = {
        GetPosition = native(function() return 100, 100, 10 end),
        GetHeading = native(function() return w.heading end),
    }
    env.PAD = {
        IS_CONTROL_PRESSED = native(function() return w.ads end),
        SET_CONTROL_VALUE_NEXT_FRAME = native(function(_, action, value)
            assert(action == 24 and value == 1); w.fires = w.fires + 1; return true
        end),
    }
    env.MISC = {GET_GAME_TIMER = native(function() return w.time end)}
    env.Entity = {
        HandleToPtr = native(function(ent) return w.entities[ent] and not w.entities[ent].invalid and ent * 16 or 0 end),
        get_all_peds = native(function() w.enums = w.enums + 1; return w.npcs end),
    }
    env.ENTITY = {
        GET_ENTITY_COORDS = native(function(ent)
            local e = assert(w.entities[ent], "失效句柄被解引用")
            assert(not e.invalid, "失效句柄被解引用")
            return {x = e.x, y = e.y, z = e.z}
        end),
        IS_ENTITY_A_PED = native(function(ent) return w.entities[ent].ped end),
        HAS_ENTITY_CLEAR_LOS_TO_ENTITY = native(function() return true end),
    }
    env.PED = {
        IS_PED_DEAD_OR_DYING = native(function(ent) return w.entities[ent].dead or false end),
        GET_VEHICLE_PED_IS_IN = native(function() return 0 end),
        GET_PED_BONE_COORDS = native(function(ent)
            local e = assert(w.entities[ent]); assert(not e.invalid)
            return {x = e.x, y = e.y, z = e.z + 0.7}
        end),
    }
    env.CAM = {
        GET_GAMEPLAY_CAM_COORD = native(function() return {x = 0, y = 0, z = 0} end),
        GET_GAMEPLAY_CAM_ROT = native(function() return {x = w.pitch, y = 0, z = w.yaw} end),
        SET_GAMEPLAY_CAM_RELATIVE_HEADING = native(function(h) w.yaw = w.heading + h; w.turns = w.turns + 1 end),
        SET_GAMEPLAY_CAM_RELATIVE_PITCH = native(function(p) w.pitch = p end),
    }
    env.memory = {
        allocate = native(function() w.allocs = w.allocs + 1; return 4096 end),
        free = native(function(ptr) assert(ptr == 4096); w.frees = w.frees + 1 end),
        get_int = native(function(ptr) return w.memory[ptr] or 0 end),
        set_int = native(function(ptr, value) w.memory[ptr] = value end),
    }
    env.StormPro = {
        RegisterMenu = function() end, Text = function() end, TextDisabled = function() end,
        TextColored = function() end, SameLine = function() end,
        Checkbox = function(_, value) return value end,
        SliderInt = function(_, value) return value end,
        Combo = function(_, value) return value end,
        Button = function() return false end, CollapsingHeader = function() return true end,
    }
    assert(loadfile("扳机自瞄.lua", "t", env))()
    env.on_init()
    local config, state
    for i = 1, 30 do
        local name, value = debug.getupvalue(env.on_menu_render, i)
        if not name then break end
        if name == "C" then config = value end
        if name == "R" then state = value end
    end
    assert(config and state)
    local function step(ms)
        w.time = w.time + (ms or 16)
        env.on_tick()
        assert(state.error == "", state.error)
    end
    return w, config, state, env, step
end

local count = 0
local function test(name, fn)
    fn(); count = count + 1; print("PASS " .. name)
end
test("关闭功能和菜单渲染不调用游戏接口", function()
    local w, _, _, env, step = harness()
    step(); env.on_menu_render()
    assert(w.calls == 0 and w.allocs == 0)
end)
test("即时扳机首帧触发且不扫描、不调整相机", function()
    local w, c, _, _, step = harness(); c.trigger = true
    step(); assert(w.fires == 1 and w.searches == 0 and w.turns == 0)
    for _ = 1, 120 do step(8) end
    assert(w.fires == 121 and w.allocs == 1)
end)
test("准星移开立即停止，出参清零防止旧目标残留", function()
    local w, c, _, _, step = harness(); c.trigger = true
    step(); w.hit = nil; step(); step()
    assert(w.fires == 1)
end)
test("相机接口失效不阻断独立扳机", function()
    local w, c, state, env, step = harness(); c.aim = true; c.trigger = true
    env.CAM.GET_GAMEPLAY_CAM_ROT = function() return nil end
    step(); assert(w.fires == 1 and state.aim_status == "视角数据不可用")
    c.aim = false; step(); assert(w.fires == 2)
end)
test("松开瞄准键不触发，重新按下立即触发", function()
    local w, c, _, _, step = harness(); c.trigger = true
    w.ads = false; step(); assert(w.fires == 0)
    w.ads = true; step(); assert(w.fires == 1)
end)
test("车辆、濒死角色、失效句柄与超距目标不触发", function()
    local w, c, _, _, step = harness(); c.trigger = true
    w.hit = 20; step(); w.hit = 11; w.entities[11].dead = true; step()
    w.entities[11].dead = false; w.entities[11].invalid = true; step()
    w.entities[11].invalid = false; w.entities[11].y = 500; step()
    assert(w.fires == 0)
end)
test("目标切换重新计时，延迟从新目标开始", function()
    local w, c, _, _, step = harness(); c.trigger = true; c.trigger_delay = 80
    step(10); step(70); assert(w.fires == 0)
    w.hit = 12; step(10); step(70); assert(w.fires == 0)
    step(10); assert(w.fires == 1)
end)
test("关闭补充检测时，分批搜索持续跟踪且不代替直接命中", function()
    local w, c, state, _, step = harness(); c.aim = true; c.trigger = true; c.trigger_assist = false; w.hit = nil
    for _ = 1, 120 do
        local previous = w.searches
        step(8)
        assert(w.searches - previous <= 4, "单帧遍历了过多玩家槽")
        assert(state.aim_ent == 11, "搜索间隔内丢失目标")
    end
    assert(w.turns == 120 and w.fires == 0)
end)
test("30与120 FPS按相同时间平滑", function()
    local function simulate(fps)
        local w, c, _, _, step = harness(); c.aim = true
        step(0)
        for _ = 1, fps / 5 do step(1000 / fps) end
        return w.yaw
    end
    near(simulate(30), simulate(120), 0.02, "帧率改变跟随速度")
end)
test("鼠标改变相机与角色转身后按实际视角计算", function()
    local w, c, _, _, step = harness(); c.aim = true
    step(); step(); w.yaw = -35; step()
    assert(math.abs(w.yaw + 35) <= c.max_speed * 0.016 + 0.01)
    local before = w.yaw; w.heading = 90; step()
    assert(math.abs(w.yaw - before) <= c.max_speed * 0.016 + 0.01)
end)
test("跨越正负180度走最短方向", function()
    local w, c, _, _, step = harness(); c.aim = true; w.yaw = -179
    w.entities[11].x = 100 - math.sin(math.rad(179)) * 30
    w.entities[11].y = 100 + math.cos(math.rad(179)) * 30
    step()
    local change = (w.yaw + 179 + 180) % 360 - 180
    assert(change < 0 and math.abs(change) < 2)
end)
test("观察模式没有相机和开火副作用", function()
    local w, c, _, _, step = harness(); c.aim = true; c.trigger = true; c.observe = true
    for _ = 1, 30 do step() end
    assert(w.fires == 0 and w.turns == 0)
end)
test("目标失效立即释放跟踪", function()
    local w, c, state, _, step = harness(); c.aim = true
    step(); assert(state.aim_ent == 11)
    w.entities[11].invalid = true; local turns = w.turns; step()
    assert(state.aim_ent == nil and w.turns == turns)
end)
test("游戏时间回绕不锁死搜索或扳机", function()
    local w, c, _, _, step = harness(); c.aim = true; c.trigger = true
    w.time = 2147483640; step(1)
    w.time = -2147483648; step(1)
    assert(w.fires == 2)
end)
test("NPC 枚举节流且上限生效", function()
    local w, c, state, _, step = harness(); c.aim = true; c.npcs = true; c.npc_cap = 4; w.hit = nil
    for i = 1, 100 do w.npcs[i] = 11 end
    for _ = 1, 120 do step(8) end
    assert(w.enums == 1 and #state.npc_list == 4)
end)
test("卸载释放复用缓冲，重复卸载不重复释放", function()
    local w, c, _, env, step = harness(); c.trigger = true
    step(); env.on_stop(); env.on_stop(); step()
    assert(w.allocs == 1 and w.frees == 1 and w.fires == 1)
end)
test("菜单渲染期间不读取或修改游戏状态", function()
    local w, c, _, env, step = harness(); c.aim = true; c.trigger = true
    step(); local calls = w.calls
    for _ = 1, 100 do env.on_menu_render() end
    assert(w.calls == calls)
end)
test("角色类型恒false仍能通过角色枚举确认并触发", function()
    local w, c, state, env, step = harness(); c.trigger = true
    env.ENTITY.IS_ENTITY_A_PED = function() return false end
    step(); assert(w.fires == 1 and state.trigger_source == "自由瞄准")
    for _ = 1, 60 do step(8) end
    assert(w.enums == 1 and w.fires == 61, "角色类型兼容检测未节流")
end)
test("角色类型接口缺失仍能通过枚举确认", function()
    local w, c, _, env, step = harness(); c.trigger = true
    env.ENTITY.IS_ENTITY_A_PED = nil
    step(); assert(w.fires == 1)
end)
test("类型检查失真时不会把载具放行为角色", function()
    local w, c, _, env, step = harness(); c.trigger = true; w.hit = 20
    env.ENTITY.IS_ENTITY_A_PED = function() return false end
    step(); assert(w.fires == 0)
end)
test("自由瞄准恒空时，自瞄真正对齐后才能触发", function()
    local w, c, state, _, step = harness(); c.aim = true; c.trigger = true; w.hit = nil
    step(); assert(w.fires == 0 and state.aim_ent == 11)
    for _ = 1, 60 do step(8) end
    assert(w.fires > 0 and state.trigger_source == "自瞄骨骼对齐")
    local fired = w.fires
    w.yaw = -40; step(); assert(w.fires == fired, "使用了上一帧的对齐结果")
end)
test("仅扫描到附近目标不能立即触发补充检测", function()
    local w, c, _, _, step = harness(); c.aim = true; c.trigger = true; w.hit = nil
    c.response_ms = 250; c.max_speed = 90
    for _ = 1, 5 do step(8) end
    assert(w.fires == 0)
end)
test("实际命中载具时，不用旧跟踪目标覆盖直接命中结果", function()
    local w, c, _, _, step = harness(); c.aim = true; c.trigger = true; w.hit = nil
    for _ = 1, 60 do step(8) end
    assert(w.fires > 0)
    local fired = w.fires; w.hit = 20; step(); assert(w.fires == fired)
end)
test("补充检测尊重视线过滤且禁止使用兼容输出角", function()
    local w, c, _, env, step = harness(); c.aim = true; c.trigger = true; w.hit = nil
    for _ = 1, 60 do step(8) end
    local fired = w.fires
    c.los = true; env.ENTITY.HAS_ENTITY_CLEAR_LOS_TO_ENTITY = function() return false end
    step(); assert(w.fires == fired)
    c.los = false; c.camera_source = 1
    for _ = 1, 60 do step(8) end
    assert(w.fires == fired)
end)
print(string.format("%d tests passed", count))
