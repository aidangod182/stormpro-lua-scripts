-- StormPro ESP v1.2：分批采样 + 每帧平滑跟随；默认仅方框。
-- pcall 不能捕获宿主 native 的访问异常。
local C = {
    enabled = false, players = true, npcs = false, boxes = true,
    names = false, distance_text = false, health = false, skip_dead = true,
    distance = 150, max_draw = 12, update_ms = 50,
    text_size = 0.30, thickness = 0.0015, smooth_ms = 45,
}
local R = {
    buffer = nil, records = {}, slots = {}, selected = {}, cursor = 1,
    slot = 0, npc_list = {}, npc_cursor = 1, next_scan = 0, next_npcs = 0,
    next_select = 0, next_view = 0, last_time = nil, options = "",
    drawn = 0, nearby = 0, error = "", status = "关闭", aspect = 16 / 9,
    busy = false, stopped = false, samples = 0, gap = 0, peak_gap = 0,
}
local function finite(v)
    return type(v) == "number" and v == v and v > -math.huge and v < math.huge
end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function vector(v)
    if type(v) ~= "table" and type(v) ~= "userdata" then return nil end
    local x, y, z = v.x or v[1], v.y or v[2], v.z or v[3]
    if finite(x) and finite(y) and finite(z) then return x, y, z end
end
local function valid(ped)
    if not finite(ped) or ped <= 0 then return false end
    local ptr = Entity.HandleToPtr(ped)
    return finite(ptr) and ptr ~= 0
end
local function position(ped) return vector(ENTITY.GET_ENTITY_COORDS(ped, true)) end
local function clear(now)
    R.records, R.slots, R.selected, R.npc_list = {}, {}, {}, {}
    R.slot, R.cursor, R.npc_cursor = 0, 1, 1
    R.next_scan, R.next_npcs, R.next_select, R.next_view = now or 0, now or 0, now or 0, now or 0
    R.own, R.last_time, R.drawn, R.nearby = nil, nil, 0, 0
end
local function release_buffer()
    if R.buffer and R.buffer ~= 0 then
        local ptr = R.buffer
        R.buffer = nil
        memory.free(ptr)
    end
end
local function project(x, y, z)
    -- 两个出参使用分开的 8 字节槽，额外留空；缓冲仅分配一次。
    memory.set_float(R.buffer, -100.0)
    memory.set_float(R.buffer + 8, -100.0)
    local ok = GRAPHICS.GET_SCREEN_COORD_FROM_WORLD_COORD(x + 0.0, y + 0.0, z + 0.0, R.buffer, R.buffer + 8)
    if R.stopped then return nil, nil, "missing" end
    local sx, sy = memory.get_float(R.buffer), memory.get_float(R.buffer + 8)
    if not finite(sx) or not finite(sy) or sx == -100 or sy == -100 then return nil, nil, "missing" end
    if not ok or sx < -2 or sx > 3 or sy < -2 or sy > 3 then return nil, nil, "outside" end
    return sx, sy
end
local function rect(x, y, width, height, r, g, b, a)
    local left, right = math.max(0, x - width / 2), math.min(1, x + width / 2)
    local top, bottom = math.max(0, y - height / 2), math.min(1, y + height / 2)
    if right > left and bottom > top then
        GRAPHICS.DRAW_RECT((left + right) / 2, (top + bottom) / 2,
            right - left + 0.0, bottom - top + 0.0, r, g, b, a, false)
    end
end
local PLAYER_COLOR, NPC_COLOR = {70, 195, 255}, {255, 195, 75}
local function smooth_box(target, now)
    local box = target.box
    local rendered = target.rendered
    local dt = rendered and now - rendered.time or 0
    -- 初次出现、重现或镜头/实体大幅跳变时直接对齐，避免跨屏拖出残影。
    local snap = not rendered or dt < 0 or dt > 250 or C.smooth_ms <= 0
    if not snap then
        local dx = box.x - rendered.x
        local dy = box.top + box.height / 2 - rendered.top - rendered.height / 2
        local scale = box.height / rendered.height
        snap = math.abs(dx) > 0.35 or math.abs(dy) > 0.35 or scale > 2.5 or scale < 0.4
    end
    if snap then
        rendered = {x = box.x, top = box.top, width = box.width, height = box.height, time = now}
        target.rendered = rendered
    else
        -- 根据实际经过的时间计算指数平滑系数，避免按帧固定比例导致帧率依赖。
        -- 原始采样值与显示值分开；没到下一次采样的帧也继续插值。
        local alpha = 1 - math.exp(-dt / C.smooth_ms)
        rendered.x = rendered.x + (box.x - rendered.x) * alpha
        rendered.top = rendered.top + (box.top - rendered.top) * alpha
        rendered.width = rendered.width + (box.width - rendered.width) * alpha
        rendered.height = rendered.height + (box.height - rendered.height) * alpha
        rendered.time = now
    end
    return rendered
