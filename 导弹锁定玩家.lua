-- StormPro 导弹锁定玩家 v2.1 · 降低每帧原生调用
-- 本地透明 NPC 附着于步行玩家，作为载具原生制导的辅助目标。
-- 锁定框、锁定时间、射击、弹药、弹道均由游戏处理。
local C = {enabled=false, distance=500, max_targets=6, model_fallback=true}
local R = {
    ped=0, pid=nil, vehicle=0, now=0, last_time=nil,
    candidates={}, proxies={}, pending={}, cursor=0, validation_cursor=0,
    next_tick=0, next_update=0, next_weapon=0, next_lock_state=0, next_cleanup=0,
    next_model=0, model_requested=false, model_ready=false, weapon_ok=false,
    model_since=nil, buffer=nil, status="关闭", error="",
    weapon=0, weapon_status="未检测", native_lock=nil, reset=false,
}
local COP_MODEL = 1581098148 -- s_m_y_cop_01
local MODELS = {[2069146067]="暴君 Mk2", [1483171323]="德罗索"}
local MISSILES = {
    [1966766321]="暴君 Mk2 导弹", [3036244276]="德罗索导弹",
    [2344076862]="暴君导弹", [84788907]="灭世暴徒火箭",
    [1347266149]="义警导弹", [3169388763]="扰流板导弹",
    [3565779982]="潜水载具导弹", [4171469727]="载具火箭",
    [3473446624]="飞机火箭", [153396725]="猎杀者导弹",
    [2092838988]="阿库拉导弹", [1177935125]="推进者导弹",
    [3393648765]="战斗机导弹", [1820910717]="狂焰导弹",
    [3767435620]="海麻雀导弹",
}
local function finite(v)
    return type(v)=="number" and v==v and v>-math.huge and v<math.huge
end
local function call(api, name, ...)
    if not api or type(api[name])~="function" then return nil end
    local ok, value = pcall(api[name], ...)
    if ok then return value end
end
local function require_call(api, name, ...)
    assert(api and type(api[name])=="function", "缺少接口："..name)
    local ok, value = pcall(api[name], ...)
    assert(ok and value~=false, name.." 调用失败："..tostring(value))
    return value
end
local function ptr(ent)
    if not finite(ent) or ent<=0 then return nil end
    local value = call(Entity, "HandleToPtr", ent)
    if finite(value) and value~=0 then return value end
end
local function coords(ent)
    local v = call(ENTITY, "GET_ENTITY_COORDS", ent, true)
    if type(v)~="table" and type(v)~="userdata" then return nil end
    local ok,x,y,z = pcall(function() return v.x,v.y,v.z end)
    if ok and finite(x) and finite(y) and finite(z) and (x~=0 or y~=0 or z~=0) then return x,y,z end
end
local function count(t) local n=0; for _ in pairs(t) do n=n+1 end; return n end
local function queue_remove(slot)
    local row = R.proxies[slot]
    if row then R.pending[row.proxy]=row; R.proxies[slot]=nil end
end
local function clear_targets()
    for slot in pairs(R.proxies) do queue_remove(slot) end
    R.candidates,R.cursor,R.validation_cursor,R.next_update = {},0,0,0
    R.native_lock = nil
end
local function flush_removals(stopping)
    if not next(R.pending) then return end
    if not stopping and R.now<R.next_cleanup then return end
    for handle,row in pairs(R.pending) do
        -- 只删除本脚本创建的同一实体，防止句柄被游戏复用。
        if ptr(handle)~=row.proxy_ptr then R.pending[handle]=nil
        else
            if row.registered then call(PLAYER,"REMOVE_PLAYER_TARGETABLE_ENTITY",row.pid,handle) end
            call(ENTITY,"DETACH_ENTITY",handle,true,false)
            local ok = pcall(function()
                require_call(memory,"set_int",R.buffer,handle)
                require_call(PED,"DELETE_PED",R.buffer)
            end)
            if ptr(handle)~=row.proxy_ptr then R.pending[handle]=nil
            else
                R.error = "辅助目标清理未完成，将继续重试"
                if stopping then
                    -- 卸载后没有下一帧，把仍存活的本地目标交还游戏回收。
                    pcall(function()
                        require_call(memory,"set_int",R.buffer,handle)
                        require_call(ENTITY,"SET_ENTITY_AS_NO_LONGER_NEEDED",R.buffer)
                    end)
                end
            end
            if not ok then R.error="删除辅助目标接口失败" end
        end
    end
    R.next_cleanup=next(R.pending) and R.now+500 or 0
