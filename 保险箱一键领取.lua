-- StormPro 保险箱一键领取 v1.0 / GTA V Enhanced 1158.x
-- 索引核对：acidlabsdev/gtav-enhanced-scripts，commit 30dd0df8bce87bdc21103555bae380be9fc0a916
-- scripts/freemode.c (1158.13)。本机文件版本 1158.16，尚需游戏内验证。
-- 仅触发已有余额领取；不改余额、不填充保险箱、不循环刷取。
local SAFES = {
    {name = "夜总会", stat = "CLUB_SAFE_CASH_VALUE", trigger = 2708943},
    {name = "游戏厅", stat = "ARCADE_SAFE_CASH_VALUE", trigger = 2708952},
    {name = "事务所", stat = "FIXER_SAFE_CASH_VALUE", trigger = 2708961},
    {name = "废车场", stat = "SALVAGE_SAFE_CASH_VALUE", trigger = 2708970},
    {name = "保释办公室", stat = "BAIL_SAFE_CASH_VALUE", trigger = 2708979},
    {name = "制衣厂", stat = "HDEN24_SAFE_CASH_VALUE", trigger = 2708994},
    {name = "洗车房", stat = "CWASH_SAFE_CASH_VALUE", trigger = 2709001},
}
for _, row in ipairs(SAFES) do row.selected, row.status = true, "未刷新" end
local S = {pending = nil, job = nil, message = "进入线上自由模式后点击领取", stopped = false, busy = false,
    total = 0, confirmed = 0, skipped = 0, error = "", slot = nil}
local function integer(v)
    return type(v) == "number" and v == v and v >= 0 and v <= 2147483647 and v == math.floor(v)
end
local function money(v) return integer(v) and string.format("$%.0f", v) or "未知" end
local function safe_call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, result = pcall(fn, ...)
    if ok then return result end
end
local function log(message)
    S.message = message
    if Utils and Utils.Log then safe_call(Utils.Log, "[保险箱] " .. message) end
end
local function context()
    if not NETWORK or NETWORK.NETWORK_IS_SESSION_STARTED() ~= true then return nil, "当前不在线上战局" end
    local fm = script("freemode")
    if not fm or not fm:is_active() then return nil, "等待线上自由模式加载完成" end
    local thread = fm:get_script_thread()
    if type(thread) ~= "number" or thread == 0 then return nil, "无法识别自由模式线程" end
    local slot = safe_call(Stats.GetMPCharacterIndex)
    if slot ~= 0 and slot ~= 1 then slot = safe_call(Stats.get_int, "MPPLY_LAST_MP_CHAR") end
    if slot ~= 0 and slot ~= 1 then return nil, "无法识别当前角色" end
    return {slot = slot, thread = thread}
end
local function same_context(job)
    local current, reason = context()
    if not current then return false, reason end
    if current.slot ~= job.slot or current.thread ~= job.thread then return false, "角色或战局已变化" end
    return true
end
local function cash(row, slot)
    local value = Stats.get_int("MP" .. slot .. "_" .. row.stat)
    if not integer(value) then return nil end
    return value
end
local function balance(slot)
    if not MONEY then return nil end
    local wallet = safe_call(MONEY.NETWORK_GET_VC_WALLET_BALANCE, slot)
    local bank = safe_call(MONEY.NETWORK_GET_VC_BANK_BALANCE)
    if integer(wallet) and integer(bank) then return wallet + bank end
end
local function flags(row)
    local requested = globals.get_int(row.trigger)
    local processing = globals.get_int(row.trigger + 1)
    if (requested ~= 0 and requested ~= 1) or (processing ~= 0 and processing ~= 1) then
        error(row.name .. "领取标记异常，停止操作")
    end
    return requested, processing
end
local function release_unconsumed(job)
    -- 只撤回本次仍未被游戏消费的请求；不清理游戏自己的处理/完成标记。
    if not job or not job.current or not job.current.submitted then return end
    local ok, valid = pcall(same_context, job)
    if not ok or not valid then return end
    local row = job.current.row
    local read_ok, request, processing = pcall(flags, row)
    if read_ok and request == 1 and processing == 0 then safe_call(globals.set_bool, row.trigger, false) end
end
local function stop(reason)
    local job = S.job
    if job and job.current then job.current.row.status = reason end
    if job then
        for i = job.index, #job.list do
            if not job.current or job.list[i] ~= job.current.row then job.list[i].status = "未处理：本次已停止" end
        end
    end
    release_unconsumed(job)
    S.job, S.pending = nil, nil
    log(reason)
end
local function finish_item(job, now)
    job.current = nil
    job.index = job.index + 1
    job.next = now + (job.mode == "collect" and 1000 or 250)