end
local function draw(target, now)
    local box = smooth_box(target, now)
    local x, top, width, height = box.x, box.top, box.width, box.height
    local color = target.player and PLAYER_COLOR or NPC_COLOR
    if C.boxes then
        local ty, tx = C.thickness, C.thickness / R.aspect
        rect(x, top, width + tx, ty, color[1], color[2], color[3], 230)
        rect(x, top + height, width + tx, ty, color[1], color[2], color[3], 230)
        rect(x - width / 2, top + height / 2, tx, height, color[1], color[2], color[3], 230)
        rect(x + width / 2, top + height / 2, tx, height, color[1], color[2], color[3], 230)
    end
    if (C.names or C.distance_text) and target.label and x >= 0 and x <= 1 then
        HUD.SET_TEXT_FONT(0)
        HUD.SET_TEXT_SCALE(0.0, C.text_size + 0.0)
        HUD.SET_TEXT_COLOUR(color[1], color[2], color[3], 255)
        HUD.SET_TEXT_CENTRE(true)
        HUD.SET_TEXT_RIGHT_JUSTIFY(false)
        HUD.SET_TEXT_WRAP(0.0, 1.0)
        HUD.SET_TEXT_OUTLINE()
        HUD.BEGIN_TEXT_COMMAND_DISPLAY_TEXT("STRING")
        HUD.ADD_TEXT_COMPONENT_SUBSTRING_PLAYER_NAME(target.label)
        HUD.END_TEXT_COMMAND_DISPLAY_TEXT(x + 0.0, clamp(top - C.text_size * 0.065, 0.0, 0.96) + 0.0, 0)
    end
    if C.health and target.ratio then
        local bar_w = 0.003 / R.aspect
        local bx = x - width / 2 - bar_w * 2
        rect(bx, top + height / 2, bar_w * 1.8, height + 0.002, 0, 0, 0, 170)
        rect(bx, top + height - height * target.ratio / 2, bar_w, height * target.ratio,
            math.floor(255 * (1 - target.ratio)), math.floor(220 * target.ratio), 50, 240)
    end
end
local function distance2(x, y, z) return (x - R.ox)^2 + (y - R.oy)^2 + (z - R.oz)^2 end
local function remember(ped, slot, now)
    if ped == R.own or not valid(ped) then return end
    if slot == nil and PED.IS_PED_A_PLAYER(ped) then return end
    local x, y, z = position(ped)
    if not x then return end
    local d2 = distance2(x, y, z)
    if d2 < 0.01 or d2 > C.distance^2 then R.records[ped] = nil; return end
    local record = R.records[ped]
    if not record then
        local count = 0
        for _ in pairs(R.records) do count = count + 1 end
        if count >= 96 then return end
        record = {ped = ped, sampled = now - C.update_ms, stats_at = now - 250}
        R.records[ped] = record
    end
    record.player, record.seen, record.d2 = slot ~= nil, now, d2
    if slot ~= nil and C.names then
        record.name = tostring(PLAYER.GET_PLAYER_NAME(slot) or "Player"):gsub("~", ""):gsub("[%c]", " ")
    else record.name = slot ~= nil and "Player" or "NPC" end
end
local function discover(now)
    if now >= R.next_scan then
        R.next_scan = now + 50
        -- 每批两个槽，不再同一帧扫描 32 个玩家及全部角色。
        for _ = 1, 2 do
            local slot = R.slot
            local ped = PLAYER.GET_PLAYER_PED(slot)
            local old = R.slots[slot]
            if old and old ~= ped then R.records[old] = nil end
            R.slots[slot] = ped
            if C.players then remember(ped, slot, now) end
            R.slot = (slot + 1) % 32
        end
    end
    if C.npcs then
        if now >= R.next_npcs then
            R.next_npcs, R.npc_cursor = now + 2000, 1
            R.npc_list = Entity.GetAllEntityHandle(0)
            assert(type(R.npc_list) == "table", "角色枚举未返回列表")
        end
        for _ = 1, 2 do
            local ped = R.npc_list[R.npc_cursor]
            if not ped or R.npc_cursor > 512 then break end
            R.npc_cursor = R.npc_cursor + 1
            local known_player = false
            for _, player_ped in pairs(R.slots) do if player_ped == ped then known_player = true; break end end
            if not known_player then remember(ped, nil, now) end
        end
    end