end
local function release_model()
    if R.model_requested then call(STREAMING,"SET_MODEL_AS_NO_LONGER_NEEDED",COP_MODEL) end
    R.model_requested,R.model_since,R.next_model,R.model_ready = false,nil,0,false
end
local function inactive(status)
    clear_targets(); flush_removals(false); release_model(); R.status=status
end
local function ensure_buffer()
    if R.buffer then return end
    -- 创建实体前确认创建、配置、删除路径完整。
    local required = {
        {memory,"allocate"}, {memory,"free"}, {memory,"get_int"}, {memory,"set_int"},
        {PED,"CREATE_PED"}, {PED,"DELETE_PED"}, {PED,"SET_BLOCKING_OF_NON_TEMPORARY_EVENTS"},
        {PED,"SET_PED_CAN_BE_TARGETTED"}, {PED,"SET_PED_AS_ENEMY"},
        {ENTITY,"ATTACH_ENTITY_TO_ENTITY"}, {ENTITY,"SET_ENTITY_ALPHA"},
        {ENTITY,"SET_ENTITY_COLLISION"}, {ENTITY,"DETACH_ENTITY"},
        {PLAYER,"ADD_PLAYER_TARGETABLE_ENTITY"}, {PLAYER,"REMOVE_PLAYER_TARGETABLE_ENTITY"},
    }
    for _,item in ipairs(required) do
        assert(item[1] and type(item[1][item[2]])=="function", "缺少接口："..item[2])
    end
    local buffer = require_call(memory,"allocate",8)
    assert(finite(buffer) and buffer~=0,"出参缓冲分配失败")
    R.buffer=buffer
end
local function weapon_supported()
    require_call(memory,"set_int",R.buffer,0)
    -- bool 返回失真时仍以本次写入的出参为准。
    call(WEAPON,"GET_CURRENT_PED_VEHICLE_WEAPON",R.ped,R.buffer)
    local hash = call(memory,"get_int",R.buffer)
    R.weapon = finite(hash) and hash%4294967296.0 or 0
    if MISSILES[R.weapon] then R.weapon_status=MISSILES[R.weapon]; return true end
    if R.weapon~=0 then R.weapon_status="当前武器不是已识别的载具导弹"; return false end
    local model = call(ENTITY,"GET_ENTITY_MODEL",R.vehicle)
    local name = finite(model) and MODELS[model%4294967296.0] or nil
    if C.model_fallback and name then
        R.weapon_status=name.."（型号兼容；请自行选择制导导弹）"; return true
    end
    R.weapon_status="未读取到载具导弹"; return false
end
local function model_ready()
    if R.model_ready then return true end
    if not R.model_requested or R.now>=R.next_model then
        require_call(STREAMING,"REQUEST_MODEL",COP_MODEL)
        if not R.model_requested then R.model_since=R.now end
        R.model_requested,R.next_model = true,R.now+1000
    end
    if call(STREAMING,"HAS_MODEL_LOADED",COP_MODEL)==true then R.model_ready=true; return true end
    R.status = R.now-R.model_since>=5000 and "辅助目标模型未就绪：检查模型加载接口" or "正在加载锁定辅助目标"
    return false
end
local function candidate(slot)
    if slot==R.pid then return nil end
    local ped = call(PLAYER,"GET_PLAYER_PED",slot)
    local identity = ptr(ped)
    if not identity or ped==R.ped then return nil end
    if call(PED,"IS_PED_DEAD_OR_DYING",ped,true)==true then return nil end
    if call(PED,"IS_PED_IN_ANY_VEHICLE",ped,false)==true then return nil end
    if call(PED,"GET_VEHICLE_PED_IS_IN",ped,false)~=0 then return nil end
    local x,y,z = coords(ped)
    if not x then return nil end
    local dx,dy,dz = x-R.x,y-R.y,z-R.z
    local d2 = dx*dx+dy*dy+dz*dz
    if d2>C.distance*C.distance then return nil end
    return {slot=slot,target=ped,target_ptr=identity,x=x,y=y,z=z,d2=d2,expires=R.now+1500}
