-- StormPro 扳机 + 自瞄 v2.1
-- 扳机优先自由瞄准命中；可选使用本帧相机与当前自瞄骨骼的对齐检测。
-- 游戏调用只在 on_tick 执行，菜单只修改设置并显示状态。
local C = {
    aim = false, trigger = false, observe = false,
    hold_aim = true, hold_trigger = true,
    players = true, npcs = false, npc_cap = 32,
    distance = 120, fov = 35, release_fov = 55,
    response_ms = 65, max_speed = 720, deadzone = 0.03,
    bone = 31086, lead_ms = 0,
    skip_dead = true, skip_same_vehicle = false, los = false,
    scan_ms = 25, slots_per_batch = 4,
    trigger_delay = 0, trigger_cooldown = 0,
    trigger_assist = true,
    camera_source = 0, pitch_invert = false, type_check = true,
}
local R = {
    frame = 0, now = 0, last_time = nil, dt = 1 / 60,
    ped = 0, pid = nil, aim_ent = nil, hit_ent = nil,
    aim_source = "无", aim_angle = 0, aim_distance = 0,
    aim_status = "关闭", trigger_status = "关闭", error = "",
    candidates = {}, npc_list = {}, npc_cursor = 1, slot = 0,
    next_scan = 0, next_npcs = 0, scan_options = "",
    out_buf = nil, detector = "未检测", type_result = "未检测",
    raw_hit = 0, hit_reason = "未检测", trigger_source = "无",
    known_peds = {}, next_ped_check = 0,
    trigger_ent = nil, trigger_since = nil, last_shot = nil,
    relative_h = nil, relative_p = nil, camera_valid = false,
    cam_coord_supported = false, next_camera_probe = 0,
    calls = 0, peak_calls = 0, fire_frames = 0, candidate_count = 0,
    sample_ent = nil, sample_time = nil, vx = 0, vy = 0, vz = 0,
    reset_requested = false,
}
local function finite(v)
    return type(v) == "number" and v == v and v > -math.huge and v < math.huge
end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function wrap(a) return (a + 180) % 360 - 180 end
local function atan2(y, x)
    if math.atan2 then return math.atan2(y, x) end
    return math.atan(y, x)
end
local function call(api, name, ...)
    if not api or type(api[name]) ~= "function" then return nil end
    R.calls = R.calls + 1
    local ok, a, b, c = pcall(api[name], ...)
    if ok then return a, b, c end
end
local function vec(v)
    if type(v) ~= "table" and type(v) ~= "userdata" then return nil end
    local ok, x, y, z = pcall(function()
        return v.x or v[1], v.y or v[2], v.z or v[3]
    end)
    if ok and finite(x) and finite(y) and finite(z) then return x, y, z end
end
local function nonzero(x, y, z) return x and (x ~= 0 or y ~= 0 or z ~= 0) end
local function valid(ent)
    if not finite(ent) or ent <= 0 or ent == R.ped then return false end
    -- DOES_ENTITY_EXIST 在这个运行时不可靠，使用菜单提供的句柄转换。
    local ptr = call(Entity, "HandleToPtr", ent)
    return finite(ptr) and ptr ~= 0
end
local function coords(ent)
    local x, y, z = vec(call(ENTITY, "GET_ENTITY_COORDS", ent, true))
    if nonzero(x, y, z) then return x, y, z end
end
local function reset_trigger()
    R.trigger_ent, R.trigger_since = nil, nil
end
local function reset_tracking()
    R.aim_ent, R.sample_ent = nil, nil
    R.relative_h, R.relative_p = nil, nil
    R.sample_time, R.vx, R.vy, R.vz = nil, 0, 0, 0
end
local function clear_candidates()
    R.candidates, R.npc_list = {}, {}
    R.slot, R.npc_cursor, R.candidate_count = 0, 1, 0
    R.next_scan, R.next_npcs = 0, 0
    R.known_peds, R.next_ped_check = {}, 0