end
local function select_targets(now)
    if now < R.next_select then return end
    R.next_select = now + 150
    local list = {}
    for ped, target in pairs(R.records) do
        if now - target.seen > (target.player and 2500 or 4500) then R.records[ped] = nil
        elseif target.d2 <= C.distance^2 then list[#list + 1] = target end
    end
    table.sort(list, function(a, b)
        local ad = a.d2 + (a.outside and C.distance^2 or 0)
        local bd = b.d2 + (b.outside and C.distance^2 or 0)
        if ad == bd then return a.ped < b.ped end
        return ad < bd
    end)
    R.nearby = #list
    while #list > math.min(24, C.max_draw + 4) do list[#list] = nil end
    R.selected = list
    if R.cursor > #list then R.cursor = 1 end
end
local function sample(target, now)
    target.sampled = now
    R.samples = R.samples + 1
    if not valid(target.ped) then
        R.records[target.ped], target.box = nil, nil
        return
    end
    if now - target.stats_at >= 250 then
        target.stats_at = now
        target.dead = C.skip_dead and PED.IS_PED_DEAD_OR_DYING(target.ped, true)
        if C.health then
            local hp, maximum = ENTITY.GET_ENTITY_HEALTH(target.ped), ENTITY.GET_ENTITY_MAX_HEALTH(target.ped)
            target.ratio = finite(hp) and finite(maximum) and maximum > 0 and clamp(hp / maximum, 0, 1) or nil
        end
    end
    if target.dead then target.box = nil; return end
    local x, y, z = position(target.ped)
    if not x then target.box = nil; return end
    target.d2 = distance2(x, y, z)
    if target.d2 > C.distance^2 or target.d2 < 0.01 then target.box = nil; return end
    -- 不读骨骼，使用站姿近似框；减少每目标的 native 调用。
    local sx, top, fail = project(x, y, z + 0.9)
    local fx, bottom, fail2
    if sx then fx, bottom, fail2 = project(x, y, z - 1.0) end
    if not sx or not fx then
        if fail == "outside" or fail2 == "outside" then target.box, target.outside = nil, true
        elseif target.box then
            target.box.expires = target.box.time + 100
            if now > target.box.expires then target.box = nil end
        end
        return
    end
    local height, center = bottom - top, (sx + fx) / 2
    local width = height * 0.48 / R.aspect
    if height <= 0.002 or height > 4 or bottom < 0 or top > 1 or center + width / 2 < 0 or center - width / 2 > 1 then
        target.box, target.outside = nil, true
        return
    end
    target.outside = false
    target.box = {x = center, top = top, width = width, height = height, time = now, expires = now + 250}
    if C.names or C.distance_text then
        local name = C.names and target.name or ""
        local distance = C.distance_text and string.format("%.0fm", math.sqrt(target.d2)) or ""
        target.label = name .. (name ~= "" and distance ~= "" and " | " or "") .. distance
    end
end
local function tick()
    local now = MISC.GET_GAME_TIMER()
    assert(finite(now), "游戏计时接口异常")
    if R.last_time and (now < R.last_time or now - R.last_time > 500) then clear(now) end
    R.gap = R.last_time and now - R.last_time or 0
    R.peak_gap = math.max(R.peak_gap, R.gap)
    R.last_time = now
    local options = table.concat({tostring(C.players), tostring(C.npcs), tostring(C.names),
        tostring(C.distance_text), tostring(C.health), tostring(C.skip_dead), C.distance, C.max_draw}, ":")
    if options ~= R.options then clear(now); R.options = options; R.last_time = now end
    if now >= R.next_view then
        R.next_view = now + 50
        local own = PLAYER.PLAYER_PED_ID()
        if not valid(own) then clear(now); R.status = "等待本地角色"; return end
        if R.own and R.own ~= own then clear(now); R.last_time = now end
        R.own = own
        R.ox, R.oy, R.oz = position(own)
        if not R.ox then clear(now); R.status = "等待本地坐标"; return end
    end
    if not R.buffer then
        local ptr = memory.allocate(32)
        assert(finite(ptr) and ptr ~= 0, "屏幕坐标缓冲分配失败")
        R.buffer = ptr
    end
    if now >= (R.next_aspect or 0) then
        R.next_aspect = now + 2000
        local aspect = GRAPHICS.GET_ASPECT_RATIO(false)
        if finite(aspect) and aspect >= 0.5 and aspect <= 8 then R.aspect = aspect end
    end
    discover(now)
    select_targets(now)
    -- 每帧最多四个目标做坐标/投影更新，所有有效缓存仍逐帧重画。
    local checked = 0
    while checked < #R.selected and R.samples < 4 and not R.stopped do
        if R.cursor > #R.selected then R.cursor = 1 end
        local target = R.selected[R.cursor]
        R.cursor, checked = R.cursor + 1, checked + 1
        if R.records[target.ped] == target and now - target.sampled >= C.update_ms then sample(target, now) end
    end
    if R.stopped then return end
    for _, target in ipairs(R.selected) do
        if R.drawn >= C.max_draw then break end
        if R.records[target.ped] == target and target.box and now <= target.box.expires then
            draw(target, now)
            R.drawn = R.drawn + 1
        else
            -- 确认失效/屏外后的再次出现不沿用旧的显示位置。
            target.rendered = nil
        end
    end
    R.status = "运行中"
end
function on_init() StormPro.RegisterMenu("ESP透视") end
function on_menu_render()
    StormPro.TextColored("ESP透视 v1.2 · 平滑跟随", 0.28, 0.76, 1.0, 1.0)
    local changed
    C.enabled, changed = StormPro.Checkbox("启用 ESP", C.enabled)
    if changed then R.error = ""; R.options = "" end
    C.players = StormPro.Checkbox("显示玩家", C.players)
    C.npcs = StormPro.Checkbox("显示 NPC", C.npcs)
    C.skip_dead = StormPro.Checkbox("过滤死亡角色", C.skip_dead)
    StormPro.Separator()
    C.boxes = StormPro.Checkbox("方框", C.boxes)
    C.names = StormPro.Checkbox("名字 / NPC 标签", C.names)
    C.distance_text = StormPro.Checkbox("距离", C.distance_text)
    C.health = StormPro.Checkbox("血条（原生生命值比例）", C.health)
    C.distance = StormPro.SliderInt("最大距离（米）", C.distance, 10, 600)
    C.max_draw = StormPro.SliderInt("最大显示数量", C.max_draw, 1, 24)
    C.update_ms = StormPro.SliderInt("坐标更新间隔（毫秒）", C.update_ms, 33, 150)
    C.smooth_ms = StormPro.SliderInt("平滑响应（毫秒）", C.smooth_ms, 0, 120)
    C.text_size = StormPro.SliderFloat("文字大小", C.text_size, 0.2, 0.6)
    C.thickness = StormPro.SliderFloat("线条粗细", C.thickness, 0.0005, 0.004)
    StormPro.Separator()
    StormPro.Text("默认仅方框，12人/150米；文字和血条按需开启。")
    StormPro.Text("平滑响应默认45ms；调小跟手，调大更柔和，0关闭平滑。")
    StormPro.Text("蓝色玩家，黄色NPC；站姿近似框，蹲姿/载具内可能有偏差。")
    StormPro.Text(string.format("%s | 范围内 %d | 绘制 %d | 本帧采样 %d", R.status, R.nearby, R.drawn, R.samples))
    StormPro.Text(string.format("Tick间隔 %dms / 峰值 %dms", R.gap, R.peak_gap))
    if R.error ~= "" then StormPro.Text("错误：" .. R.error) end
end
function on_tick()
    if R.busy or R.stopped then return end
    R.drawn, R.samples = 0, 0
    if not C.enabled then
        if R.last_time or next(R.records) then clear() end
        R.status = R.error ~= "" and "错误后已关闭，重新勾选可重试" or "关闭"
        return
    end
    R.busy = true
    local ok, err = pcall(tick)
    R.busy = false
    if R.stopped then clear(); release_buffer(); return end
    if not ok then
        R.error, R.status, C.enabled = tostring(err), "接口错误", false
        clear()
        if Utils and Utils.Log then Utils.Log("[ESP v1.2] " .. R.error) end
    end
end
function on_stop()
    R.stopped, C.enabled = true, false
    -- 宿主若在 native 调用期间重入卸载回调，等待本次 Tick 退出再释放。
    if R.busy then return end
    clear()
    release_buffer()
end
