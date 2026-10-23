-- ============================================================
--  扳机 · 子弹追踪   for StormPro Lua   v2.04
--  v2.04: 崩溃排查版 —— 只观察默认开(加载后绝不会自动发弹),
--         输入只保留已验证读法, 附"一键诊断"和"手动发射"两级测试
--
--  [A] 强制命中: 扳机按下时从枪口向目标骨骼发真子弹
--      目标来源: 自由瞄准实体(主) + 可选NPC/玩家扫描(默认关, 节流)
--  [B] 实体弹追踪: 识别飞行中的弹体(转向默认锁死)
--  附加: 最大距离 / 准星夹角 / 清理掉落武器
--
--  本运行时实测结论(已绕开, 勿依赖):
--    GET_SELECTED_PED_WEAPON / GET_ENTITY_TYPE / DOES_ENTITY_EXIST /
--    GET_ENTITY_VELOCITY / GET_GAMEPLAY_CAM_RELATIVE_HEADING 恒 0/false
--    可用: GET_ENTITY_COORDS / GET_PED_BONE_COORDS / GET_GAMEPLAY_CAM_ROT /
--          IS_CONTROL_PRESSED / IS_PLAYER_FREE_AIMING / GET_GAME_TIMER
--  v2.00 崩溃教训: GET_PLAYER_TARGET_ENTITY(未实测的出参native)与
--    GetAllEntityHandle(0)高频全量扫描有风险 -> 本版移除前者, 后者默认关+节流
-- ============================================================

local S = {
    -- 主开关
    hit_on        = false,
    dry_run       = true,     -- ★v2.04默认开: 只观察, 不会自动发弹(排查崩溃用)
    hit_trigger   = true,
    hit_need_ads  = true,
    hit_need_fire = false,    -- ★默认关: 按住瞄准键即自动开火(与已验证的扳机自瞄一致)
    scan_npc      = false,    -- ★默认关(崩溃点, 节流扫描)
    scan_players  = false,

    -- 距离 / 角度
    max_dist      = 120,
    fov_deg       = 8,

    -- 弹道
    hit_damage    = 100,
    hit_speed     = 999,
    hit_lead_ms   = 0,
    hit_min_dist  = 2.0,
    hit_muzzle_fwd= 0.5,
    weapon_idx    = 1,
    weapon_auto   = false,

    -- 扳机
    trg_delay     = 120,
    trg_confirm   = 2,
    trg_cooldown  = 150,

    -- 骨骼
    bone_idx      = 1,
    bone_z        = 0.0,

    -- 清理
    clean_range   = 60,
    clean_info    = "-",
    diag_lines    = {},

    -- 运行时
    ped = 0, pid = 0,
    hb = 0, err = "无", stage = "待机",
    msg_queue = {}, shot_info = "-",
    target = nil, t_src = "-",
    ads_pad = false, ads_player = false, ads_grp = nil, fire_key = false,
    muzzle_info = "-", bone_info = "-",
    weapon_h = 0,
    trg_frames = 0, trg_armed = nil, trg_last = 0,
    scan_cache = nil, scan_cache_src = "-", scan_last = 0,
}

local BONES = { 31086, 39317, 24818, 11816 }
local BONE_NAMES = { "头", "颈", "胸", "骨盆" }
local WEAPON_PRESETS = {
    { "突击步枪", "WEAPON_ASSAULTRIFLE" },
    { "卡宾枪", "WEAPON_CARBINERIFLE" },
    { "狙击枪", "WEAPON_SNIPERRIFLE" },
    { "手枪", "WEAPON_PISTOL" },
    { "RPG", "WEAPON_RPG" },
    { "加特林", "WEAPON_MINIGUN" },
}

-- ============================================================
--  基础
-- ============================================================
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function norm180(a) while a > 180 do a = a - 360 end while a < -180 do a = a + 360 end return a end

local function game_ms()
    local ok, t = pcall(MISC.GET_GAME_TIMER)
    if ok and type(t) == "number" then return t end
    return nil
end

local function vec3(v)
    if type(v) == "table" and type(v.x) == "number" then return v.x, v.y, v.z end
    if type(v) == "userdata" then
        local ok, x = pcall(function() return v.x end)
        if ok and type(x) == "number" then
            local oky, y = pcall(function() return v.y end)
            local okz, z = pcall(function() return v.z end)
            if oky and okz then return x, y, z end
        end
    end
    return nil
end

