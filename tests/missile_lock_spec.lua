-- 原生载具锁定：验证辅助目标生命周期及保留原生开火流程。
local function size(t) local n=0; for _ in pairs(t) do n=n+1 end; return n end
local function harness()
    local w={time=0,ped=10,pid=0,vehicle=20,driver=10,weapon=1966766321,model=2069146067,
        nonhoming=false,loaded=true,slots={[1]=11},dead={},vehicles={},
        positions={[10]={x=1,y=1,z=1},[11]={x=1,y=101,z=1}},
        pointers={[10]=1010,[11]=1011,[20]=1020,[21]=1021},mem={},nextped=100,
        calls=0,created={},deleted={},alpha={},collision={},attached={},registered={},
        forbidden=0,allocs=0,frees=0,requests=0,releases=0,remove_calls=0,lockstate=0,
        delete_fail=false,attach_fail=false,weapon_writes=true}
    local env=setmetatable({}, {__index=_G})
    local function native(fn) return function(...) w.calls=w.calls+1; return fn(...) end end
    local function forbidden()
        w.forbidden=w.forbidden+1; error("不允许操作开火、弹药、网络或自绘锁定框")
    end
    local function restricted(t) return setmetatable(t or {}, {__index=function() return forbidden end}) end
    env.PAD=restricted(); env.NETWORK=restricted(); env.GRAPHICS=restricted(); env.HUD=restricted()
    env.CAM=restricted(); env.FIRE=restricted()
    env.MISC=restricted({GET_GAME_TIMER=native(function() return w.time end)})
    env.WEAPON=restricted({GET_CURRENT_PED_VEHICLE_WEAPON=native(function(_,p)
        if w.weapon_writes then w.mem[p]=w.weapon end
        return false -- 模拟 bool 返回失真，但出参成功写入。
    end)})
    env.memory={
        allocate=native(function() w.allocs=w.allocs+1; return 9000 end),
        free=native(function(p) assert(p==9000); w.frees=w.frees+1 end),
        set_int=native(function(p,v) assert(p==9000); w.mem[p]=v end),
        get_int=native(function(p) return w.mem[p] or 0 end),
    }
    env.Entity={HandleToPtr=native(function(h) return w.pointers[h] or 0 end)}
    env.PLAYER={
        PLAYER_PED_ID=native(function() return w.ped end), PLAYER_ID=native(function() return w.pid end),
        GET_PLAYER_PED=native(function(slot) return slot==w.pid and w.ped or w.slots[slot] or 0 end),
        IS_PLAYER_VEHICLE_WEAPON_TOGGLED_TO_NON_HOMING=native(function() return w.nonhoming end),
        ADD_PLAYER_TARGETABLE_ENTITY=native(function(pid,h) assert(pid==w.pid); w.registered[h]=pid end),
        REMOVE_PLAYER_TARGETABLE_ENTITY=native(function(pid,h)
            assert(w.registered[h]==nil or w.registered[h]==pid)
            w.remove_calls=w.remove_calls+1; w.registered[h]=nil
        end),
    }
    env.PED={
        GET_VEHICLE_PED_IS_IN=native(function(h) return h==w.ped and w.vehicle or w.vehicles[h] or 0 end),
        IS_PED_IN_ANY_VEHICLE=native(function(h) return (w.vehicles[h] or 0)~=0 end),
        IS_PED_DEAD_OR_DYING=native(function(h) return w.dead[h]==true end),
        CREATE_PED=native(function(...)
            local args={...}; assert(#args==8 and args[7]==false and args[8]==true)
            for i=3,6 do assert(math.type(args[i])=="float") end
            local h=w.nextped; w.nextped=h+1
            w.pointers[h]=h+10000; w.created[#w.created+1]={handle=h,args=args}; return h
        end),
        DELETE_PED=native(function(p)
            local h=w.mem[p]; assert(h>=100,"不得删除玩家或载具")
            if w.delete_fail then return end
            w.pointers[h]=nil; w.attached[h]=nil; w.mem[p]=0; w.deleted[#w.deleted+1]=h
        end),
        SET_BLOCKING_OF_NON_TEMPORARY_EVENTS=native(function(h,b) assert(h>=100 and b) end),
        SET_PED_CAN_RAGDOLL=native(function(h,b) assert(h>=100 and not b) end),
        SET_PED_CAN_BE_TARGETTED=native(function(h,b) assert(h>=100 and b) end),
        SET_PED_AS_ENEMY=native(function(h,b) assert(h>=100 and b) end),
        SET_ALLOW_LOCKON_TO_PED_IF_FRIENDLY=native(function(h,b) assert(h>=100 and b) end),
    }
    env.ENTITY={
        GET_ENTITY_COORDS=native(function(h) return w.positions[h] end),
        GET_ENTITY_MODEL=native(function() return w.model end),
        SET_ENTITY_ALPHA=native(function(h,a) assert(h>=100); w.alpha[h]=a end),
        SET_ENTITY_COLLISION=native(function(h,b) assert(h>=100); w.collision[h]=b end),
        ATTACH_ENTITY_TO_ENTITY=native(function(h,target,...)
            assert(h>=100 and target<100)
            if w.attach_fail then error("模拟附着失败") end
            local args={...}; assert(#args==14)
            w.attached[h]=target
        end),
        DETACH_ENTITY=native(function(h) assert(h>=100); w.attached[h]=nil end),
        SET_ENTITY_AS_NO_LONGER_NEEDED=native(function(p) w.released_handle=w.mem[p] end),
    }
    env.VEHICLE={
        GET_PED_IN_VEHICLE_SEAT=native(function(_,seat) assert(seat==-1); return w.driver end),
        GET_VEHICLE_HOMING_LOCKON_STATE=native(function() return w.lockstate end),
    }
    env.STREAMING={
        REQUEST_MODEL=native(function() w.requests=w.requests+1 end),
        HAS_MODEL_LOADED=native(function() return w.loaded end),
        SET_MODEL_AS_NO_LONGER_NEEDED=native(function() w.releases=w.releases+1 end),
    }
    env.StormPro={RegisterMenu=function() end, Text=function() end, TextDisabled=function() end,
        TextColored=function() end, Checkbox=function(_,v) return v end,
        SliderInt=function(_,v) return v end, Button=function() return false end}
    assert(loadfile("导弹锁定玩家.lua","t",env))(); env.on_init()
    local c,r
    for i=1,20 do
        local name,value=debug.getupvalue(env.on_menu_render,i)
        if name=="C" then c=value elseif name=="R" then r=value end
    end
    assert(c and r)
    local function step(ms,allow_error)
        w.time=w.time+(ms or 50); env.on_tick()
        assert(w.forbidden==0,"触碰了原生开火流程")
        if not allow_error then assert(r.error=="",r.error) end
    end
    local function start() c.enabled=true; step(); assert(size(r.proxies)==1,r.status) end
    return w,c,r,env,step,start
end
local n=0
local function test(name,fn) fn(); n=n+1; print("PASS "..name) end
test("关闭和菜单渲染零游戏调用",function()
    local w,_,_,env,step=harness(); step(); env.on_menu_render(); assert(w.calls==0)
end)
test("Mk2 创建透明、无碰撞、本地附着目标",function()
    local w,_,r,_,_,start=harness(); start(); local h=r.proxies[1].proxy
    assert(w.alpha[h]==0 and w.collision[h]==false and w.attached[h]==11 and w.registered[h]==0)
end)
test("德罗索有符号武器哈希及原生状态",function()
    local w,_,r,_,_,start=harness(); w.weapon=3036244276.0-4294967296.0
    w.model=1483171323; w.lockstate=2; start()
    assert(r.weapon==3036244276.0 and r.native_lock==2)
end)
test("所有运行阶段均不接管开火、弹药、相机或绘制锁定框",function()
    local w,c,_,env,step,start=harness(); start()
    for _=1,80 do step() end
    c.enabled=false; step(); env.on_stop(); assert(w.forbidden==0)
end)
test("步行与乘客状态不会创建目标",function()
    for _,mode in ipairs({"foot","passenger"}) do
        local w,c,_,_,step=harness(); c.enabled=true
        if mode=="foot" then w.vehicle=0 else w.driver=12 end
        step(); assert(#w.created==0 and w.allocs==0)
    end
end)
test("只选择其他步行玩家，排除乘员、死者和范围外目标",function()
    for _,mode in ipairs({"vehicle","dead","far","absent"}) do
        local w,c,r,_,step=harness(); c.enabled=true
        if mode=="vehicle" then w.vehicles[11]=22 elseif mode=="dead" then w.dead[11]=true
        elseif mode=="far" then w.positions[11].y=1001 else w.slots={} end
        for _=1,16 do step() end
        assert(size(r.proxies)==0 and #w.created==0)
    end
end)
test("目标上车、死亡、离线、超距后回收辅助目标",function()
    for _,mode in ipairs({"vehicle","dead","left","far"}) do
        local w,_,r,_,step,start=harness(); start()
        if mode=="vehicle" then w.vehicles[11]=22 elseif mode=="dead" then w.dead[11]=true
        elseif mode=="left" then w.slots[1]=nil else w.positions[11].y=1001 end
        step(100); assert(size(r.proxies)==0 and #w.deleted==1 and size(w.registered)==0)
    end
end)
test("重生同槽新角色重新创建，清理旧附着",function()
    local w,_,r,_,step,start=harness(); start()
    w.slots[1]=12; w.positions[12]={x=1,y=100,z=1}; w.pointers[12]=1012
    step(200); assert(#w.deleted==1 and r.proxies[1].target==12)
    assert(w.attached[r.proxies[1].proxy]==12)
end)
test("同句柄身份变化不会继续跟随旧实体",function()
    local w,_,r,_,step,start=harness(); start(); w.pointers[11]=9011; step(200)
    assert(#w.deleted==1 and r.proxies[1].target_ptr==9011)
end)
test("关闭和重复卸载回收一次，缓冲只释放一次",function()
    local w,c,r,env,step,start=harness(); start(); c.enabled=false; step()
    assert(#w.deleted==1 and size(r.pending)==0 and w.releases==1)
    env.on_stop(); env.on_stop(); assert(#w.deleted==1 and w.frees==1)
end)
test("下车或换乘不支持的车辆立即清理",function()
    for _,mode in ipairs({"exit","switch"}) do
        local w,_,r,_,step,start=harness(); start()
        if mode=="exit" then w.vehicle=0 else w.vehicle=21; w.weapon=0; w.model=1 end
        step(200); assert(size(r.proxies)==0 and #w.deleted==1)
    end
end)
test("切换机枪或关闭制导即清理，不修改武器模式",function()
    for _,mode in ipairs({"gun","nonhoming"}) do
        local w,_,r,_,step,start=harness(); start()
        if mode=="gun" then w.weapon=123 else w.nonhoming=true end
        step(200); assert(size(r.proxies)==0 and #w.deleted==1 and w.forbidden==0)
    end
end)
test("零出参仅对指定型号启用兼容，已知机枪不走兼容",function()
    local w,c,r,_,step=harness(); c.enabled=true; w.weapon=0; step()
    assert(size(r.proxies)==1 and r.weapon_status:find("型号兼容"))
    c.model_fallback=false; step(200); assert(size(r.proxies)==0)
    c.model_fallback=true; w.weapon=123; step(200); assert(size(r.proxies)==0)
end)
test("每次清零武器出参，不沿用上一帧导弹哈希",function()
    local w,c,r,_,step,start=harness(); start(); c.model_fallback=false
    w.weapon_writes=false; step(200); assert(r.weapon==0 and size(r.proxies)==0)
end)
test("模型未加载时异步等待且不创建",function()
    local w,c,r,_,step=harness(); c.enabled=true; w.loaded=false; step(); step(5100)
    assert(#w.created==0 and r.status:find("未就绪"))
    w.loaded=true; step(); assert(#w.created==1)
end)
test("辅助目标数量受限，分帧创建，优先近处",function()
    local w,c,r,_,step=harness(); c.enabled=true; c.max_targets=2
    for i=1,5 do w.slots[i]=10+i; w.positions[10+i]={x=1,y=100*i,z=1}; w.pointers[10+i]=1010+i end
    for _=1,20 do
        local before=#w.created; step(25)
        assert(#w.created-before<=1 and size(r.proxies)<=2)
    end
    assert(r.proxies[1] and r.proxies[2] and not r.proxies[3])
end)
test("配置中途失败仍回收创建的实体并停止",function()
    local w,c,r,_,step=harness(); c.enabled=true; w.attach_fail=true; step(25,true)
    assert(not c.enabled and #w.created==1 and #w.deleted==1 and size(r.proxies)==0)
    assert(r.error:find("ATTACH_ENTITY_TO_ENTITY"))
end)
test("删除失败保留待清理记录、暂停新增并在后续重试",function()
    local w,c,r,_,step,start=harness(); start(); w.delete_fail=true; c.enabled=false; step(25,true)
    assert(size(r.pending)==1 and #w.deleted==0)
    w.delete_fail=false; step(500,true); assert(size(r.pending)==0 and #w.deleted==1)
end)
test("辅助实体句柄复用时不删除其他实体",function()
    local w,c,r,_,step,start=harness(); start(); local h=r.proxies[1].proxy
    w.pointers[h]=999999; c.enabled=false; step()
    assert(#w.deleted==0 and w.pointers[h]==999999 and size(r.pending)==0)
end)
test("缺少删除接口时创建前就停止",function()
    local w,c,r,env,step=harness(); c.enabled=true; env.PED.DELETE_PED=nil; step(25,true)
    assert(#w.created==0 and not c.enabled and r.error:find("DELETE_PED"))
end)
test("时间回绕清理再建，不滞留旧目标",function()
    local w,_,r,_,step,start=harness(); start(); w.time=-25; step()
    assert(#w.deleted==1 and size(r.proxies)==1)
end)
test("卸载删除失败时尝试交还游戏并释放缓冲",function()
    local w,_,r,env,_,start=harness(); start(); local h=r.proxies[1].proxy
    w.delete_fail=true; env.on_stop(); assert(w.released_handle==h and w.frees==1)
end)
test("多人场景限制每帧和每秒的原生调用量",function()
    local w,c,r,_,step=harness(); c.enabled=true
    for slot=1,12 do
        local ped=10+slot
        w.slots[slot]=ped; w.pointers[ped]=1010+slot
        w.positions[ped]={x=1,y=10+slot*10,z=1}
    end
    for _=1,150 do step(20) end -- 稳态前先让六个辅助目标建立。
    assert(size(r.proxies)==6)
    local before=w.calls; local peak=0
    for _=1,100 do
        local previous=w.calls; step(20)
        peak=math.max(peak,w.calls-previous)
    end
    local per_second=(w.calls-before)/2
    assert(peak<=65 and per_second<=700,
        string.format("调用预算：峰值 %d，平均 %.0f/s",peak,per_second))
    print(string.format("PERF 多人稳态：峰值 %d 次/帧，平均 %.0f 次/秒",peak,per_second))
end)
print(string.format("%d tests passed",n))
