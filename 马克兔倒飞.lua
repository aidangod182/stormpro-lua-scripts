-- 马克兔倒飞 v3.2 · 离地判定修复 / StormPro
-- 原生驾驶 + 倒飞横滚纠偏；每次纠偏保留当前机头方向。
-- 不修改 handling、速度、角速度、碰撞、输入或镜头。
-- GET_ENTITY_QUATERNION 使用显式出参，避免依赖包装器的多返回值行为。
local MK2 = 2069146067
local GET_QUAT = 0x7B3703D2D32DFA18
local C = {min_height=5.0, balance=true, strength=10.0, bank=35.0, manual_height=false}
local R = {request=nil, pending=nil, active=nil, buffer=nil, busy=false, stopped=false,
    status="就绪：驾驶 Mk2，在空中点击进入倒飞。", error=""}

local function finite(v)
    return type(v)=="number" and v==v and v>-math.huge and v<math.huge
end
local function need(api, name, ...)
    assert(api and type(api[name])=="function", "缺少接口："..name)
    return api[name](...)
end
local function pointer(h)
    if not finite(h) or h<=0 then return nil end
    local p=need(Entity,"HandleToPtr",h)
    if finite(p) and p~=0 then return p end
end
local function report(message)
    R.status=message
    if Utils and type(Utils.Log)=="function" then
        pcall(Utils.Log,"[马克兔倒飞] "..message)
    end
end
local function finish(message)
    R.pending=nil
    report(message)
end
local function release_buffer()
    if R.buffer then
        need(memory,"free",R.buffer)
        R.buffer=nil
    end
end
local function quaternion(veh)
    if not R.buffer then
        -- 每个 float 出参独占 8 字节，兼容 native 调用器的槽位回写。
        assert(memory and type(memory.free)=="function","缺少接口：memory.free")
        local p=need(memory,"allocate",32)
        assert(finite(p) and p~=0,"四元数缓冲分配失败")
        R.buffer=p
    end
    for i=0,3 do need(memory,"set_float",R.buffer+i*8,12345.0) end
    need(natives,"invoke",GET_QUAT,veh,R.buffer,R.buffer+8,R.buffer+16,R.buffer+24)
    local q={}
    local norm=0.0
    for i=1,4 do
        local v=need(memory,"get_float",R.buffer+(i-1)*8)
        assert(finite(v) and math.abs(v)<=1.01,"四元数出参无效或未写入")
        q[i]=v; norm=norm+v*v
    end
    assert(norm>=0.9 and norm<=1.1,"载具四元数长度异常")
    norm=math.sqrt(norm)
    for i=1,4 do q[i]=q[i]/norm end
    return q
end
local function context()
    local ped=need(PLAYER,"PLAYER_PED_ID")
    local pp=pointer(ped)
    if not pp then return nil,"未找到本地角色" end
    if need(ENTITY,"IS_ENTITY_DEAD",ped,false)~=false then return nil,"角色不可用" end
    local veh=need(PED,"GET_VEHICLE_PED_IS_IN",ped,false)
    local vp=pointer(veh)
    if not vp then return nil,"请先驾驶暴君 Mk2" end
    if need(ENTITY,"GET_ENTITY_MODEL",veh)~=MK2 then return nil,"仅支持暴君 Mk2" end
    if need(VEHICLE,"GET_PED_IN_VEHICLE_SEAT",veh,-1,false)~=ped then
        return nil,"需要坐在驾驶位"
    end
    if need(ENTITY,"IS_ENTITY_DEAD",veh,false)~=false then return nil,"载具已损毁" end
    return {ped=ped,pp=pp,veh=veh,vp=vp}
end
local function same(a,b)
    return a.ped==b.ped and a.pp==b.pp and a.veh==b.veh and a.vp==b.vp
end
local function can_control(veh)
    local networked=need(NETWORK,"NETWORK_GET_ENTITY_IS_NETWORKED",veh)
    if networked==false then return true end
    if networked==true then return need(NETWORK,"NETWORK_HAS_CONTROL_OF_ENTITY",veh)==true end
    return false
end
local function start_balance(p)
    if not C.balance or p.mode=="upright" then return end
    p.balance_time=nil
    R.active=p
end
local function stop_balance(message)
    R.active=nil
    report(message)