end
local function create_proxy(target)
    local proxy = require_call(PED,"CREATE_PED",4,COP_MODEL,
        target.x+0.0,target.y+0.0,target.z+0.0,0.0,false,true)
    assert(finite(proxy) and proxy>0,"创建本地辅助目标失败")
    local identity = ptr(proxy)
    if not identity then
        require_call(memory,"set_int",R.buffer,proxy)
        require_call(PED,"DELETE_PED",R.buffer)
        error("辅助目标句柄无法验证")
    end
    -- 先记录后配置，确保中途异常也可回收。
    local row = {proxy=proxy,proxy_ptr=identity,target=target.target,
        target_ptr=target.target_ptr,pid=R.pid,registered=false}
    R.proxies[target.slot]=row
    require_call(PED,"SET_BLOCKING_OF_NON_TEMPORARY_EVENTS",proxy,true)
    call(PED,"SET_PED_CAN_RAGDOLL",proxy,false)
    require_call(ENTITY,"SET_ENTITY_COLLISION",proxy,false,false)
    -- 保持 visible 标志，使用透明度隐藏，供原生目标筛选使用。
    require_call(ENTITY,"SET_ENTITY_ALPHA",proxy,0,true)
    require_call(PED,"SET_PED_CAN_BE_TARGETTED",proxy,true)
    require_call(PED,"SET_PED_AS_ENEMY",proxy,true)
    call(PED,"SET_ALLOW_LOCKON_TO_PED_IF_FRIENDLY",proxy,true)
    require_call(ENTITY,"ATTACH_ENTITY_TO_ENTITY",proxy,target.target,0,
        0.0,0.0,0.0,0.0,0.0,0.0,false,false,false,true,2,true,false)
    row.registered=true
    require_call(PLAYER,"ADD_PLAYER_TARGETABLE_ENTITY",R.pid,proxy)
end
local function refresh_slot(slot)
    local current=candidate(slot)
    local row=R.proxies[slot]
    if row and (not current or current.target~=row.target or current.target_ptr~=row.target_ptr
        or ptr(row.proxy)~=row.proxy_ptr or call(PED,"IS_PED_DEAD_OR_DYING",row.proxy,true)==true) then
        queue_remove(slot)
    end
    R.candidates[slot]=current
