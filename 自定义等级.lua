-- ============================================================
-- 自定义等级修改 (RP_GIFT_ADMIN 注入)
-- 适配 StormPro Lua API (动态算法免 8000 行长表)
-- ============================================================

local LevelState = {
    target_level = "120" -- 默认显示的输入值
}

local function show_msg(msg)
    StormPro.ShowNotification("[等级修改] " .. msg)
end

-- ============================================================
-- [核心算法] 完美还原 GTA5 RP 经验值计算公式
-- ============================================================
-- 1 - 99 级基础经验数组
local rp_base_array = {
    0, 800, 2100, 3800, 6100, 9500, 12500, 16000, 19800, 24000,
    28500, 33400, 38700, 44200, 50200, 56400, 63000, 69900, 77100, 84700,
    92500, 100700, 109200, 118000, 127100, 136500, 146200, 156200, 166500, 177100,
    188000, 199200, 210700, 222400, 234500, 246800, 259400, 272300, 285500, 299000,
    312700, 326800, 341000, 355600, 370500, 385600, 401000, 416600, 432600, 448800,
    465200, 482000, 499000, 516300, 533800, 551600, 569600, 588000, 606500, 625400,
    644500, 663800, 683400, 703300, 723400, 743800, 764500, 785400, 806500, 827900,
    849600, 871500, 893600, 916000, 938700, 961600, 984700, 1008100, 1031800, 1055700,
    1079800, 1104200, 1128800, 1153700, 1178800, 1204200, 1229800, 1255600, 1281700, 1308100,
    1334600, 1361400, 1388500, 1415800, 1443300, 1471100, 1499100, 1527300, 1555800
}

local function calc_rp_for_level(level)
    if level <= 1 then return 0 end

    -- 1 到 99 级，直接读取基础表
    if level <= 99 then
        return rp_base_array[level]
    end

    -- 100 级以上使用等差推导公式计算
    -- L100 经验: 1584350，增量 28550
    local current_rp = rp_base_array[99]
    for i = 100, level do
        current_rp = current_rp + 28500 + (i - 99) * 50
    end

    return current_rp
end

-- ============================================================
-- [生命周期]
-- ============================================================
function on_init()
    StormPro.RegisterMenu("等级修改")
    show_msg("动态等级推算模块已加载！")
end

function on_menu_render()
    StormPro.TextColored("线上角色等级自定义 (1 - 8000级)", 1.0, 0.8, 0.0, 1.0)
    StormPro.Separator()
    StormPro.Spacing()

    -- 接收输入的等级
    local input_val, input_chg = StormPro.InputText("输入目标等级:", LevelState.target_level, 5)
    if input_chg then
        LevelState.target_level = input_val
    end

    StormPro.Spacing()

    if StormPro.Button("写入角色数据") then
        local target_lvl = tonumber(LevelState.target_level)

        -- 参数校验
        if target_lvl and target_lvl >= 1 and target_lvl <= 8000 then
            -- 1. 瞬间计算出目标经验值
            local target_rp = calc_rp_for_level(target_lvl)

            -- 2. 通过 Stats API 写入 MP0 和 MP1 角色槽位，兼容双角色
            if Stats and Stats.set_int then
                Stats.set_int("MPX_CHAR_SET_RP_GIFT_ADMIN", target_rp)
                show_msg(string.format("已将 %d 级经验 (RP: %d) 写入缓存。\n请切换战局以生效！", target_lvl, target_rp))
            else
                show_msg("写入失败：未检测到 Stats 接口环境！")
            end
        else
            show_msg("错误拦截：请输入 1 到 8000 之间的有效数字！")
        end
    end

    StormPro.Spacing()
    StormPro.Separator()
    StormPro.TextDisabled("【操作流程】")
    StormPro.TextDisabled("1. 输入你想要的等级数字。")
    StormPro.TextDisabled("2. 点击[写入角色数据]。")
    StormPro.TextDisabled("3. 打开菜单 寻找新战局/切换战局。")
    StormPro.TextDisabled("4. 落地后即可看到左上角等级提示改变。")
end