end
local function start(mode, now)
    local ctx, reason = context()
    if not ctx then log(reason); return end
    local list = {}
    for _, row in ipairs(SAFES) do
        if mode == "refresh" or row.selected then list[#list + 1] = row; row.status = "等待处理" end
    end
    if #list == 0 then log("请至少勾选一项资产"); return end
    S.total, S.confirmed, S.skipped, S.error, S.slot = 0, 0, 0, "", ctx.slot
    S.job = {mode = mode, slot = ctx.slot, thread = ctx.thread, list = list, index = 1, next = now, last = now}
    log(mode == "collect" and "开始逐项领取已有收益" or "正在刷新余额")
end
local function step(now)
    local job = S.job
    if not job then return end
    if now < job.last then stop("游戏计时已重置，已停止后续操作"); return end
    job.last = now
    if now < job.next then return end
    job.next = now + 250
    local valid, reason = same_context(job)
    if not valid then stop(reason .. "，已停止后续操作"); return end
    local row = job.list[job.index]
    if not row then
        S.job = nil
        log(job.mode == "refresh" and "余额刷新完成" or string.format("本次完成：已确认 %d 项 / %s，跳过 %d 项", S.confirmed, money(S.total), S.skipped))
        return
    end
    local current = cash(row, job.slot)
    row.value = current
    if current == nil then stop(row.name .. "余额读取异常，停止后续操作"); return end
    if job.mode == "refresh" then
        row.status = current == 0 and "余额为0 / 未拥有" or "可领取"
        finish_item(job, now)
        return
    end
    if not job.current then
        if current == 0 then
            row.status = "跳过：余额为0 / 未拥有"
            S.skipped = S.skipped + 1
            finish_item(job, now)
            return
        end
        local requested, processing = flags(row)
        if requested == 1 or processing == 1 then
            row.status = "跳过：游戏已有领取请求"
            S.skipped = S.skipped + 1
            finish_item(job, now)
            return
        end
        -- 余额快照用于区分请求提交与实际结果。没有钱款读数也可请求，但不虚报到账。
        job.current = {row = row, before = current, balance = balance(job.slot), deadline = now + 12000, submitted = true}
        local result = globals.set_bool(row.trigger, true)
        if S.stopped then return end
        if result == false then stop(row.name .. "领取请求写入失败"); return end
        row.status = "请求已提交，等待到账"
        log("正在领取：" .. row.name .. " / " .. money(current))
        return
    end
    local request = job.current
    local requested, processing = flags(row)
    local after = balance(job.slot)
    local decrease = request.before - current
    if decrease > 0 and request.balance and after and after - request.balance >= decrease
        and requested == 0 and processing == 0 then
        row.status = "已确认领取 " .. money(decrease)
        S.total, S.confirmed = S.total + decrease, S.confirmed + 1
        log(row.name .. "：保险箱减少且余额增加 " .. money(decrease))
        finish_item(job, now)
    elseif now >= request.deadline then
        local detail = decrease > 0 and "保险箱金额已减少，但到账未确认" or "领取超时，未观察到收益到账"
        stop(row.name .. "：" .. detail .. "；已停止后续领取")
    else
        row.status = decrease > 0 and "金额已变化，等待余额同步" or "等待游戏处理领取请求"
    end
end
local function queue(mode)
    if not S.job and not S.pending then S.pending = mode end
end
function on_init() StormPro.RegisterMenu("保险箱一键领取") end
function on_menu_render()
    StormPro.TextColored("保险箱一键领取 v1.0", 0.35, 0.85, 1.0, 1.0)
    StormPro.Text("勾选资产后，一键领取已有收益。余额为0的项目自动跳过。")
    if StormPro.Button("一键领取勾选收益") then queue("collect") end
    StormPro.SameLine()
    if StormPro.Button("刷新全部余额") then queue("refresh") end
    if S.job or S.pending then
        if StormPro.Button("停止后续领取") then S.pending = "cancel" end
    end
    StormPro.Separator()
    for _, row in ipairs(SAFES) do
        row.selected = StormPro.Checkbox(row.name, row.selected)
        StormPro.SameLine()
        StormPro.Text(money(row.value) .. " | " .. row.status)
    end
    StormPro.Separator()
    StormPro.Text(S.message)
    StormPro.Text(string.format("当前角色：%s | 本次已确认 %s", S.slot == nil and "未知" or ("MP" .. S.slot), money(S.total)))
    StormPro.Text("一次只处理一项，最长等待12秒；重复点击不会叠加请求。")
    StormPro.Text("停止只取消后续项目，已由游戏接收的领取可能继续完成。")
    if S.error ~= "" then StormPro.Text("错误：" .. S.error) end
end
function on_tick()
    if S.stopped or S.busy or (not S.job and not S.pending) then return end
    S.busy = true
    local ok, err = pcall(function()
        if S.pending == "cancel" then stop("已停止后续操作；已接收的请求可能继续完成"); return end
        local now = MISC.GET_GAME_TIMER()
        assert(type(now) == "number" and now == now and now > -math.huge and now < math.huge, "游戏计时异常")
        if S.pending then
            local mode = S.pending
            S.pending = nil
            start(mode, now)
        end
        step(now)
    end)
    S.busy = false
    if not ok then S.error = tostring(err); stop("接口错误，已停止：" .. S.error) end
    if S.stopped then stop("脚本已卸载，停止后续领取") end
end
function on_stop()
    S.stopped = true
    if not S.busy then stop("脚本已卸载，停止后续领取") end
end