end
local function clamp(x,a,b) return math.max(a,math.min(b,x)) end
local function balance_tick(now)
    local p=R.active
    if not p then return end
    if not C.balance then stop_balance("平衡辅助已关闭"); return end
    if need(HUD,"IS_PAUSE_MENU_ACTIVE")~=false or need(CAM,"IS_SCREEN_FADED_OUT")~=false then
        stop_balance("平衡辅助已停止：游戏暂停或切换场景"); return
    end
    local current,why=context()
    if not current or not same(p,current) then
        stop_balance("平衡辅助已停止："..(why or "角色或载具已改变")); return
    end
    if not can_control(p.veh) then stop_balance("平衡辅助已停止：失去载具控制权"); return end
    local height=need(ENTITY,"GET_ENTITY_HEIGHT_ABOVE_GROUND",p.veh)
    if not p.ignore_height then
        assert(finite(height),"无法读取离地高度")
        if height<1.5 then
            stop_balance(string.format("平衡辅助已停止：离地读数 %.2f 米",height)); return
        end
    end
    local elapsed=p.balance_time and now-p.balance_time or 0
    p.balance_time=now
    -- 暂停、切后台、回绕后不补做大角度纠偏。
    if elapsed<=0 or elapsed>250 then return end
    local dt=math.min(elapsed/1000.0,0.05)
    local q=quaternion(p.veh)
    local x,y,z,w=q[1],q[2],q[3],q[4]
    local fx,fy,fz=2.0*(x*y-z*w),1.0-2.0*(x*x+z*z),2.0*(y*z+x*w)
    local ux,uy,uz=2.0*(x*z+y*w),2.0*(y*z-x*w),1.0-2.0*(x*x+y*y)
    -- 世界向下投影到机头的垂直平面，得到保持当前俯仰的倒立上轴。
    local tx,ty,tz=fx*fz,fy*fz,-1.0+fz*fz
    local norm=math.sqrt(tx*tx+ty*ty+tz*tz)
    if norm<0.2 then
        R.status="平衡辅助中：接近垂直，暂缓横滚纠偏"
        return
    end
    tx,ty,tz=tx/norm,ty/norm,tz/norm
    local sine=fx*(uy*tz-uz*ty)+fy*(uz*tx-ux*tz)+fz*(ux*ty-uy*tx)
    local cosine=clamp(ux*tx+uy*ty+uz*tz,-1.0,1.0)
    local error_angle=math.atan(sine,cosine)
    local steer=need(PAD,"GET_CONTROL_NORMAL",0,59)
    local fly_roll=need(PAD,"GET_CONTROL_NORMAL",0,107)
    assert(finite(steer) and finite(fly_roll),"无法读取转向输入")
    local input=clamp(math.max(math.abs(steer),math.abs(fly_roll)),0.0,1.0)
    -- 只放宽已有的压弯，不额外代替玩家转向或指定压弯方向。
    local allowance=math.rad(C.bank)*math.max(0.0,(input-0.1)/0.9)
    local excess=math.max(0.0,math.abs(error_angle)-allowance)
    R.status="平衡辅助中：原生油门与俯仰，转弯可压弯"
    if excess<math.rad(0.4) then return end
    local correction=math.min(excess*(1.0-math.exp(-C.strength*dt)),math.rad(240.0)*dt)
    if error_angle<0 then correction=-correction end
    local s,c=math.sin(correction*0.5),math.cos(correction*0.5)
    -- q * local-Y rotation：数学上严格保留当前 forward，航向与俯仰不被锁定。
    need(ENTITY,"SET_ENTITY_QUATERNION",p.veh,x*c-z*s,y*c+w*s,z*c+x*s,w*c-y*s)
end
local function flip(p)
    if not can_control(p.veh) then finish("当前没有载具控制权，请稍后重试"); return end
    local q=quaternion(p.veh)
    local up=1.0-2.0*(q[1]*q[1]+q[2]*q[2])
    if (p.mode=="upright" and up>0.25) or (p.mode~="upright" and up< -0.25) then
        start_balance(p)
        finish(p.mode=="upright" and "已经正飞，无需翻转" or
            (C.balance and "已经倒飞，平衡辅助已接管" or "已经倒飞，无需翻转"))
        return
    end
    if math.abs(up)<=0.25 then finish("当前接近侧立或垂直，请调整姿态后重试"); return end
    -- q * (0,1,0,0)：绕本地 Y 前轴横滚 180°，保留机头方向。
    -- 不使用 pitch + 180：那样会同时反转机头方向。
    local target={-q[3],q[4],q[1],-q[2]}
    need(ENTITY,"SET_ENTITY_QUATERNION",p.veh,target[1],target[2],target[3],target[4])
    local actual=quaternion(p.veh)
    local dot=0.0
    for i=1,4 do dot=dot+target[i]*actual[i] end
    assert(math.abs(dot)>0.98,"姿态写入未得到确认；未自动重试")
    start_balance(p)
    finish(p.mode=="upright" and "已翻回正飞，继续使用原生操控" or
        (C.balance and "已进入倒飞，自动保持左右平衡" or "已进入倒飞，平衡辅助关闭"))
