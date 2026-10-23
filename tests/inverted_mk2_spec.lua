-- Run from project root: npx.cmd --offline --yes --package=fengari-node-cli fengari tests/inverted_mk2_spec.lua
local function harness(balance)
    local w={now=0,ped=10,veh=20,driver=10,model=2069146067,air=true,height=10.0,
        paused=false,faded=false,dead={},ptrs={[10]=1010,[20]=2020,[21]=2021},
        net=true,control=true,q={0.0,0.0,0.0,1.0},mem={},calls=0,writes=0,
        allocs=0,frees=0,logs={},texts={},buffer=nil,vel={2,40,-3},ang={0.1,0.2,0.3},
        steer=0.0,roll_input=0.0,sliders={}}
    local env=setmetatable({}, {__index=_G})
    local function wrap(fn) return function(...) w.calls=w.calls+1; return fn(...) end end
    local function strict(t)
        return setmetatable(t,{__index=function(_,key) error("未允许的接口："..key) end})
    end
    env.Utils={Log=function(s) w.logs[#w.logs+1]=s end}
    env.StormPro=strict({
        RegisterMenu=function(s) w.menu=s end,
        Text=function(s) w.texts[#w.texts+1]=s end,
        TextDisabled=function() end,TextColored=function() end,Separator=function() end,
        SliderFloat=function(label,v) return w.sliders[label] or v end,
        Checkbox=function(_,v) if w.check~=nil then return w.check,w.check~=v end; return v,false end,
        Button=function(label) return label==w.click end,
    })
    env.Entity=strict({HandleToPtr=wrap(function(h) return w.ptrs[h] or 0 end)})
    env.PLAYER=strict({PLAYER_PED_ID=wrap(function() return w.ped end)})
    env.PED=strict({GET_VEHICLE_PED_IS_IN=wrap(function() return w.veh end)})
    env.VEHICLE=strict({GET_PED_IN_VEHICLE_SEAT=wrap(function(_,seat) assert(seat==-1); return w.driver end)})
    env.MISC=strict({GET_GAME_TIMER=wrap(function() return w.now end)})
    env.HUD=strict({IS_PAUSE_MENU_ACTIVE=wrap(function() return w.paused end)})
    env.CAM=strict({IS_SCREEN_FADED_OUT=wrap(function() return w.faded end)})
    env.PAD=strict({GET_CONTROL_NORMAL=wrap(function(_,id)
        assert(id==59 or id==107); return id==59 and w.steer or w.roll_input
    end)}) -- 只读转向，不允许拦截原生输入。
    env.NETWORK=strict({
        NETWORK_GET_ENTITY_IS_NETWORKED=wrap(function() return w.net end),
        NETWORK_HAS_CONTROL_OF_ENTITY=wrap(function() return w.control end),
    })
    env.ENTITY=strict({
        IS_ENTITY_DEAD=wrap(function(h) return w.dead[h]==true end),
        GET_ENTITY_MODEL=wrap(function() return w.model end),
        IS_ENTITY_IN_AIR=wrap(function() return w.air end),
        GET_ENTITY_HEIGHT_ABOVE_GROUND=wrap(function() return w.height end),
        SET_ENTITY_QUATERNION=wrap(function(h,x,y,z,a)
            assert(h==w.veh); w.writes=w.writes+1
            if w.throw_set then error("写入失败") end
            if not w.noop_set then w.q={x,y,z,a} end
        end),
    })
    env.memory=strict({
        allocate=wrap(function(n)
            assert(n==32 and not w.buffer); w.allocs=w.allocs+1
            if w.fail_alloc then return 0 end
            w.buffer=9000; return w.buffer
        end),
        free=wrap(function(p) assert(p==w.buffer); w.frees=w.frees+1; w.buffer=nil end),
        set_float=wrap(function(p,v)
            assert(w.buffer and p>=9000 and p<=9024 and (p-9000)%8==0)
            w.mem[p]=v
        end),
        get_float=wrap(function(p) return w.mem[p] end),
    })
    env.natives=strict({invoke=wrap(function(hash,h,x,y,z,a)
        assert(hash==0x7B3703D2D32DFA18 and h==w.veh)
        assert(x==9000 and y==9008 and z==9016 and a==9024)
        if w.missing_output then return end
        for i=1,4 do w.mem[9000+(i-1)*8]=w.q[i] end
    end)})
    assert(loadfile("马克兔倒飞.lua","t",env))()
    env.on_init()
    if not balance then w.check=false; env.on_menu_render(); w.check=nil end
    local function click(label)
        local calls=w.calls
        w.click=label; env.on_menu_render(); w.click=nil
        assert(w.calls==calls,"菜单线程不应调用 native")
    end
    local function step(dt) w.now=w.now+(dt or 16); env.on_tick() end
    local function message() env.on_menu_render(); return w.texts[#w.texts] end
    return w,env,click,step,message
end
local n=0
local function test(name,f) f(); n=n+1; print("PASS "..name) end
local ENTER="进入倒飞（空中）"
local ARM="准备倒飞（起飞后执行一次）"
local EXIT="翻回正飞（空中）"
local function close(a,b) assert(math.abs(a-b)<1e-6,tostring(a).." != "..tostring(b)) end
local function axes(q)
    local x,y,z,w=table.unpack(q)
    return {2*(x*y-z*w),1-2*(x*x+z*z),2*(y*z+x*w)},
        {2*(x*z+y*w),2*(y*z-x*w),1-2*(x*x+y*y)}
end
test("待机与菜单没有游戏调用",function()
    local w,e,click,step=harness()
    for _=1,100 do e.on_menu_render(); step() end
    assert(w.calls==0 and w.writes==0)
end)
test("只翻转一次，保持惯性和所有原生输入",function()
    local w,e,click,step=harness()
    click(ENTER); step()
    assert(w.writes==1 and w.allocs==1 and w.frees==1)
    close(w.q[2],1); close(w.q[4],0)
    local before=w.calls
    for _=1,600 do step() end
    assert(w.calls==before and w.writes==1)
    assert(w.vel[2]==40 and w.ang[2]==0.2)
    e.on_stop(); assert(w.writes==1)
end)
test("不同俯仰航向下机头不变、上轴反向",function()
    for i=1,200 do
        local w,e,click,step=harness()
        local x=math.sin(i*1.3)*0.9; local y=math.cos(i*0.7)*0.9
        local z=math.sin(i*0.2); local a=math.cos(i*0.4)
        local len=math.sqrt(x*x+y*y+z*z+a*a)
        w.q={x/len,y/len,z/len,a/len}
        local f,u=axes(w.q)
        if math.abs(u[3])>0.25 then
            click(u[3]>0 and ENTER or EXIT); step()
            assert(w.writes==1)
            local ff,uu=axes(w.q)
            for j=1,3 do close(f[j],ff[j]); close(u[j],-uu[j]) end
        end
    end
end)
test("重复进入不会翻回去，退出可还原朝向",function()
    local w,e,click,step=harness()
    click(ENTER); step(); click(ENTER); step(); assert(w.writes==1)
    click(EXIT); step(); assert(w.writes==2); close(math.abs(w.q[4]),1)
    click(EXIT); step(); assert(w.writes==2)
end)
test("地面准备只对这次起飞执行一次",function()
    local w,e,click,step=harness(); w.air=false; w.height=0
    click(ARM); step(); assert(w.writes==0)
    w.air=true; w.height=4; step(100); assert(w.writes==0)
    w.height=6; step(100); assert(w.writes==1)
    w.air=false; step(100); w.air=true; step(100); assert(w.writes==1)
end)
test("取消等待与卸载不写姿态",function()
    for _,stop in ipairs({false,true}) do
        local w,e,click,step=harness(); w.air=false
        click(ARM); step()
        if stop then e.on_stop() else click("取消等待") end
        w.air=true; step(100); assert(w.writes==0 and w.allocs==0)
    end
end)
test("等待 20 秒超时",function()
    local w,e,click,step,msg=harness(); w.air=false
    click(ARM); step()
    for _=1,200 do step(100) end
    w.air=true; step(100)
    assert(w.writes==0 and msg():find("超时"))
end)
test("计时中断和回绕取消，不延迟触发",function()
    for _,delta in ipairs({2000,-100}) do
        local w,e,click,step,msg=harness(); w.air=false
        click(ARM); step(); w.air=true; step(delta)
        assert(w.writes==0 and msg():find("中断"))
    end
end)
test("换车、句柄复用、下车、死亡、暂停、场景切换取消准备",function()
    local changes={
        function(w) w.veh=21 end,
        function(w) w.ptrs[20]=3030 end,
        function(w) w.ptrs[10]=4040 end,
        function(w) w.veh=0 end,
        function(w) w.dead[10]=true end,
        function(w) w.dead[20]=true end,
        function(w) w.paused=true end,
        function(w) w.faded=true end,
    }
    for _,change in ipairs(changes) do
        local w,e,click,step=harness(); w.air=false
        click(ARM); step(); change(w); w.air=true; step(100)
        assert(w.writes==0 and w.allocs==0)
    end
end)
test("错误车型、乘客、地面、低空、无控制权拒绝写入",function()
    local changes={
        function(w) w.model=1 end,function(w) w.driver=11 end,
        function(w) w.air=false end,function(w) w.height=2 end,
        function(w) w.control=false end,function(w) w.dead[10]=true end,
    }
    for _,change in ipairs(changes) do
        local w,e,click,step=harness(); change(w)
        click(ENTER); step(); assert(w.writes==0 and w.allocs==0)
    end
end)
test("非网络实体可以翻转",function()
    local w,e,click,step=harness(); w.net=false; w.control=false
    click(ENTER); step(); assert(w.writes==1)
end)
test("侧立与垂直姿态不强行翻转",function()
    for _,q in ipairs({{0,math.sqrt(0.5),0,math.sqrt(0.5)},
                       {math.sqrt(0.5),0,0,math.sqrt(0.5)}}) do
        local w,e,click,step=harness(); w.q=q
        click(ENTER); step(); assert(w.writes==0 and w.allocs==w.frees)
    end
end)
test("缺少出参、非有限值与异常长度不写姿态",function()
    local changes={function(w) w.missing_output=true end,
        function(w) w.q={0,0,0,0} end,function(w) w.q={0/0,0,0,1} end,
        function(w) w.q={1,1,1,1} end}
    for _,change in ipairs(changes) do
        local w,e,click,step,msg=harness(); change(w)
        click(ENTER); step(); assert(w.writes==0 and w.allocs==w.frees)
        assert(msg():find("操作失败")); step(); assert(w.writes==0)
    end
end)
test("写入抛错或静默无效时释放缓冲且不循环重试",function()
    for _,key in ipairs({"throw_set","noop_set"}) do
        local w,e,click,step,msg=harness(); w[key]=true
        click(ENTER); step(); assert(w.writes==1 and w.frees==1)
        assert(msg():find("操作失败")); step(); assert(w.writes==1)
    end
end)
test("分配失败不调用姿态写入",function()
    local w,e,click,step,msg=harness(); w.fail_alloc=true
    click(ENTER); step(); assert(w.writes==0 and w.frees==0 and msg():find("操作失败"))
end)
test("准备期间的新请求覆盖旧请求",function()
    local w,e,click,step=harness(); w.air=false
    click(ARM); step(); click(EXIT); w.air=true; step()
    assert(w.writes==0); step(100); assert(w.writes==0)
end)
local function rolled(degrees)
    local a=math.rad(180+degrees)*0.5
    return {0.0,math.sin(a),0.0,math.cos(a)}
end
local function bank_error(q)
    local _,u=axes(q)
    return math.acos(math.max(-1,math.min(1,-u[3])))
end
test("默认开启平衡，左右侧倾都回到倒立",function()
    for _,angle in ipairs({-60,60}) do
        local w,e,click,step=harness(true)
        click(ENTER); step(); step(); w.q=rolled(angle)
        for _=1,60 do step(16) end
        assert(bank_error(w.q)<math.rad(0.5))
        assert(w.allocs==1 and w.frees==0)
        assert(w.vel[2]==40 and w.ang[2]==0.2)
        e.on_stop(); assert(w.frees==1)
    end
end)
test("辅助纠偏保留当前航向俯仰",function()
    local w,e,click,step=harness(true)
    click(ENTER); step(); step()
    for i=1,100 do
        local q={math.sin(i)*0.3,math.cos(i)*0.7,math.sin(i*0.7)*0.3,0.7}
        local norm=0; for _,v in ipairs(q) do norm=norm+v*v end
        for j=1,4 do q[j]=q[j]/math.sqrt(norm) end
        w.q=q; local before=axes(q); step(16); local after=axes(w.q)
        for j=1,3 do close(before[j],after[j]) end
    end
    e.on_stop()
end)
test("转弯允许原生压弯，松开后恢复平衡",function()
    for _,key in ipairs({"steer","roll_input"}) do
        local w,e,click,step=harness(true)
        click(ENTER); step(); step(); w.q=rolled(30); w[key]=1
        local writes=w.writes
        for _=1,30 do step(16) end
        assert(w.writes==writes)
        w[key]=0
        for _=1,60 do step(16) end
        assert(bank_error(w.q)<math.rad(0.5)); e.on_stop()
    end
end)
test("30、60、144 FPS 对同一侧倾的收敛一致",function()
    local errors={}
    for _,fps in ipairs({30,60,144}) do
        local w,e,click,step=harness(true)
        click(ENTER); step(); step(); w.q=rolled(20)
        for _=1,fps/6 do step(1000/fps) end
        errors[#errors+1]=bank_error(w.q); e.on_stop()
    end
    close(errors[1],errors[2]); close(errors[2],errors[3])
end)
test("大侧翻逐渐纠正，单帧不超过角速度上限",function()
    local w,e,click,step=harness(true)
    click(ENTER); step(); step(); w.q=rolled(170)
    local before=bank_error(w.q); step(16)
    local delta=before-bank_error(w.q)
    assert(delta>0 and delta<=math.rad(240)*0.016+1e-6); e.on_stop()
end)
test("接近垂直时放开横滚，不发生轴跳变",function()
    local w,e,click,step,msg=harness(true)
    click(ENTER); step(); step(); w.q={math.sqrt(0.5),0,0,math.sqrt(0.5)}
    local writes=w.writes; step(16)
    assert(w.writes==writes and msg():find("垂直")); e.on_stop()
end)
test("停止、关闭开关、卸载均释放缓冲并停止写入",function()
    for _,action in ipairs({"button","checkbox","stop"}) do
        local w,e,click,step=harness(true)
        click(ENTER); step(); step(); w.q=rolled(20); step()
        local writes=w.writes
        if action=="button" then click("停止平衡辅助")
        elseif action=="checkbox" then w.check=false; e.on_menu_render(); w.check=nil
        else e.on_stop() end
        step(); step()
        assert(w.writes==writes and w.frees==1)
    end
end)
test("运行中换车、死亡、暂停、着地、失去控制权立即停止",function()
    for _,change in ipairs({
        function(w) w.veh=21 end,function(w) w.ptrs[20]=9999 end,
        function(w) w.driver=11 end,function(w) w.dead[10]=true end,
        function(w) w.paused=true end,function(w) w.faded=true end,
        function(w) w.air=false end,function(w) w.height=1 end,
        function(w) w.control=false end,
    }) do
        local w,e,click,step=harness(true)
        click(ENTER); step(); step(); w.q=rolled(30)
        local writes=w.writes; change(w); step()
        assert(w.writes==writes and w.frees==1)
    end
end)
test("已经倒飞可以直接接管平衡，翻正解除辅助",function()
    local w,e,click,step=harness(true); w.q=rolled(20)
    click(ENTER); step(); assert(w.writes==0)
    step(); step(); assert(w.writes==1)
    click(EXIT); step(); local calls=w.calls; local writes=w.writes
    for _=1,30 do step() end
    assert(w.calls==calls and w.writes==writes and w.frees==1)
end)
test("长帧与计时回绕不补做横滚",function()
    for _,delay in ipairs({500,-100}) do
        local w,e,click,step=harness(true)
        click(ENTER); step(); step(); w.q=rolled(30)
        local writes=w.writes; step(delay); assert(w.writes==writes)
        step(16); assert(w.writes==writes+1); e.on_stop()
    end
end)
test("运行中出参或输入异常停止辅助并释放缓冲",function()
    for _,change in ipairs({function(w) w.missing_output=true end,
                           function(w) w.steer=0/0 end}) do
        local w,e,click,step,msg=harness(true)
        click(ENTER); step(); step(); w.q=rolled(30); change(w)
        local writes=w.writes; step()
        assert(w.writes==writes and w.frees==1 and msg():find("操作失败"))
        step(); assert(w.writes==writes)
    end
end)
print(string.format("%d tests passed",n))