end
local function filter(ent)
    if not valid(ent) then return false end
    if C.skip_dead and call(PED, "IS_PED_DEAD_OR_DYING", ent, true) == true then return false end
    if C.skip_same_vehicle then
        local own = call(PED, "GET_VEHICLE_PED_IS_IN", R.ped, false)
        if finite(own) and own ~= 0 and call(PED, "GET_VEHICLE_PED_IS_IN", ent, false) == own then return false end
    end
    if C.los and call(ENTITY, "HAS_ENTITY_CLEAR_LOS_TO_ENTITY", R.ped, ent, 17) ~= true then return false end
    return true
end
local function refresh_view(need_direction)
    R.direction_ok = false
    local x, y, z = call(Ped, "GetPosition")
    if not (finite(x) and finite(y) and finite(z)) then x, y, z = coords(R.ped) end
    if not x then return false end
    R.ox, R.oy, R.oz = x, y, z + 0.7
    -- 仅开扳机时不读相机、不计算方向，命中检测不依赖相机接口。
    if not need_direction then return true end
    -- 相机坐标曾实测恒为零；失效时每秒探测，不每帧重复调用。
    if R.cam_coord_supported or R.now >= R.next_camera_probe then
        R.next_camera_probe = R.now + 1000
        local cx, cy, cz = vec(call(CAM, "GET_GAMEPLAY_CAM_COORD"))
        R.cam_coord_supported = not not nonzero(cx, cy, cz)
        if R.cam_coord_supported then R.ox, R.oy, R.oz = cx, cy, cz end
    end
    local h = call(Ped, "GetHeading")
    if not finite(h) then h = call(ENTITY, "GET_ENTITY_HEADING", R.ped) end
    if not finite(h) then return true end
    R.body_h = h
    local pitch, _, yaw = vec(call(CAM, "GET_GAMEPLAY_CAM_ROT", 2))
    R.camera_valid = finite(pitch) and finite(yaw)
    if C.camera_source == 0 then
        if not R.camera_valid then return true end
        R.yaw, R.pitch = yaw, pitch
    else
        R.yaw, R.pitch = h + (R.relative_h or 0), R.relative_p or 0
    end
    local yr, pr = math.rad(R.yaw), math.rad(R.pitch)
    R.fx, R.fy, R.fz = -math.sin(yr) * math.cos(pr), math.cos(yr) * math.cos(pr), math.sin(pr)
    R.direction_ok = true
    return true
end
local function geometry(x, y, z)
    local dx, dy, dz = x - R.ox, y - R.oy, z - R.oz
    local d2 = dx * dx + dy * dy + dz * dz
    if d2 < 0.09 or d2 > C.distance * C.distance then return nil end
    local d = math.sqrt(d2)
    return math.deg(math.acos(clamp((dx * R.fx + dy * R.fy + dz * R.fz) / d, -1, 1))), d
end
local function confirmed_ped(ent)
    local result = call(ENTITY, "IS_ENTITY_A_PED", ent)
    R.type_result = tostring(result)
    if result == true then return true end
    -- 类型 bool 失真时，以角色枚举的成员身份确认，不把所有实体都放行。
    for _, row in pairs(R.candidates) do
        if row.ent == ent and row.expires >= R.now then
            R.type_result = R.type_result .. " / 搜索列表确认"
            return true
        end
    end
    if R.now >= R.next_ped_check then
        R.next_ped_check = R.now + 1000
        R.known_peds = {}
        local list = call(Entity, "get_all_peds")
        if type(list) == "table" then
            for _, handle in ipairs(list) do
                if finite(handle) and handle > 0 then R.known_peds[handle] = true end
            end
        end
    end
    if R.known_peds[ent] then
        R.type_result = R.type_result .. " / 角色枚举确认"
        return true
    end
    return false