end
local function update_targets()
    -- 每次只扫描两个槽位；当前辅助目标再轮流复查两个。
    local scanned={}
    for _=1,2 do
        local slot=R.cursor; R.cursor=(slot+1)%32
        refresh_slot(slot); scanned[slot]=true
    end
    local validated=0
    for _=1,32 do
        local slot=R.validation_cursor; R.validation_cursor=(slot+1)%32
        if R.proxies[slot] and not scanned[slot] then
            refresh_slot(slot); validated=validated+1
            if validated==2 then break end
        end
    end
    flush_removals(false)
    if R.now<R.next_update then return end
    R.next_update=R.now+200
    local sorted={}
    for slot,row in pairs(R.candidates) do
        if row.expires<R.now then R.candidates[slot]=nil else sorted[#sorted+1]=row end
    end
    table.sort(sorted,function(a,b) if a.d2==b.d2 then return a.slot<b.slot end; return a.d2<b.d2 end)
    local wanted={}
    for i=1,math.min(#sorted,C.max_targets) do wanted[sorted[i].slot]=true end
    for slot in pairs(R.proxies) do if not wanted[slot] then queue_remove(slot) end end
    flush_removals(false)
    -- 删除失败时暂停创建，避免堆积；每次最多创建一个。
    if next(R.pending) then R.status="等待清理辅助目标"; return end
    for _,row in ipairs(sorted) do
        if wanted[row.slot] and not R.proxies[row.slot] then
            local current=candidate(row.slot)
            if current and current.target==row.target and current.target_ptr==row.target_ptr then
                create_proxy(current); break
            end
        end
    end
end
local function tick()
    if R.reset then
        inactive("已重置"); R.error,R.reset="",false
        R.next_tick,R.next_weapon,R.next_lock_state=0,0,0
    end
    if not C.enabled then
        if next(R.pending) then
            local cleanup_time=call(MISC,"GET_GAME_TIMER")
            if finite(cleanup_time) then R.now=cleanup_time end
        end
        inactive("关闭")
        R.last_time,R.weapon,R.weapon_status,R.next_tick,R.next_weapon=nil,0,"未检测",0,0
        return
    end
    local now=call(MISC,"GET_GAME_TIMER")
    assert(finite(now),"游戏计时器不可用")
    if R.last_time and now<R.last_time then
        inactive("计时重置"); R.next_tick,R.next_weapon,R.next_lock_state=0,0,0
    end
    R.now,R.last_time=now,now
    if now<R.next_tick then return end
    R.next_tick=now+50
    local ped,pid=call(PLAYER,"PLAYER_PED_ID"),call(PLAYER,"PLAYER_ID")
    if not ptr(ped) or not finite(pid) or pid<0 or pid>31 then inactive("等待角色"); return end
    local vehicle=call(PED,"GET_VEHICLE_PED_IS_IN",ped,false)
    if not ptr(vehicle) then inactive("请驾驶配有制导导弹的载具"); return end
    if call(PED,"IS_PED_DEAD_OR_DYING",ped,true)==true then inactive("等待复活"); return end
    if call(VEHICLE,"GET_PED_IN_VEHICLE_SEAT",vehicle,-1,false)~=ped then inactive("请坐在驾驶位"); return end
    if R.ped~=ped or R.pid~=pid or R.vehicle~=vehicle then
        inactive("载具切换"); R.next_weapon,R.next_lock_state=0,0
    end
    R.ped,R.pid,R.vehicle=ped,pid,vehicle
    ensure_buffer()
    if now>=R.next_weapon then
        R.next_weapon=now+200
        R.weapon_ok=weapon_supported()
        if R.weapon_ok and call(PLAYER,"IS_PLAYER_VEHICLE_WEAPON_TOGGLED_TO_NON_HOMING",pid)==true then
            R.weapon_ok=false; R.weapon_status="请切换到制导导弹模式"
        end
    end
    if not R.weapon_ok then inactive(R.weapon_status); return end
    R.x,R.y,R.z=coords(ped)
    if not R.x then inactive("角色坐标不可用"); return end
    flush_removals(false)
    if not model_ready() then return end
    R.status="原生锁定辅助已启用"
    update_targets()
    if now>=R.next_lock_state then
        R.next_lock_state=now+500
        R.native_lock=call(VEHICLE,"GET_VEHICLE_HOMING_LOCKON_STATE",vehicle)
    end
end
function on_init() StormPro.RegisterMenu("导弹锁定玩家") end
function on_tick()
    local ok,err=pcall(tick)
    if not ok then
        C.enabled=false
        clear_targets(); flush_removals(false); release_model()
        R.error,R.status=tostring(err),"已停止：接口异常"
    end
end
function on_stop()
    C.enabled=false
    clear_targets(); flush_removals(true); release_model()
    if next(R.pending) then call(Utils,"Log","导弹锁定玩家：部分辅助目标未确认删除，已尝试交还游戏回收") end
    if R.buffer then call(memory,"free",R.buffer); R.buffer=nil end
    R.status="已卸载"
end
function on_menu_render()
    StormPro.TextColored("导弹锁定玩家 v2.1 · 载具原生锁定",0.5,0.85,1,1)
    local enabled=StormPro.Checkbox("启用载具原生锁定步行玩家",C.enabled)
    if type(enabled)=="boolean" then C.enabled=enabled end
    StormPro.Text("状态："..R.status)
    StormPro.TextDisabled("驾驶暴君 Mk2、德罗索等载具，选择制导导弹，按游戏原有方式瞄准、开火。")
    StormPro.TextDisabled("使用游戏原生锁定框、提示音、弹药和射速。辅助目标仅存在于本机。")
    local value=StormPro.SliderInt("辅助目标搜索距离（米）",C.distance,50,800)
    if finite(value) then C.distance=math.max(50,math.min(800,math.floor(value))) end
    value=StormPro.SliderInt("最多辅助目标",C.max_targets,1,31)
    if finite(value) then C.max_targets=math.max(1,math.min(31,math.floor(value))) end
    local fallback=StormPro.Checkbox("武器读取为零时按 Mk2／德罗索型号兼容",C.model_fallback)
    if type(fallback)=="boolean" then C.model_fallback=fallback end
    StormPro.TextDisabled("搜索距离不改变载具导弹原有锁定射程；目标较多时优先附近玩家。")
    StormPro.Text("当前武器："..R.weapon_status)
    StormPro.TextDisabled(string.format("本地辅助目标 %d | 待清理 %d | 武器哈希 %.0f",count(R.proxies),count(R.pending),R.weapon))
    StormPro.TextDisabled("载具原生锁定状态："..tostring(R.native_lock or "未读取").."（0 无／1 捕获中／2 锁定；包含原有载具和 NPC 目标）")
    if R.error~="" then StormPro.TextColored(R.error,1,0.4,0.4,1) end
    if StormPro.Button("清理并重新扫描") then R.reset=true end
end