local function entity_valid(ent)
    if type(ent) ~= "number" or ent == 0 then return false end
    if not (Entity and type(Entity.HandleToPtr) == "function") then return true end
    local ok, p = pcall(Entity.HandleToPtr, ent)
    return ok and type(p) == "number" and p ~= 0
end

local function ped_of()
    local ok, v = pcall(PLAYER.PLAYER_PED_ID)
    if ok and type(v) == "number" then return v end
    return nil
end
local function pid_of()
    -- ★PLAYER.PLAYER_ID 是实测可用路径(v1.07验证); GET_PLAYER_ID 可能属于坏哈希批次
    if type(PLAYER.PLAYER_ID) == "function" then
        local ok, v = pcall(PLAYER.PLAYER_ID)
        if ok and type(v) == "number" and v ~= 0 then return v end
    end
    local ok2, v2 = pcall(PLAYER.GET_PLAYER_ID)
    if ok2 and type(v2) == "number" then return v2 end
    return nil
end

local function self_pos()
    if not S.ped then return nil end
    if Ped and type(Ped.GetPosition) == "function" then
        local ok, p = pcall(Ped.GetPosition, S.ped)
        if ok then local x, y, z = vec3(p); if x then return x, y, z end end
    end
    local ok, p = pcall(ENTITY.GET_ENTITY_COORDS, S.ped, true)
    if ok then local x, y, z = vec3(p); if x then return x, y, z end end
    return nil
end

-- 位置差分求速度(GET_ENTITY_VELOCITY 恒0)
local vel_cache = {}
local function vel_of(o, x, y, z)
    local now = game_ms()
    local vx, vy, vz = 0.0, 0.0, 0.0
    if now then
        local p = vel_cache[o]
        if p and now > p.t then
            local dt = (now - p.t) / 1000.0
            if dt > 0.002 then vx, vy, vz = (x - p.x) / dt, (y - p.y) / dt, (z - p.z) / dt end
        end
        vel_cache[o] = { x = x, y = y, z = z, t = now }
        local n = 0
        for _ in pairs(vel_cache) do n = n + 1 end
        if n > 96 then vel_cache = {} end
    end
    return vx, vy, vz
end