end
local function direct_target()
    R.raw_hit, R.hit_reason, R.trigger_source = 0, "自由瞄准接口未返回实体", "无"
    if not memory or type(memory.set_int) ~= "function" or type(memory.get_int) ~= "function"
        or not PLAYER or type(PLAYER.GET_ENTITY_PLAYER_IS_FREE_AIMING_AT) ~= "function" then
        R.detector = "缺少自由瞄准或内存接口"; R.hit_reason = R.detector; return nil
    end
    if not R.out_buf then
        local buf = call(memory, "allocate", 8)
        if not finite(buf) or buf == 0 then R.detector = "出参缓冲分配失败"; R.hit_reason = R.detector; return nil end
        R.out_buf = buf
    end
    -- 清零后读取本次写入的句柄，兼容 bool 返回值失真的运行时。
    R.calls = R.calls + 3
    memory.set_int(R.out_buf, 0)
    PLAYER.GET_ENTITY_PLAYER_IS_FREE_AIMING_AT(R.pid, R.out_buf)
    local ent = memory.get_int(R.out_buf)
    R.raw_hit = ent
    R.detector = "自由瞄准"
    if not finite(ent) or ent <= 0 then return nil end
    if not filter(ent) then R.hit_reason = "准星实体失效或被过滤"; return nil end
    if C.type_check and not confirmed_ped(ent) then R.hit_reason = "准星实体未确认为角色"; return nil end
    local x, y, z = coords(ent)
    if not x then R.hit_reason = "准星实体坐标不可用"; return nil end
    local dx, dy, dz = x - R.ox, y - R.oy, z - R.oz
    if dx * dx + dy * dy + dz * dz > C.distance * C.distance then R.hit_reason = "准星实体超出距离"; return nil end
    R.hit_reason, R.trigger_source = "本帧直接命中", "自由瞄准"
    return ent
end
local function add_candidate(key, ent, ttl)
    if not valid(ent) then R.candidates[key] = nil; return end
    local x, y, z = coords(ent)
    if not x then R.candidates[key] = nil; return end
    local dx, dy, dz = x - R.ox, y - R.oy, z - R.oz
    if dx * dx + dy * dy + dz * dz > C.distance * C.distance then
        R.candidates[key] = nil; return
    end
    local row = R.candidates[key] or {}
    row.ent, row.x, row.y, row.z, row.expires = ent, x, y, z + 0.7, R.now + ttl
    R.candidates[key] = row