end
local function tick()
    if R.stopped then return end
    if not R.request and not R.pending and not R.active then return end
    local now=need(MISC,"GET_GAME_TIMER")
    assert(finite(now),"读取游戏计时失败")
    -- 菜单只提交请求，所有游戏接口都在 Tick 中执行。
    if R.request then
        local mode=R.request
        R.request=nil; R.pending=nil; R.active=nil
        local current,why=context()
        if not current then report(why); return end
        current.mode=mode; current.start=now; current.last=now; current.next=now
        current.min_height=C.min_height
        -- 兼容开关仅对主动点击的翻转生效；自动起飞准备始终检查高度。
        current.ignore_height=C.manual_height and mode~="armed"
        R.pending=current
    end
    local p=R.pending
    if not p then balance_tick(now); return end
    if now<p.last or now-p.last>1500 then finish("等待已取消：游戏计时中断"); return end
    p.last=now
    if now-p.start>=20000 then finish("等待已超时，请重新准备倒飞"); return end
    if now<p.next then return end
    p.next=now+100
    if need(HUD,"IS_PAUSE_MENU_ACTIVE")~=false or need(CAM,"IS_SCREEN_FADED_OUT")~=false then
        finish("等待已取消：游戏暂停或正在切换场景"); return
    end
    local current,why=context()
    if not current then finish("等待已取消："..why); return end
    if not same(p,current) then finish("等待已取消：角色或载具已改变"); return end
    local height=need(ENTITY,"GET_ENTITY_HEIGHT_ABOVE_GROUND",p.veh)
    if not p.ignore_height and not finite(height) then
        finish("未读到有效离地高度；确认在空中后可启用手动高度兼容"); return
    end
    -- Mk2 悬浮时不能用 IS_ENTITY_IN_AIR 的布尔值否决有效高度。
    if not p.ignore_height and height<p.min_height then
        if p.mode=="armed" then
            R.status=string.format("等待起飞：离地读数 %.2f 米，要求 %.0f 米（20 秒内）",height,p.min_height)
        else
            finish(string.format("离地读数 %.2f 米，要求 %.0f 米；读数异常可启用手动高度兼容",height,p.min_height))
        end
        return
    end
    -- 先消耗请求，失败不会在下一帧重复写入。
    R.pending=nil
    flip(p)
end

function on_init()
    R.stopped=false
    StormPro.RegisterMenu("马克兔倒飞")
end
function on_tick()
    if R.busy or R.stopped then return end
    R.busy=true
    local ok,err=pcall(tick)
    -- 平衡运行期间复用缓冲，避免每帧分配；停止或失败时释放。
    if not ok then R.active=nil end
    local freed,free_err=true,nil
    if not R.active then freed,free_err=pcall(release_buffer) end
    if not ok or not freed then
        R.request=nil; R.pending=nil; R.active=nil
        R.error=tostring(not ok and err or free_err)
        report("操作失败："..R.error)
    end
    R.busy=false
end
function on_stop()
    R.stopped=true; R.request=nil; R.pending=nil; R.active=nil
    -- 没有持久修改，也不在退出时突然把飞行中的载具扶正。
    if not R.busy then pcall(release_buffer) end
end
local function request(mode)
    if R.stopped then return end
    R.request=mode; R.pending=nil; R.active=nil; R.error=""
    R.status="请求已提交"
end
function on_menu_render()
    StormPro.TextColored("马克兔倒飞 v3.2 · 离地判定修复",0.28,0.76,1.0,1.0)
    StormPro.Text("自动维持倒飞左右平衡，按原有键位驾驶。")
    StormPro.TextDisabled("油门、升降俯仰与飞行方向仍由你控制。")
    local enabled,changed=StormPro.Checkbox("进入倒飞后自动保持平衡",C.balance)
    if changed and type(enabled)=="boolean" then
        C.balance=enabled
        if not enabled then R.active=nil; R.status="平衡辅助已关闭" end
    end
    StormPro.Separator()
    if StormPro.Button("进入倒飞（空中）") then request("inverted") end
    if StormPro.Button("准备倒飞（起飞后执行一次）") then request("armed") end
    if StormPro.Button("翻回正飞（空中）") then request("upright") end
    if StormPro.Button("取消等待") then
        R.request=nil; R.pending=nil; R.status="已取消等待"
    end
    if StormPro.Button("停止平衡辅助") then
        R.request=nil; R.pending=nil; R.active=nil; R.status="平衡辅助已停止"
    end
    local strength=StormPro.SliderFloat("平衡力度",C.strength,2.0,16.0)
    if finite(strength) then C.strength=clamp(strength,2.0,16.0) end
    local bank=StormPro.SliderFloat("转弯允许倾斜（度）",C.bank,0.0,60.0)
    if finite(bank) then C.bank=clamp(bank,0.0,60.0) end
    local height=StormPro.SliderFloat("最低离地高度（米）",C.min_height,3.0,20.0)
    if finite(height) then C.min_height=math.max(3.0,math.min(20.0,height)) end
    local compat,compat_changed=StormPro.Checkbox("手动高度兼容（确认在空中时使用）",C.manual_height)
    if compat_changed and type(compat)=="boolean" then C.manual_height=compat end
    if C.manual_height then
        StormPro.TextDisabled("仅手动进入/翻正跳过高度检查；落地前请停止平衡辅助。")
    end
    StormPro.Separator()
    StormPro.Text("状态："..R.status)
    StormPro.TextDisabled("起飞准备有效期 20 秒；下车、换车或暂停会取消。")
    StormPro.TextDisabled("使用前卸载旧版倒飞脚本，避免同时控制载具。")
end