local function notify(msg)
    S.msg_queue[#S.msg_queue + 1] = tostring(msg)
    if #S.msg_queue > 6 then table.remove(S.msg_queue, 1) end
end

local function btn(label, fn) if StormPro.Button(label) then fn() end end
local function toggle(label, key)
    local nv = StormPro.Checkbox(label, S[key] and true or false)
    if type(nv) == "boolean" then S[key] = nv end
end
local function slider_int(label, key, vmin, vmax)
    local a = StormPro.SliderInt(label, S[key], vmin, vmax)
    if type(a) == "number" then S[key] = clamp(math.floor(a + 0.5), vmin, vmax) end
end

-- ============================================================
--  瞄准点 / 枪口 / 武器
-- ============================================================
local function aim_point(ent)
    local bone = BONES[S.bone_idx] or 31086
    local ok, c = pcall(PED.GET_PED_BONE_COORDS, ent, bone, 0, 0, S.bone_z)
    if ok then
        local x, y, z = vec3(c)
        if x then S.bone_info = BONE_NAMES[S.bone_idx] .. " ok" return x, y, z end
    end
    S.bone_info = "骨骼失败"
    local ok2, c2 = pcall(ENTITY.GET_ENTITY_COORDS, ent, true)
    if ok2 then local x, y, z = vec3(c2); if x then return x, y, z + 0.5 end end
    return nil
end

local function muzzle_pos()
    if not S.ped then return nil end
    local ok, c = pcall(PED.GET_PED_BONE_COORDS, S.ped, 28422, 0, 0, 0)
    local x, y, z
    if ok then x, y, z = vec3(c); S.muzzle_info = "右手骨骼" end
    if not x then
        local ok2, c2 = pcall(ENTITY.GET_ENTITY_COORDS, S.ped, true)
        if ok2 then x, y, z = vec3(c2); S.muzzle_info = "自身坐标" end
        if not x then S.muzzle_info = "取不到" return nil end
    end
    local okh, h = pcall(ENTITY.GET_ENTITY_HEADING, S.ped)
    if okh and type(h) == "number" then
        local r = math.rad(h)
        x = x - math.sin(r) * 0.3
        y = y + math.cos(r) * 0.3
    end
    return x, y, z
end

function weapon_hash()
    if S.weapon_auto and S.ped then
        local ok, w = pcall(WEAPON.GET_SELECTED_PED_WEAPON, S.ped)
        if ok and type(w) == "number" and w ~= 0 then return w end
    end
    local item = WEAPON_PRESETS[S.weapon_idx]
    if item and type(joaat) == "function" then
        local ok2, h = pcall(joaat, item[2])
        if ok2 and type(h) == "number" then return h end
    end
    return 0
end

-- ============================================================
--  目标获取 (自由瞄准为主, 扫描为可选)
-- ============================================================
local function aimed_entity()
    local pid = S.pid or pid_of()
    if not pid then return nil end
    local buf = memory.allocate(8)
    if not buf then return nil end
    local ok = pcall(PLAYER.GET_ENTITY_PLAYER_IS_FREE_AIMING_AT, pid, buf)
    local v = ok and memory.get_int(buf) or 0
    memory.free(buf)
    if type(v) == "number" and v ~= 0 then return v end
    return nil
end

-- 准星方向
local function aim_dir()
    local ok, r = pcall(CAM.GET_GAMEPLAY_CAM_ROT, 2)
    if ok then
        local pitch, roll, yaw = vec3(r)
        if pitch then
            local ry, rp = math.rad(yaw), math.rad(pitch)
            return -math.sin(ry) * math.cos(rp), math.cos(ry) * math.cos(rp), math.sin(rp)
        end
    end
    return nil
end

-- 节流扫描(每500ms一次, 结果缓存复用; NPC/玩家都默认关)
local SCAN_CAP = 32
local function scan_target()
    local now = game_ms() or 0
    if S.scan_cache ~= nil and now - S.scan_last < 500 then
        if S.scan_cache == 0 then return nil, S.scan_cache_src end
        return S.scan_cache, S.scan_cache_src
    end
    S.scan_last = now
    S.scan_cache = 0
    S.scan_cache_src = "扫描:无"

    if not (S.scan_npc or S.scan_players) then return nil, "扫描未开" end
    local ox, oy, oz = self_pos()
    if not ox then return nil, "扫描:取不到自身" end
    local fx, fy, fz = aim_dir()

    local best, bestang, bsrc = 0, nil, "扫描"
    local function consider(ent, src)
        if type(ent) ~= "number" or ent == 0 or ent == S.ped then return end
        if not entity_valid(ent) then return end
        local ok, c = pcall(ENTITY.GET_ENTITY_COORDS, ent, true)
        if not ok then return end
        local x, y, z = vec3(c)
        if not x or (x == 0 and y == 0 and z == 0) then return end
        local dx, dy, dz = x - ox, y - oy, z - oz
        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
        if d > S.max_dist then return end
        local ang = 0
        if fx then
            local dot = (dx * fx + dy * fy + dz * fz) / (d > 0.01 and d or 1)
            ang = math.deg(math.acos(clamp(dot, -1, 1)))
            if ang > S.fov_deg then return end
        end
        if best == 0 or ang < bestang then best, bestang, bsrc = ent, ang, src end
    end

    -- 真人玩家(官方native遍历槽位)
    if S.scan_players then
        local okn, num = pcall(PLAYER.GET_NUMBER_OF_PLAYERS)
        if okn and type(num) == "number" and num > 0 then
            for i = 0, num - 1 do
                local oka, act = pcall(NETWORK.NETWORK_IS_PLAYER_ACTIVE, i)
                if oka and act == true and i ~= (S.pid or -1) then
                    local okp, e = pcall(PLAYER.GET_PLAYER_PED, i)
                    if okp and type(e) == "number" then consider(e, "玩家槽" .. i) end
                end
            end
        end
    end

    -- NPC(默认关; 节流+上限32)
    if S.scan_npc and Entity and type(Entity.GetAllEntityHandle) == "function" then
        local okn, list = pcall(Entity.GetAllEntityHandle, 0)
        if okn and type(list) == "table" then
            for i = 1, math.min(#list, SCAN_CAP) do
                consider(list[i], "NPC")
            end
        end
    end

    if best ~= 0 then
        S.scan_cache = best
        S.scan_cache_src = string.format("%s %.1f°", bsrc, bestang or 0)
        return best, S.scan_cache_src
    end
    return nil, S.scan_cache_src
end

local function get_target()
    local e = aimed_entity()
    if e and entity_valid(e) then return e, "自由瞄准" end
    e = scan_target()
    if e then return e, S.scan_cache_src end
    return nil, "-"
end

-- ============================================================
--  [A] 强制命中
-- ============================================================
local function muzzle_lead(ent, tx, ty, tz)
    if S.hit_lead_ms <= 0 then return tx, ty, tz end
    local lead = S.hit_lead_ms / 1000.0
    local vx, vy, vz = vel_of(ent, tx, ty, tz)
    return tx + vx * lead, ty + vy * lead, tz + vz * lead
end

local function force_hit(ent)
    local mx, my, mz = muzzle_pos()
    if not mx then return false, "取不到枪口" end
    local tx, ty, tz = aim_point(ent)
    if not tx then return false, "取不到目标点" end
    tx, ty, tz = muzzle_lead(ent, tx, ty, tz)

    local wpn = weapon_hash()
    if wpn == 0 then return false, "取不到武器哈希" end
    S.weapon_h = wpn

    -- 距离检查(对目标本身, 不依赖扫描)
    local ox, oy, oz = self_pos()
    if ox then
        local dd = math.sqrt((tx - ox) ^ 2 + (ty - oy) ^ 2 + (tz - oz) ^ 2)
        if dd > S.max_dist then return false, string.format("目标太远(%.0fm>%d)", dd, S.max_dist) end
    end

    if S.dry_run then
        S.shot_info = string.format("[只观察] 枪口(%.1f,%.1f,%.1f) -> 目标(%.1f,%.1f,%.1f)",
            mx, my, mz, tx, ty, tz)
        return true, "dry"
    end

    local ddx, ddy, ddz = tx - mx, ty - my, tz - mz
    local dline = math.sqrt(ddx * ddx + ddy * ddy + ddz * ddz)
    if dline < S.hit_min_dist then return false, string.format("目标太近(%.1fm)", dline) end
    if S.hit_muzzle_fwd > 0 and dline > S.hit_muzzle_fwd + 0.2 then
        local k = S.hit_muzzle_fwd / dline
        mx, my, mz = mx + ddx * k, my + ddy * k, mz + ddz * k
    end

    local ok, err = pcall(MISC.SHOOT_SINGLE_BULLET_BETWEEN_COORDS,
        mx, my, mz, tx, ty, tz, S.hit_damage, true, wpn, S.ped, true, false, S.hit_speed + 0.0)
    if ok then
        S.shot_info = string.format("已命中 -> %d (%.0fm)", ent, dline)
        return true
    end
    return false, tostring(err)
end

-- 枚举指定类型实体(文档988行: 0=Ped 1=Vehicle 2=Pickup 3=Object)
local function enum_type(t)
    if not (Entity and type(Entity.GetAllEntityHandle) == "function") then return {} end
    local ok, list = pcall(Entity.GetAllEntityHandle, t)
    if ok and type(list) == "table" then return list end
    return {}
end

-- 清理掉落武器(Pickup=2 / Object=3)
local function clean_dropped()
    local ox, oy, oz = self_pos()
    if not ox then return 0, 0, "取不到自身坐标" end
    local del, fail = 0, 0
    for _, t in ipairs({ 2, 3 }) do
        for _, h in ipairs(enum_type(t)) do
            if type(h) == "number" and h ~= 0 and h ~= S.ped and entity_valid(h) then
                local okc, c = pcall(ENTITY.GET_ENTITY_COORDS, h, true)
                if okc then
                    local x, y, z = vec3(c)
                    if x and x ~= 0 then
                        local dx, dy, dz = x - ox, y - oy, z - oz
                        if math.sqrt(dx * dx + dy * dy + dz * dz) <= S.clean_range then
                            local okd = pcall(Entity.DeleteEntity, h)
                            if okd then del = del + 1 else fail = fail + 1 end
                        end
                    end
                end
            end
        end
    end
    return del, fail, nil
end

-- ============================================================
--  诊断 / 手动发射 (v2.04 排查工具)
-- ============================================================
local function diagnose()
    local lines = {}
    lines[#lines + 1] = string.format("ped=%s pid=%s", tostring(S.ped), tostring(S.pid))
    local ox, oy, oz = self_pos()
    lines[#lines + 1] = string.format("自身坐标: %s", ox and string.format("%.1f,%.1f,%.1f", ox, oy, oz) or "取不到")
    lines[#lines + 1] = string.format("瞄准键=%s 自由瞄准=%s", tostring(S.ads_pad), tostring(S.ads_player))
    local e = aimed_entity()
    lines[#lines + 1] = string.format("自由瞄准实体=%s (有效=%s)", tostring(e), tostring(e and entity_valid(e) or false))
    if e then
        local x, y, z = aim_point(e)
        lines[#lines + 1] = string.format("瞄准点: %s", x and string.format("%.1f,%.1f,%.1f", x, y, z) or "取不到")
    end
    local mx, my, mz = muzzle_pos()
    lines[#lines + 1] = string.format("枪口: %s %s", tostring(S.muzzle_info),
        mx and string.format("%.1f,%.1f,%.1f", mx, my, mz) or "取不到")
    S.weapon_h = weapon_hash()
    lines[#lines + 1] = string.format("武器哈希=%d (%s)", S.weapon_h,
        (WEAPON_PRESETS[S.weapon_idx] and WEAPON_PRESETS[S.weapon_idx][1]) or "?")
    S.diag_lines = lines
    notify("诊断完成(见下方)")
end

-- 手动发射: 无视只观察, 真打一发(用于判定"崩溃是否出在发射路径")
local function manual_fire()
    local e = aimed_entity()
    if not e then
        S.shot_info = "手动发射: 自由瞄准没有实体"
        return
    end
    local was_dry = S.dry_run
    S.dry_run = false
    local ok, why = force_hit(e)
    S.dry_run = was_dry
    S.shot_info = ok and ("手动发射成功 -> " .. tostring(e)) or ("手动发射失败: " .. tostring(why))
    notify(S.shot_info)
end

-- ============================================================
--  主循环
-- ============================================================
-- ============================================================
--  输入读取 (只保留已验证读法: 扳机自瞄.lua 第506行 组0 + 普通按下)
--  v2.04: 删掉了 IS_DISABLED_CONTROL_PRESSED 和组2探测(未经你验证)
-- ============================================================
local function key_down(action)
    local ok, v = pcall(PAD.IS_CONTROL_PRESSED, 0, action)
    if ok and v == true then return true end
    return false
end

local function tick()
    S.hb = S.hb + 1
    if S.hb % 30 == 1 then
        S.ped = ped_of() or S.ped
        S.pid = pid_of() or S.pid
        S.weapon_h = weapon_hash()
    end

    if not (S.hit_on and S.ped) then
        S.stage = "待机 (A未开启)"
        S.trg_frames = 0
        return
    end

    -- 瞄准键(组0, 已验证读法)
    local ads = key_down(25)
    local freeaiming = false
    if S.pid then
        local okf, fa = pcall(PLAYER.IS_PLAYER_FREE_AIMING, S.pid)
        freeaiming = okf and fa == true
    end
    S.ads_pad, S.ads_player = ads, freeaiming

    -- 开火键(仅当"必须按开火键"开启时才作为门控)
    local fire_key = S.hit_need_fire and key_down(24) or false
    S.fire_key = fire_key

    local aiming = ads or freeaiming
    local want_fire = S.hit_trigger
    if S.hit_need_fire and not fire_key then want_fire = false end
    if S.hit_need_ads and not aiming then want_fire = false end

    if not want_fire then
        S.trg_frames = 0
        S.trg_armed = nil
        if S.hit_need_ads and not aiming then
            S.stage = "就绪 (等待瞄准键)"
        else
            S.stage = "就绪 (等待开火键)"
        end
        return
    end

    local now = game_ms() or 0
    if S.trg_frames == 0 then S.trg_armed = now end
    S.trg_frames = S.trg_frames + 1
    local waited = (S.trg_armed and (now - S.trg_armed)) or 0
    if S.trg_frames < S.trg_confirm or waited < S.trg_delay
        or (S.trg_last > 0 and now - S.trg_last < S.trg_cooldown) then
        S.stage = string.format("扳机: 帧%d 等%d/%dms", S.trg_frames, waited, S.trg_delay)
        return
    end

    local ent, src = get_target()
    S.target, S.t_src = ent, src or "-"
    if not ent then
        S.stage = "扳机: 无目标"
        return
    end

    local ok, why = force_hit(ent)
    if ok then
        if why ~= "dry" then S.trg_last = now end
        S.stage = why == "dry" and "命中(只观察)" or "已发射"
    else
        S.stage = "失败: " .. tostring(why)
        S.shot_info = tostring(why)
    end
end

-- ============================================================
--  生命周期
-- ============================================================
function on_init()
    StormPro.RegisterMenu("扳机子弹追踪")
    StormPro.ShowNotification("[子弹追踪] v2.04 已加载 (只观察默认开; 加诊断/手动发射)")
end

function on_stop()
    S.hit_on = false
end

function on_tick()
    local ok, err = pcall(tick)
    if not ok then S.err = tostring(err) end
end

function on_menu_render()
    for _ = 1, 3 do
        local m = table.remove(S.msg_queue, 1)
        if not m then break end
        StormPro.ShowNotification("[子弹追踪] " .. m)
    end

    StormPro.TextColored("扳机 · 子弹追踪 v2.04", 1.0, 0.85, 0.2, 1.0)
    StormPro.Separator()
    if S.dry_run then
        StormPro.TextColored("★ 只观察已开: 不会自动发弹 (排查崩溃用, 确认稳定后再关)", 1.0, 0.85, 0.3, 1.0)
    end
    if S.err ~= "无" then StormPro.TextColored("异常: " .. S.err, 1.0, 0.4, 0.4, 1.0) end
    StormPro.TextDisabled(string.format("状态: %s | 最近: %s", S.stage, S.shot_info))
    StormPro.TextDisabled(string.format("目标: %s [%s] | 瞄准:%s(组%s) 开火:%s | 武器哈希:%d",
        tostring(S.target), S.t_src, tostring(S.ads_pad), tostring(S.ads_grp),
        tostring(S.fire_key), S.weapon_h))

    if StormPro.CollapsingHeader("[A] 强制命中") then
        if StormPro.Button(S.hit_on and "强制命中: 已开启 (点击关闭)" or "强制命中: 已关闭 (点击开启)") then
            S.hit_on = not S.hit_on
            S.trg_frames = 0
            S.trg_armed = nil
        end
        toggle("只观察 (不发真弹)", "dry_run")
        toggle("由扳机自动触发", "hit_trigger")
        toggle("必须按瞄准键", "hit_need_ads")
        toggle("必须按开火键(默认关, 按住右键即开火)", "hit_need_fire")

        slider_int("最大距离 (米)", "max_dist", 5, 500)
        slider_int("准星夹角 (度)", "fov_deg", 1, 45)

        StormPro.TextDisabled(string.format("弹道武器: %s (哈希%d)",
            (WEAPON_PRESETS[S.weapon_idx] and WEAPON_PRESETS[S.weapon_idx][1]) or "?", S.weapon_h))
        for i = 1, #WEAPON_PRESETS do
            local idx = i
            if i > 1 then StormPro.SameLine() end
            btn(WEAPON_PRESETS[i][1], function() S.weapon_idx = idx end)
        end
        slider_int("伤害", "hit_damage", 1, 1000)
        slider_int("弹速", "hit_speed", 100, 3000)
        slider_int("提前量 (ms)", "hit_lead_ms", 0, 400)

        StormPro.Spacing()
        slider_int("反应延迟 (ms)", "trg_delay", 0, 1000)
        slider_int("确认帧", "trg_confirm", 1, 15)
        slider_int("连发冷却 (ms)", "trg_cooldown", 0, 2000)
        btn("硬触发 (0/1/100)", function() S.trg_delay, S.trg_confirm, S.trg_cooldown = 0, 1, 100 end)
        StormPro.SameLine()
        btn("软触发 (150/3/300)", function() S.trg_delay, S.trg_confirm, S.trg_cooldown = 150, 3, 300 end)
        StormPro.Separator()
        StormPro.TextColored("▼ 排查工具 (先点这两个)", 1.0, 0.8, 0.3, 1.0)
        btn("一键诊断 (不发弹)", function() diagnose() end)
        StormPro.SameLine()
        btn("手动发射一次 (真弹)", function() manual_fire() end)
        for i = 1, #S.diag_lines do StormPro.TextDisabled("  " .. S.diag_lines[i]) end
    end

    if StormPro.CollapsingHeader("目标扫描 (可选, 默认关)") then
        toggle("包含 NPC (500ms节流, 最多32个)", "scan_npc")
        toggle("包含真人玩家", "scan_players")
        StormPro.TextDisabled("扫描结果: " .. S.scan_cache_src)
        StormPro.TextDisabled("瞄准点: " .. S.bone_info .. " | 枪口: " .. S.muzzle_info)
        slider_int("命中部位", "bone_idx", 1, 4)
        StormPro.TextDisabled(string.format("部位: %s", BONE_NAMES[S.bone_idx] or "?"))
    end

    if StormPro.CollapsingHeader("清理掉落武器") then
        slider_int("清理半径 (米)", "clean_range", 5, 300)
        btn("清理附近拾取物/物体", function()
            local del, fail, why = clean_dropped()
            S.clean_info = why and ("失败: " .. why) or string.format("已删除%d个(失败%d)", del, fail)
            notify(S.clean_info)
        end)
        StormPro.TextDisabled("清理: " .. S.clean_info)
    end
end