end
local function scan_batch()
    if R.now < R.next_scan then return end
    R.next_scan = R.now + C.scan_ms
    if C.players then
        for _ = 1, C.slots_per_batch do
            local slot = R.slot
            R.slot = (slot + 1) % 32
            local ent = slot ~= R.pid and call(PLAYER, "GET_PLAYER_PED", slot) or nil
            add_candidate(slot, ent, math.max(650, C.scan_ms * math.ceil(32 / C.slots_per_batch) * 2))
        end
    end
    if C.npcs then
        if R.now >= R.next_npcs then
            R.next_npcs = R.now + 1000
            local list = call(Entity, "get_all_peds")
            R.npc_list = {}
            if type(list) == "table" then
                for i = 1, math.min(#list, C.npc_cap) do R.npc_list[i] = list[i] end
            end
            R.npc_cursor = 1
        end
        for _ = 1, math.min(2, #R.npc_list) do
            if R.npc_cursor > #R.npc_list then R.npc_cursor = 1 end
            local i = R.npc_cursor
            R.npc_cursor = i + 1
            add_candidate(32 + i, R.npc_list[i], 1200)
        end
    end
end
local function snapshot(ent)
    if not filter(ent) then return nil end
    local x, y, z = vec(call(PED, "GET_PED_BONE_COORDS", ent, C.bone, 0.0, 0.0, 0.0))
    if not nonzero(x, y, z) then
        x, y, z = coords(ent)
        if x then z = z + (C.bone == 31086 and 0.7 or 0.3) end
    end
    if not x then return nil end
    local angle, distance = geometry(x, y, z)
    if not angle then return nil end
    return {ent = ent, x = x, y = y, z = z, angle = angle, distance = distance}
end
local function aligned_target()
    if not C.trigger_assist or not C.aim or not R.aim_ent
        or not R.direction_ok or not R.camera_valid or C.camera_source ~= 0 then return nil end
    -- 接口明确命中了其他实体或返回了被过滤的目标时，不用几何结果覆盖它。
    if finite(R.raw_hit) and R.raw_hit > 0 then return nil end
    -- 用本帧真实相机、当前骨骼重新判断；不使用上一帧角度或即将输出的角度。
    local point = snapshot(R.aim_ent)
    if not point then R.hit_reason = "跟踪目标失效或被过滤"; return nil end
    local dx, dy, dz = point.x - R.ox, point.y - R.oy, point.z - R.oz
    local along = dx * R.fx + dy * R.fy + dz * R.fz
    local miss2 = math.max(0, dx * dx + dy * dy + dz * dz - along * along)
    -- 头/颈约12cm，胸/骨盆约18cm；同时限制在0.6度内，避免近距离过宽。
    local radius = (C.bone == 31086 or C.bone == 39317) and 0.12 or 0.18
    if along <= 0 or point.angle > 0.6 or miss2 > radius * radius then
        R.hit_reason = "自由瞄准无命中；自瞄尚未对齐"
        return nil
    end
    R.trigger_source = "自瞄骨骼对齐"
    R.hit_reason = "当前骨骼已对齐（几何检测）"
    return point.ent
end
local function choose_target(hit)
    local held = R.aim_ent and snapshot(R.aim_ent) or nil
    if held and held.angle > math.max(C.fov, C.release_fov) then held = nil end
    if hit then
        local direct = held and held.ent == hit and held or snapshot(hit)
        if direct then return direct, "准星目标" end
    end
    if held then return held, "持续跟踪" end
    local best, best_angle = nil, C.fov
    R.candidate_count = 0
    for key, row in pairs(R.candidates) do
        if R.now > row.expires then R.candidates[key] = nil
        else
            R.candidate_count = R.candidate_count + 1
            local angle = geometry(row.x, row.y, row.z)
            if angle and angle < best_angle then best, best_angle = row.ent, angle end
        end
    end
    if best then
        local found = snapshot(best)
        if found and found.angle <= C.fov then return found, "分批搜索" end
        for key, row in pairs(R.candidates) do if row.ent == best then R.candidates[key] = nil end end
    end
    return nil, "无"
end
local function follow(target)
    local x, y, z = target.x, target.y, target.z
    if R.sample_ent ~= target.ent then
        R.sample_time, R.vx, R.vy, R.vz = nil, 0, 0, 0
        R.sample_ent = target.ent
    end
    if C.lead_ms > 0 and R.sample_time then
        local dt = (R.now - R.sample_time) / 1000
        if dt > 0 and dt < 0.25 then
            local vx, vy, vz = (x - R.sx) / dt, (y - R.sy) / dt, (z - R.sz) / dt
            if vx * vx + vy * vy + vz * vz < 200 * 200 then
                local a = 1 - math.exp(-dt / 0.08)
                R.vx, R.vy, R.vz = R.vx + (vx - R.vx) * a, R.vy + (vy - R.vy) * a, R.vz + (vz - R.vz) * a
            else R.vx, R.vy, R.vz = 0, 0, 0 end
        end
    end
    R.sx, R.sy, R.sz, R.sample_time = x, y, z, R.now
    local lead = C.lead_ms / 1000
    x, y, z = x + R.vx * lead, y + R.vy * lead, z + R.vz * lead
    local dx, dy, dz = x - R.ox, y - R.oy, z - R.oz
    local yaw = math.deg(atan2(-dx, dy))
    local pitch = math.deg(atan2(dz, math.sqrt(dx * dx + dy * dy)))
    if C.pitch_invert then pitch = -pitch end
    local eh, ep = wrap(yaw - R.yaw), pitch - R.pitch
    local alpha = C.response_ms == 0 and 1 or 1 - math.exp(-R.dt * 1000 / C.response_ms)
    local dh, dp = eh * alpha, ep * alpha
    local length, limit = math.sqrt(dh * dh + dp * dp), C.max_speed * R.dt
    if length > limit and length > 0 then dh, dp = dh * limit / length, dp * limit / length end
    if math.abs(eh) < C.deadzone then dh = 0 end
    if math.abs(ep) < C.deadzone then dp = 0 end
    if not C.observe then
        R.relative_h, R.relative_p = wrap(R.yaw - R.body_h + dh), clamp(R.pitch + dp, -89, 89)
        call(CAM, "SET_GAMEPLAY_CAM_RELATIVE_HEADING", R.relative_h)
        call(CAM, "SET_GAMEPLAY_CAM_RELATIVE_PITCH", R.relative_p, 1.0)
    end
end
local function trigger(hit, ads)
    if not C.trigger then R.trigger_status = "关闭"; reset_trigger(); return end
    if C.hold_trigger and not ads then R.trigger_status = "等待瞄准键"; reset_trigger(); return end
    if not hit then R.trigger_status = R.hit_reason; reset_trigger(); return end
    if R.trigger_ent ~= hit then R.trigger_ent, R.trigger_since = hit, R.now end
    if R.now - R.trigger_since < C.trigger_delay then R.trigger_status = "等待反应延迟"; return end
    if R.last_shot and R.now - R.last_shot < C.trigger_cooldown then R.trigger_status = "冷却"; return end
    if C.observe then R.trigger_status = "观察：准星命中，可开火"; return end
    if not PAD or type(PAD.SET_CONTROL_VALUE_NEXT_FRAME) ~= "function" then
        R.trigger_status = "攻击输入接口不可用"; return
    end
    -- 额外间隔为零时连续保持攻击输入，由游戏处理自动武器自身的射速。
    R.calls = R.calls + 1
    local ok, result = pcall(PAD.SET_CONTROL_VALUE_NEXT_FRAME, 0, 24, 1.0)
    if ok and result ~= false then
        R.last_shot, R.fire_frames, R.trigger_status = R.now, R.fire_frames + 1, "已请求开火"
    else R.trigger_status = "攻击输入失败" end
end
local function tick()
    R.calls, R.frame = 0, R.frame + 1
    if R.reset_requested then
        clear_candidates(); reset_tracking(); reset_trigger()
        R.last_shot, R.last_time, R.error, R.reset_requested = nil, nil, "", false
    end
    if not (C.aim or C.trigger) then
        reset_tracking(); reset_trigger(); R.last_time, R.hit_ent = nil, nil
        R.aim_status, R.trigger_status = "关闭", "关闭"; return
    end
    local now = call(MISC, "GET_GAME_TIMER")
    if not finite(now) then error("游戏计时器不可用") end
    if R.last_time and now < R.last_time then
        clear_candidates(); reset_tracking(); reset_trigger()
        R.last_shot, R.last_time, R.next_camera_probe = nil, nil, 0
    end
    local elapsed = R.last_time and (now - R.last_time) or 16.667
    R.now, R.last_time, R.dt = now, now, clamp(elapsed / 1000, 0.001, 0.05)
    local ped, pid = call(PLAYER, "PLAYER_PED_ID"), call(PLAYER, "PLAYER_ID")
    if not finite(ped) or ped <= 0 or not finite(pid) then
        reset_tracking(); reset_trigger(); R.hit_ent = nil
        R.aim_status, R.trigger_status = "等待角色", "等待角色"; return
    end
    if R.ped ~= ped then clear_candidates(); reset_tracking(); reset_trigger() end
    R.ped, R.pid = ped, pid
    local ads = call(PAD, "IS_CONTROL_PRESSED", 0, 25) == true
    if not ads then ads = call(PLAYER, "IS_PLAYER_FREE_AIMING", pid) == true end
    local run_aim = C.aim and (not C.hold_aim or ads)
    local run_trigger = C.trigger and (not C.hold_trigger or ads)
    if not (run_aim or run_trigger) then
        reset_tracking(); reset_trigger(); R.hit_ent = nil
        R.aim_status = C.aim and "等待瞄准键" or "关闭"
        R.trigger_status = C.trigger and "等待瞄准键" or "关闭"; return
    end
    if not refresh_view(run_aim) then
        R.aim_status, R.trigger_status = "视角数据不可用", "视角数据不可用"
        reset_tracking(); reset_trigger(); R.hit_ent = nil; return
    end
    R.hit_ent = direct_target()
    -- 辅助检测只影响扳机，保持自瞄原有的目标选择与跟随算法。
    local trigger_hit = R.hit_ent
    if not trigger_hit and run_trigger and run_aim then trigger_hit = aligned_target() end
    trigger(trigger_hit, ads)
    if run_aim and R.direction_ok then
        local options = tostring(C.players) .. ":" .. tostring(C.npcs) .. ":" .. C.npc_cap
        if R.scan_options ~= options then
            clear_candidates(); reset_tracking(); R.scan_options = options
        end
        scan_batch()
        local target, source = choose_target(R.hit_ent)
        R.aim_ent, R.aim_source = target and target.ent or nil, source
        if target then
            R.aim_angle, R.aim_distance = target.angle, target.distance
            follow(target)
            R.aim_status = C.observe and "观察目标" or "连续跟踪"
        else reset_tracking(); R.aim_status = "搜索目标" end
    else
        reset_tracking()
        R.aim_status = run_aim and "视角数据不可用" or (C.aim and "等待瞄准键" or "关闭")
    end
end
function on_init()
    StormPro.RegisterMenu("扳机自瞄")
end
function on_stop()
    C.aim, C.trigger = false, false
    reset_tracking(); reset_trigger()
    if R.out_buf then call(memory, "free", R.out_buf); R.out_buf = nil end
end
function on_tick()
    local ok, err = pcall(tick)
    R.peak_calls = math.max(R.peak_calls, R.calls)
    if not ok then
        R.error = tostring(err)
        reset_tracking(); reset_trigger(); R.hit_ent = nil
        R.aim_status, R.trigger_status = "脚本异常", "脚本异常"
    end
end
local function checkbox(label, key)
    local value = StormPro.Checkbox(label, C[key])
    if type(value) == "boolean" then C[key] = value end
end
local function slider(label, key, lo, hi)
    local value = StormPro.SliderInt(label, C[key], lo, hi)
    if finite(value) then C[key] = clamp(math.floor(value + 0.5), lo, hi) end
end
function on_menu_render()
    StormPro.TextColored("扳机 + 自瞄 v2.1 · 扳机兼容修复", 0.55, 0.85, 1, 1)
    checkbox("启用自瞄", "aim")
    StormPro.SameLine()
    checkbox("启用扳机", "trigger")
    checkbox("只观察（不转相机、不请求开火）", "observe")
    StormPro.Text("自瞄：" .. R.aim_status .. " | 扳机：" .. R.trigger_status)
    StormPro.TextDisabled(string.format("跟踪 %s [%s] | 准星命中 %s", tostring(R.aim_ent or "无"), R.aim_source, tostring(R.hit_ent or "无")))
    if R.error ~= "" then StormPro.TextColored(R.error, 1, 0.4, 0.4, 1) end
    if StormPro.CollapsingHeader("自瞄设置") then
        checkbox("按住瞄准键时自瞄", "hold_aim")
        slider("捕获角（度）", "fov", 1, 90)
        slider("保持角（度）", "release_fov", 1, 120)
        slider("最大距离（米）", "distance", 5, 400)
        slider("平滑时间（毫秒，越小越快）", "response_ms", 0, 250)
        slider("最大转速（度/秒）", "max_speed", 90, 1440)
        if StormPro.Button("柔和") then C.response_ms, C.max_speed = 110, 360 end
        StormPro.SameLine()
        if StormPro.Button("流畅跟随") then C.response_ms, C.max_speed = 65, 720 end
        StormPro.SameLine()
        if StormPro.Button("快速跟随") then C.response_ms, C.max_speed = 30, 1080 end
        local bone = C.bone == 31086 and 0 or (C.bone == 39317 and 1 or (C.bone == 24818 and 2 or 3))
        local index = StormPro.Combo("瞄准部位", bone, 4, {"头", "颈", "胸", "骨盆"})
        if type(index) == "number" then C.bone = ({31086, 39317, 24818, 11816})[index + 1] or C.bone end
        slider("移动提前量（毫秒）", "lead_ms", 0, 150)
        checkbox("俯仰反向", "pitch_invert")
    end
    if StormPro.CollapsingHeader("扳机设置") then
        checkbox("按住瞄准键时开火", "hold_trigger")
        checkbox("自瞄对齐后补充检测", "trigger_assist")
        slider("反应延迟（毫秒）", "trigger_delay", 0, 500)
        slider("额外开火间隔（毫秒）", "trigger_cooldown", 0, 500)
        if StormPro.Button("即时扳机") then C.trigger_delay, C.trigger_cooldown = 0, 0 end
        StormPro.TextDisabled("优先直接命中；补充检测要求真实相机已对齐当前目标骨骼。")
        StormPro.TextDisabled("补充检测沿用额外视线检查设置；关闭时几何对齐不判断墙体遮挡。")
    end
    if StormPro.CollapsingHeader("搜索与过滤") then
        checkbox("搜索玩家", "players")
        checkbox("搜索 NPC", "npcs")
        checkbox("跳过濒死角色", "skip_dead")
        checkbox("跳过同车角色", "skip_same_vehicle")
        checkbox("额外视线检查", "los")
        slider("每批搜索间隔（毫秒）", "scan_ms", 10, 100)
        slider("每批玩家槽数量", "slots_per_batch", 1, 8)
        slider("NPC 搜索上限", "npc_cap", 4, 64)
        StormPro.TextDisabled("搜索范围设置不影响准星直接命中；补充检测只检查当前跟踪目标。")
    end
    if StormPro.CollapsingHeader("诊断与兼容") then
        local source = StormPro.Combo("视角来源", C.camera_source, 2, {"真实相机角度（默认）", "自身朝向 + 输出角（兼容）"})
        if type(source) == "number" then C.camera_source = source end
        checkbox("检查准星实体为角色", "type_check")
        StormPro.TextDisabled(string.format("每帧接口调用 %d | 峰值 %d | 候选 %d | 心跳 %d", R.calls, R.peak_calls, R.candidate_count, R.frame))
        StormPro.TextDisabled(string.format("目标角度 %.2f | 距离 %.1f | 开火请求帧 %d", R.aim_angle, R.aim_distance, R.fire_frames))
        StormPro.TextDisabled("检测：" .. R.detector .. " | 角色类型返回：" .. R.type_result)
        StormPro.TextDisabled("原始命中：" .. tostring(R.raw_hit) .. " | 扳机来源：" .. R.trigger_source)
        StormPro.TextDisabled("检测结果：" .. R.hit_reason)
        StormPro.TextDisabled("相机角度有效：" .. tostring(R.camera_valid))
        if StormPro.Button("重置跟踪和错误") then R.reset_requested = true end
    end
end
