-- Runtime bow parameter adjustments kept separate from BowAssist.lua.
-- This script changes the live Bow/UserData objects and restores their
-- original values when the script is disabled or the player changes weapon.

local MOD_NAME = "BowBalance"
local CONFIG_PATH = "BowBalance_config.json"
local BOW_RUNTIME_TYPE = 13

local FRAMES_PER_SECOND = 60
local STATIC_ACTION_BIT = 1073741824

-- These are the bow's release/follow-up motions observed in the 16.0.2.0
-- Motion list. The actual selection is made by the BowCreateShell action
-- marker below; the list is only a fallback for builds with renamed types.
local BOW_SHOT_MOTIONS = {
    [110] = true,
    [117] = true,
}

-- Verified by Bow_longerGP on the current Rise action table. These are the
-- rapid power-shot and rapid power-stun-shot Actions; their speed is exposed
-- through the managed set_Speed accessor, not the raw v5_Speed field.
local BOW_DIRECT_SPEED_ACTIONS = {
    { index = 9439, label = "刚连射" },
    { index = 9729, label = "刚连射（眩晕瓶）" },
}

-- These are the vanilla transition conditions used when chaining a power
-- shot after a normal or rapid shot.  They are StartFrame values, not motion
-- speeds: lowering them opens the input window earlier without accelerating
-- the animation itself.
local BOW_POWER_SHOT_TRANSITION_CONDITIONS = {
    { index = 7127, label = "刚射", default_frame = 42 },
    { index = 7263, label = "刚射（眩晕瓶）", default_frame = 42 },
    { index = 7139, label = "刚连射", default_frame = 48 },
    { index = 7275, label = "刚连射（眩晕瓶）", default_frame = 48 },
}

local defaults = {
    enabled = true,
    charge_rate_enabled = true,
    stamina_cost_enabled = true,
    buff_duration_enabled = true,
    range_enabled = true,
    critical_distance_enabled = true,
    arrow_speed_enabled = true,
    distance_damage_enabled = true,
    charge_level_3_rate = 1.5,
    charge_level_4_rate = 1.7,
    charge_level_1_enabled = false,
    charge_level_2_enabled = false,
    charge_level_1_rate = 1.0,
    charge_level_2_rate = 1.0,
    stamina_cost_multiplier = 0.5,
    arrow_speed_percent = 200,
    rapid_power_shot_speed_percent = 140,
    power_shot_window_enabled = true,
    power_shot_escape_frames = 42,
    rapid_power_shot_escape_frames = 48,
    arrow_buff_minutes = 30,
    wire_buff_minutes = 30,
    max_range = 100.0,
    critical_begin_percent = 75,
    critical_end_percent = 125,
    distance_damage_rate = 0.5,
    distance_damage_percent = 50,
}

local config = json.load_file(CONFIG_PATH)
if type(config) ~= "table" then config = {} end

-- Migrate the first diagnostic build's decimal settings to the clearer
-- integer-percent representation. Keep existing user choices when present.
if config.arrow_speed_percent == nil then
    local old_speed = tonumber(config.arrow_speed_multiplier)
    if old_speed ~= nil then
        -- The old float slider routinely serialized 2.00999999 for a
        -- requested 2.00x. Normalize values within 0.02 of an integer.
        local nearest_integer = math.floor(old_speed + 0.5)
        if math.abs(old_speed - nearest_integer) < 0.02 then old_speed = nearest_integer end
        config.arrow_speed_percent = math.floor(old_speed * 100 + 0.5)
    else
        config.arrow_speed_percent = defaults.arrow_speed_percent
    end
end
if config.critical_begin_percent == nil then
    local old_begin = tonumber(config.critical_begin_multiplier)
    config.critical_begin_percent = old_begin and math.floor(old_begin * 100 + 0.5)
        or defaults.critical_begin_percent
end
if config.critical_end_percent == nil then
    local old_end = tonumber(config.critical_end_multiplier)
    config.critical_end_percent = old_end and math.floor(old_end * 100 + 0.5)
        or defaults.critical_end_percent
end
if config.arrow_buff_minutes == nil then config.arrow_buff_minutes = defaults.arrow_buff_minutes end
if config.wire_buff_minutes == nil then config.wire_buff_minutes = defaults.wire_buff_minutes end
if config.distance_damage_rate == nil then config.distance_damage_rate = defaults.distance_damage_rate end
if config.distance_damage_percent == nil then
    config.distance_damage_percent = math.floor((tonumber(config.distance_damage_rate) or 0.5) * 100 + 0.5)
end
if config.charge_level_1_enabled == nil then config.charge_level_1_enabled = defaults.charge_level_1_enabled end
if config.charge_level_2_enabled == nil then config.charge_level_2_enabled = defaults.charge_level_2_enabled end
if config.charge_level_1_rate == nil then config.charge_level_1_rate = defaults.charge_level_1_rate end
if config.charge_level_2_rate == nil then config.charge_level_2_rate = defaults.charge_level_2_rate end
if config.rapid_power_shot_speed_percent == nil then
    local old_rapid_speed = tonumber(config.rapid_power_shot_speed)
    if old_rapid_speed ~= nil then
        config.rapid_power_shot_speed_percent = math.floor(old_rapid_speed * 100 + 0.5)
    else
        config.rapid_power_shot_speed_percent = defaults.rapid_power_shot_speed_percent
    end
end
if config.power_shot_window_enabled == nil then
    config.power_shot_window_enabled = defaults.power_shot_window_enabled
end
if config.power_shot_escape_frames == nil then
    config.power_shot_escape_frames = defaults.power_shot_escape_frames
end
if config.rapid_power_shot_escape_frames == nil then
    config.rapid_power_shot_escape_frames = defaults.rapid_power_shot_escape_frames
end
config.arrow_speed_multiplier = nil
config.rapid_power_shot_speed = nil
config.critical_begin_multiplier = nil
config.critical_end_multiplier = nil
for key, value in pairs(defaults) do
    if config[key] == nil then config[key] = value end
end

local function save_config()
    json.dump_file(CONFIG_PATH, config)
end

local function safe_call(object, method, ...)
    if object == nil then return nil end
    local args = { ... }
    local ok, result = pcall(function()
        return object:call(method, table.unpack(args))
    end)
    return ok and result or nil
end

-- REFramework exposes several Motion FSM/BHVT methods through its managed
-- object wrapper. They are callable as object:get_nodes(), while
-- object:call("get_nodes") may return nil even though the object is valid.
-- Prefer the wrapper form and retain :call as a compatibility fallback.
local function wrapper_call(object, method, ...)
    if object == nil then return nil end
    local args = { ... }
    local ok, result = pcall(function()
        return object[method](object, table.unpack(args))
    end)
    if ok and result ~= nil then return result end
    return safe_call(object, method, table.unpack(args))
end

local function safe_field(object, name)
    if object == nil then return nil end
    local ok, result = pcall(function() return object:get_field(name) end)
    return ok and result or nil
end

local function safe_set_field(object, name, value)
    if object == nil or value == nil then return false end
    return pcall(function() object:set_field(name, value) end)
end

local function get_tree_action(tree, raw_index)
    if tree == nil then return nil end
    local index = tonumber(raw_index)
    if index == nil then return nil end
    local actions = wrapper_call(tree, "get_actions")
    if actions ~= nil then
        local ok, action = pcall(function() return actions[index] end)
        if ok and action ~= nil then return action end
    end
    local ok, action = pcall(function() return tree:get_action(index) end)
    if ok and action ~= nil then return action end
    if index >= STATIC_ACTION_BIT then
        local data = safe_call(tree, "get_data")
        local static_actions = safe_call(data, "get_static_actions")
        if static_actions ~= nil then
            local ok_static, static_action = pcall(function()
                return static_actions[index - STATIC_ACTION_BIT]
            end)
            if ok_static then return static_action end
        end
    end
    return nil
end

local function get_tree_condition(tree, raw_index)
    if tree == nil then return nil end
    local index = tonumber(raw_index)
    if index == nil then return nil end
    local conditions = wrapper_call(tree, "get_conditions")
    if conditions ~= nil then
        local ok, condition = pcall(function() return conditions[index] end)
        if ok and condition ~= nil then return condition end
    end
    local ok, condition = pcall(function() return tree:get_condition(index) end)
    if ok and condition ~= nil then return condition end
    return nil
end

local function array_size(array)
    if array == nil then return 0 end
    local ok, size = pcall(function() return array:get_size() end)
    if ok and tonumber(size) ~= nil then return tonumber(size) end
    ok, size = pcall(function() return array:size() end)
    if ok and tonumber(size) ~= nil then return tonumber(size) end
    return 0
end

local function array_get(array, index)
    if array == nil then return nil end
    local ok, value = pcall(function() return array[index] end)
    return ok and tonumber(value) or nil
end

local function array_set(array, index, value)
    if array == nil or value == nil then return false end
    return pcall(function() array[index] = value end)
end

local function number_equal(left, right)
    return type(left) == "number" and type(right) == "number"
        and math.abs(left - right) < 0.0001
end

local function type_name(object)
    if object == nil then return "nil" end
    local ok, value = pcall(function() return object:get_type_definition():get_full_name() end)
    if ok and value ~= nil then return tostring(value) end
    return "unknown"
end

local runtime = {
    player_manager = nil,
    player = nil,
    weapon_type = -1,
    bow_data = nil,
    arrow_data = nil,
    arrow_count = 0,
    charge_array_size = 0,
    motion_tree = nil,
    motion_fsm_present = false,
    motion_layer_count = -1,
    motion_layer0_present = false,
    motion_tree_type = "nil",
    motion_tree_node_count = 0,
    motion_tree_action_count = 0,
    motion_tree_source = "未检测",
    behavior_tree = nil,
    motion_speed_candidates = {},
    motion_speed_target_count = 0,
    motion_speed_modified_count = 0,
    motion_speed_last_status = "未扫描",
    motion_speed_last_scan_frame = -1000,
    motion_speed_retry_counter = 0,
    motion_speed_direct_status = "未扫描",
    motion_speed_kind_status = "未扫描",
    power_shot_condition_target_count = 0,
    power_shot_condition_modified_count = 0,
    power_shot_condition_status = "未扫描",
    fields_applied = 0,
    array_values_applied = 0,
    last_status = "等待弓箭对象",
}

local motion_speed_originals = {}

-- Tables are keyed by the live managed objects.  This mirrors the existing
-- BowAssist action cache and lets us restore values across Tree reloads.
local originals = {}
local active_player = nil

local function cache_value(object, field)
    if object == nil then return nil end
    if originals[object] == nil then originals[object] = {} end
    if originals[object][field] == nil then
        originals[object][field] = safe_field(object, field)
    end
    return originals[object][field]
end

local function apply_scalar(object, field, target)
    if object == nil or target == nil then return false end
    local original = cache_value(object, field)
    if type(original) ~= "number" then return false end
    local current = tonumber(safe_field(object, field))
    if current == nil or not number_equal(current, target) then
        if safe_set_field(object, field, target) then
            runtime.fields_applied = runtime.fields_applied + 1
        end
    end
    return true
end

local function apply_array_value(array, index, target)
    if array == nil or target == nil then return false end
    if originals[array] == nil then originals[array] = {} end
    local cache_key = "index_" .. tostring(index)
    if originals[array][cache_key] == nil then
        originals[array][cache_key] = array_get(array, index)
    end
    local original = originals[array][cache_key]
    if type(original) ~= "number" then return false end
    local current = array_get(array, index)
    if current == nil or not number_equal(current, target) then
        if array_set(array, index, target) then
            runtime.array_values_applied = runtime.array_values_applied + 1
        end
    end
    return true
end

local function restore_all()
    for object, value in pairs(motion_speed_originals) do
        pcall(function() object:set_Speed(value) end)
        safe_set_field(object, "v5_Speed", value)
    end
    motion_speed_originals = {}
    for object, fields in pairs(originals) do
        for field, value in pairs(fields) do
            if field:sub(1, 6) == "index_" then
                local index = tonumber(field:sub(7))
                if index ~= nil then array_set(object, index, value) end
            else
                safe_set_field(object, field, value)
            end
        end
    end
    originals = {}
    runtime.fields_applied = 0
    runtime.array_values_applied = 0
    runtime.arrow_count = 0
    runtime.charge_array_size = 0
    runtime.motion_speed_candidates = {}
    runtime.motion_speed_target_count = 0
    runtime.motion_speed_modified_count = 0
    runtime.motion_speed_last_scan_frame = -1000
    runtime.motion_speed_retry_counter = 0
    runtime.motion_speed_direct_status = "未扫描"
    runtime.motion_speed_kind_status = "未扫描"
    runtime.power_shot_condition_target_count = 0
    runtime.power_shot_condition_modified_count = 0
    runtime.power_shot_condition_status = "未扫描"
end

local function apply_charge_rates(bow_data)
    if not config.charge_rate_enabled then return end
    local rates = safe_field(bow_data, "_ChargeAdjustAttackRate")
    local size = array_size(rates)
    runtime.charge_array_size = size
    if size <= 0 then return end

    -- The game's charge table is zero-based: indices 0..3 are charges 1..4.
    if size > 0 then
        apply_array_value(rates, 0, tonumber(config.charge_level_1_rate))
    end
    if size > 1 then
        apply_array_value(rates, 1, tonumber(config.charge_level_2_rate))
    end
    if size > 2 then apply_array_value(rates, 2, tonumber(config.charge_level_3_rate)) end
    if size > 3 then apply_array_value(rates, 3, tonumber(config.charge_level_4_rate)) end
end

local function minutes_to_frames(minutes)
    local value = math.max(0, math.min(30, tonumber(minutes) or 0))
    return value * 60 * FRAMES_PER_SECOND
end

local function apply_bow_data(bow_data)
    if bow_data == nil then return end
    if config.stamina_cost_enabled then
        local original = cache_value(bow_data, "_ChargingReduceStamina")
        if type(original) == "number" then
            apply_scalar(bow_data, "_ChargingReduceStamina",
                original * tonumber(config.stamina_cost_multiplier))
        end
    end
    if config.buff_duration_enabled then
        apply_scalar(bow_data, "_ArrowUpBufTime", minutes_to_frames(config.arrow_buff_minutes))
        apply_scalar(bow_data, "_WireBuffAttackUpTime", minutes_to_frames(config.wire_buff_minutes))
    end
    apply_charge_rates(bow_data)
end

local function adjusted_critical_begin(original)
    return math.max(0.0, original * (tonumber(config.critical_begin_percent) or 100) / 100)
end

local function adjusted_critical_end(original, begin_value, range_cap)
    local target = original * (tonumber(config.critical_end_percent) or 100) / 100
    target = math.max(target, begin_value + 1.0)
    return math.min(tonumber(range_cap) or target, target)
end

local function apply_arrow_data(arrow_data)
    if arrow_data == nil then return end
    runtime.arrow_count = runtime.arrow_count + 1

    if config.range_enabled then
        apply_scalar(arrow_data, "_MaxRange", tonumber(config.max_range))
    end

    if config.critical_distance_enabled then
        local range_cap = tonumber(safe_field(arrow_data, "_MaxRange"))
        local begin_original = cache_value(arrow_data, "_CriticalBeginRange")
        local end_original = cache_value(arrow_data, "_CriticalEndRange")
        if type(begin_original) == "number" and type(end_original) == "number" then
            local begin_target = adjusted_critical_begin(begin_original)
            local end_target = adjusted_critical_end(end_original, begin_target, range_cap)
            apply_scalar(arrow_data, "_CriticalBeginRange", begin_target)
            apply_scalar(arrow_data, "_CriticalEndRange", end_target)
        end

        local upper_begin_original = cache_value(arrow_data, "_UpperCriticalBeginRange")
        local upper_end_original = cache_value(arrow_data, "_UpperCriticalEndRange")
        if type(upper_begin_original) == "number" and type(upper_end_original) == "number" then
            local begin_target = adjusted_critical_begin(upper_begin_original)
            local end_target = adjusted_critical_end(upper_end_original, begin_target, range_cap)
            apply_scalar(arrow_data, "_UpperCriticalBeginRange", begin_target)
            apply_scalar(arrow_data, "_UpperCriticalEndRange", end_target)
        end
    end
    if config.distance_damage_enabled then
        local damage_rate = math.max(0.0, math.min(1.0, tonumber(config.distance_damage_rate) or 0.5))
        apply_scalar(arrow_data, "_BeforeRangeAttackRate", damage_rate)
        apply_scalar(arrow_data, "_AfterRangeAttackRate", damage_rate)
    end
end

local function is_play_motion_action(action)
    local name = type_name(action)
    return name:find("PlayerPlayMotion2", 1, true) ~= nil
        or name:find("Fsm2ActionPlayMotion", 1, true) ~= nil
end

-- Return the exact shot family represented by a BowCreateShell action.
-- Keeping this whitelist narrow is important: the same node can also contain
-- aim, sheath, bottle and transition motions that must retain vanilla speed.
local function bow_shot_kind(action)
    local name = type_name(action)
    if name:find("BowCreateShellRapidPowerStun", 1, true) ~= nil then
        return "刚连射绝"
    end
    if name:find("BowCreateShellRapidPower", 1, true) ~= nil then
        return "刚连射"
    end
    if name:find("BowCreateShellPowerStun", 1, true) ~= nil then
        return "刚射绝"
    end
    if name:find("BowCreateShellPower", 1, true) ~= nil then
        return "刚射"
    end
    if name:find("BowCreateShellNormal", 1, true) ~= nil then
        return "普通射击"
    end
    if name:find("BowCreateShellBelow1st", 1, true) ~= nil
        or name:find("BowCreateShellBelow2nd", 1, true) ~= nil
        or name:find("BowCreateShellBelow3rd", 1, true) ~= nil then
        return "蓄力射击"
    end
    return nil
end

local function is_rapid_power_shot_kind(kind)
    return kind == "刚连射" or kind == "刚连射绝"
end

local function read_action_speed(action)
    if action == nil then return nil end
    local speed = safe_call(action, "get_Speed")
    if type(speed) == "number" then return speed end
    speed = safe_field(action, "v5_Speed")
    if type(speed) == "number" then return speed end
    return nil
end

local function write_action_speed(action, value)
    if action == nil or type(value) ~= "number" then return false end
    -- Bow_longerGP uses this managed accessor successfully. Keep the raw
    -- field as a compatibility fallback for builds that expose it directly.
    local ok = pcall(function() action:set_Speed(value) end)
    if ok then return true end
    ok = pcall(function() action:call("set_Speed", value) end)
    if ok then return true end
    return safe_set_field(action, "v5_Speed", value)
end

local function is_rapid_power_shot_action(action_index)
    local index = tonumber(action_index)
    return index == 9439 or index == 9729
end

local function collect_motion_speed_target(action, action_index, label, targets, shot_kind)
    if action == nil then return end
    local speed = read_action_speed(action)
    if type(speed) ~= "number" or speed <= 0 then return end
    if motion_speed_originals[action] == nil then
        motion_speed_originals[action] = speed
    end
    targets[action] = {
        action_index = action_index,
        label = label,
        shot_kind = shot_kind or label,
        rapid_power_shot = is_rapid_power_shot_kind(shot_kind)
            or is_rapid_power_shot_action(action_index),
        original_speed = motion_speed_originals[action],
    }
end

local function scan_motion_speed_actions()
    runtime.motion_speed_candidates = {}
    runtime.motion_speed_target_count = 0
    runtime.motion_speed_modified_count = 0
    runtime.motion_speed_last_status = "等待弓射击动作"
    runtime.motion_speed_direct_status = "未扫描"
    runtime.motion_speed_kind_status = "未扫描"
    local scan_tree = runtime.motion_tree
    if scan_tree == nil then
        runtime.motion_speed_last_status = "未取得 Motion FSM 动作树"
        return
    end

    local targets = {}
    local kind_counts = {}

    -- Direct targets from the known working mod. This path is independent of
    -- node ordering and is the primary route for rapid power-shot speed.
    local direct_found = 0
    for _, spec in ipairs(BOW_DIRECT_SPEED_ACTIONS) do
        local action = get_tree_action(scan_tree, spec.index)
        if action ~= nil then
            local before = read_action_speed(action)
            collect_motion_speed_target(action, spec.index, spec.label, targets, "刚连射")
            if before ~= nil then
                direct_found = direct_found + 1
                kind_counts["刚连射"] = (kind_counts["刚连射"] or 0) + 1
            end
        end
    end
    runtime.motion_speed_direct_status = string.format("直接 Action 9439/9729：找到 %d/2", direct_found)

    local nodes = wrapper_call(scan_tree, "get_nodes")
    local node_count = array_size(nodes)
    if node_count <= 0 then
        runtime.motion_speed_last_status = "动作树为空"
        return
    end

    local matched_nodes = 0
    for node_index = 0, node_count - 1 do
        local node = nil
        local ok_node, value = pcall(function() return nodes[node_index] end)
        if ok_node then node = value end
        local data = wrapper_call(node, "get_data")
        local actions = wrapper_call(data, "get_actions")
        local action_count = array_size(actions)
        if action_count > 0 then
            local shot_kind = nil
            local node_actions = {}
            for slot = 0, action_count - 1 do
                local raw_index = nil
                local ok_index, index_value = pcall(function() return actions[slot] end)
                if ok_index then raw_index = tonumber(index_value) end
                local action = get_tree_action(scan_tree, raw_index)
                node_actions[#node_actions + 1] = { index = raw_index, object = action }
                local marker_kind = bow_shot_kind(action)
                if marker_kind ~= nil then shot_kind = marker_kind end
            end
            if shot_kind ~= nil then
                matched_nodes = matched_nodes + 1
                kind_counts[shot_kind] = (kind_counts[shot_kind] or 0) + 1
                for _, entry in ipairs(node_actions) do
                    local action = entry.object
                    if is_play_motion_action(action) then
                        local speed = read_action_speed(action)
                        local mot_id = tonumber(safe_field(action, "_weaponMotID"))
                        local bank_id = tonumber(safe_field(action, "_weaponBankID"))
                        -- The whitelisted BowCreateShell marker is the
                        -- authoritative selector. Do not touch sibling nodes
                        -- containing only movement, aiming or utility actions.
                        if type(speed) == "number" and speed > 0 then
                            if motion_speed_originals[action] == nil then
                                motion_speed_originals[action] = speed
                            end
                            targets[action] = {
                                action_index = entry.index,
                                motion_id = mot_id,
                                shot_kind = shot_kind,
                                rapid_power_shot = is_rapid_power_shot_kind(shot_kind)
                                    or is_rapid_power_shot_action(entry.index),
                                original_speed = motion_speed_originals[action] or speed,
                            }
                        end
                    end
                end
            end
        end
    end
    local kind_order = { "普通射击", "蓄力射击", "刚射", "刚连射", "刚射绝", "刚连射绝" }
    local kind_summary = {}
    for _, kind in ipairs(kind_order) do
        if kind_counts[kind] ~= nil then
            kind_summary[#kind_summary + 1] = kind .. "节点 " .. tostring(kind_counts[kind])
        end
    end
    runtime.motion_speed_kind_status = #kind_summary > 0
        and table.concat(kind_summary, "；") or "未找到白名单射击节点"

    for action, target in pairs(targets) do
        local original = target.original_speed
        if type(original) == "number" then
            local speed_percent = target.rapid_power_shot
                and tonumber(config.rapid_power_shot_speed_percent)
                or tonumber(config.arrow_speed_percent)
            local multiplier = math.max(0.5, math.min(4.0,
                (speed_percent or 100) / 100))
            local target_speed = original * multiplier
            local current = read_action_speed(action)
            if current == nil or not number_equal(current, target_speed) then
                if write_action_speed(action, target_speed) then
                    runtime.motion_speed_modified_count = runtime.motion_speed_modified_count + 1
                end
            end
            runtime.motion_speed_candidates[action] = target
            runtime.motion_speed_target_count = runtime.motion_speed_target_count + 1
        end
    end
    if runtime.motion_speed_target_count > 0 then
        runtime.motion_speed_last_status = string.format(
            "已找到弓射击动作 %d 个，已写入 %d 个（set_Speed）",
            runtime.motion_speed_target_count, runtime.motion_speed_modified_count)
    elseif matched_nodes > 0 then
        runtime.motion_speed_last_status = "已找到弓箭创建节点，但未找到可写射击速度"
    else
        runtime.motion_speed_last_status = "未找到弓箭创建节点，保持原版速度"
    end
end

local function apply_power_shot_windows()
    runtime.power_shot_condition_target_count = 0
    runtime.power_shot_condition_modified_count = 0
    runtime.power_shot_condition_status = "刚射派生窗口已关闭"
    if not config.power_shot_window_enabled then return end
    local tree = runtime.motion_tree
    if tree == nil then
        runtime.power_shot_condition_status = "未取得 Motion FSM 条件树"
        return
    end

    for _, spec in ipairs(BOW_POWER_SHOT_TRANSITION_CONDITIONS) do
        local condition = get_tree_condition(tree, spec.index)
        local target_frame
        if spec.index == 7139 or spec.index == 7275 then
            target_frame = tonumber(config.rapid_power_shot_escape_frames)
        else
            target_frame = tonumber(config.power_shot_escape_frames)
        end
        target_frame = math.max(0, math.min(180, target_frame or spec.default_frame))
        if condition ~= nil then
            local original = cache_value(condition, "StartFrame")
            local current = tonumber(safe_field(condition, "StartFrame"))
            if type(original) == "number" then
                runtime.power_shot_condition_target_count =
                    runtime.power_shot_condition_target_count + 1
                if current == nil or not number_equal(current, target_frame) then
                    if safe_set_field(condition, "StartFrame", target_frame) then
                        runtime.power_shot_condition_modified_count =
                            runtime.power_shot_condition_modified_count + 1
                    end
                end
            end
        end
    end

    if runtime.power_shot_condition_target_count > 0 then
        runtime.power_shot_condition_status = string.format(
            "刚射派生窗口：找到 %d/4，已写入 %d（普通 %d 帧 / 刚连射 %d 帧）",
            runtime.power_shot_condition_target_count,
            runtime.power_shot_condition_modified_count,
            tonumber(config.power_shot_escape_frames) or 42,
            tonumber(config.rapid_power_shot_escape_frames) or 48)
    else
        runtime.power_shot_condition_status = "未找到刚射派生条件，保持原版窗口"
    end
end

local function refresh_motion_trees(player)
    local game_object = safe_call(player, "get_GameObject")
    local behavior_tree = safe_call(game_object, "getComponent(System.Type)",
        sdk.typeof("via.behaviortree.BehaviorTree"))
    local motion_fsm = safe_call(game_object, "getComponent(System.Type)",
        sdk.typeof("via.motion.MotionFsm2"))
    runtime.motion_fsm_present = motion_fsm ~= nil
    runtime.motion_layer_count = tonumber(safe_call(motion_fsm, "getLayerCount")) or -1

    -- get_tree_object is exposed by REFramework's managed-object wrapper,
    -- rather than as a normal reflected method. Calling it through
    -- object:call(...) silently returns nil on current Rise builds.
    local motion_layer = safe_call(motion_fsm, "getLayer", 0)
    runtime.motion_layer0_present = motion_layer ~= nil
    local motion_tree = nil
    if motion_layer ~= nil then
        local ok_tree, value = pcall(function() return motion_layer:get_tree_object() end)
        if ok_tree then motion_tree = value end
        if motion_tree == nil then
            motion_tree = safe_call(motion_layer, "get_tree_object")
        end
    end

    -- Some builds expose the same layer from Player.getMotionLayer even when
    -- the component getter is not ready during the first frames of a quest.
    if motion_tree == nil then
        local player_layer = safe_call(player, "getMotionLayer", 0)
        if player_layer ~= nil then
            runtime.motion_layer0_present = true
            local ok_tree, value = pcall(function() return player_layer:get_tree_object() end)
            if ok_tree then motion_tree = value end
            if motion_tree ~= nil then runtime.motion_tree_source = "Player:getMotionLayer(0)" end
        end
    else
        runtime.motion_tree_source = "MotionFsm2:getLayer(0)"
    end

    if motion_tree ~= nil then
        runtime.motion_tree_type = type_name(motion_tree)
        runtime.motion_tree_node_count = array_size(wrapper_call(motion_tree, "get_nodes"))
        runtime.motion_tree_action_count = array_size(wrapper_call(motion_tree, "get_actions"))
    else
        runtime.motion_tree_type = "nil"
        runtime.motion_tree_node_count = 0
        runtime.motion_tree_action_count = 0
        if not runtime.motion_fsm_present then
            runtime.motion_tree_source = "未取得 MotionFsm2 组件"
        elseif not runtime.motion_layer0_present then
            runtime.motion_tree_source = "MotionFsm2 没有 Layer 0"
        else
            runtime.motion_tree_source = "Layer 0 尚未生成 tree_object"
        end
    end
    if behavior_tree ~= runtime.behavior_tree or motion_tree ~= runtime.motion_tree then
        if runtime.behavior_tree ~= nil or runtime.motion_tree ~= nil then restore_all() end
        runtime.behavior_tree = behavior_tree
        runtime.motion_tree = motion_tree
        runtime.motion_speed_last_scan_frame = -1000
    end
end

local function apply_parameters(player)
    refresh_motion_trees(player)
    apply_power_shot_windows()
    local bow_data = safe_field(player, "_PlayerUserDataBow")
    local arrows = safe_field(player, "_PlayerUserDataArrow")
    if bow_data == nil then
        runtime.last_status = "未取得 PlayerUserDataBow"
        return
    end
    if bow_data ~= runtime.bow_data or arrows ~= runtime.arrow_data then
        if runtime.bow_data ~= nil or runtime.arrow_data ~= nil then restore_all() end
        runtime.bow_data = bow_data
        runtime.arrow_data = arrows
    end

    apply_bow_data(bow_data)
    local size = array_size(arrows)
    runtime.arrow_count = 0
    for index = 0, size - 1 do
        local ok, arrow_data = pcall(function() return arrows[index] end)
        if ok then apply_arrow_data(arrow_data) end
    end
    if config.arrow_speed_enabled then
        runtime.motion_speed_retry_counter = runtime.motion_speed_retry_counter + 1
        if runtime.motion_speed_last_scan_frame < 0
            or (runtime.motion_speed_target_count == 0
                and runtime.motion_speed_retry_counter >= 120) then
            scan_motion_speed_actions()
            runtime.motion_speed_last_scan_frame = 0
            runtime.motion_speed_retry_counter = 0
        end
    else
        runtime.motion_speed_last_status = "射击动作速度已关闭"
    end
    runtime.last_status = string.format(
        "已应用：弓字段 %d；数组值 %d；箭对象 %d；蓄力表 %d 项；射击动作 %d/%d",
        runtime.fields_applied, runtime.array_values_applied,
        runtime.arrow_count, runtime.charge_array_size,
        runtime.motion_speed_target_count, runtime.motion_speed_modified_count)
end

local function refresh_player()
    if runtime.player_manager == nil then
        runtime.player_manager = sdk.get_managed_singleton("snow.player.PlayerManager")
    end
    if runtime.player_manager == nil then return nil end
    local player = safe_call(runtime.player_manager, "findMasterPlayer")
    if player == nil then return nil end
    runtime.player = player
    runtime.weapon_type = tonumber(safe_field(player, "_playerWeaponType")) or -1
    return player
end

local function checkbox(label, key)
    local changed, value = imgui.checkbox(label, config[key])
    if changed then
        config[key] = value
        -- Revert first so the next frame recalculates every enabled field
        -- from the real original values, including when a sub-feature is
        -- switched off individually.
        restore_all()
        save_config()
    end
end

local function slider_float(label, key, min_value, max_value, format)
    local changed, value = imgui.slider_float(label, config[key], min_value, max_value, format)
    if changed then
        config[key] = value
        restore_all()
        save_config()
    end
end

local function slider_int(label, key, min_value, max_value)
    local current = math.floor(tonumber(config[key]) or min_value)
    local changed, value = imgui.slider_int(label, current, min_value, max_value)
    if changed then
        config[key] = value
        restore_all()
        save_config()
    end
end

local function slider_rate(label, key, min_value, max_value)
    local current = tonumber(config[key]) or min_value
    local changed, value = imgui.slider_float(label, current, min_value, max_value, "%.2fx")
    if changed then
        config[key] = math.floor(value * 100 + 0.5) / 100
        restore_all()
        save_config()
    end
end

re.on_frame(function()
    local player = refresh_player()
    if player == nil then return end
    if player ~= active_player then
        if active_player ~= nil then restore_all() end
        active_player = player
        runtime.bow_data = nil
        runtime.arrow_data = nil
    end
    if not config.enabled or runtime.weapon_type ~= BOW_RUNTIME_TYPE then
        if runtime.bow_data ~= nil or runtime.arrow_data ~= nil then restore_all() end
        runtime.last_status = runtime.weapon_type == BOW_RUNTIME_TYPE
            and "功能已关闭" or "当前不是弓箭（运行时类型需为 13）"
        return
    end
    apply_parameters(player)
end)

re.on_draw_ui(function()
    if not imgui.tree_node("弓箭参数增强") then return end
    checkbox("启用参数增强", "enabled")
    checkbox("蓄力倍率修改", "charge_rate_enabled")
    checkbox("蓄力耐力消耗减半", "stamina_cost_enabled")
    checkbox("箭强化与刚力挽弓时长", "buff_duration_enabled")
    checkbox("最大射程", "range_enabled")
    checkbox("会心距离", "critical_distance_enabled")
    checkbox("射击动作速度", "arrow_speed_enabled")
    checkbox("刚射派生窗口", "power_shot_window_enabled")
    checkbox("距离减伤倍率", "distance_damage_enabled")
    slider_rate("一蓄倍率（默认原版）", "charge_level_1_rate", 0.5, 3.0)
    slider_rate("二蓄倍率（默认原版）", "charge_level_2_rate", 0.5, 3.0)
    slider_rate("三蓄倍率", "charge_level_3_rate", 1.0, 3.0)
    slider_rate("四蓄倍率", "charge_level_4_rate", 1.0, 3.0)
    slider_int("普通射击动作速度（百分比）", "arrow_speed_percent", 50, 400)
    slider_int("刚连射动作速度（百分比）", "rapid_power_shot_speed_percent", 50, 400)
    slider_int("普通刚射派生帧", "power_shot_escape_frames", 0, 120)
    slider_int("刚连射派生帧", "rapid_power_shot_escape_frames", 0, 120)
    slider_int("箭强化时间（分钟）", "arrow_buff_minutes", 0, 30)
    slider_int("刚力挽弓时间（分钟）", "wire_buff_minutes", 0, 30)
    slider_float("最大射程", "max_range", 10.0, 200.0, "%.1f")
    slider_int("会心起始距离（原距离百分比）", "critical_begin_percent", 10, 100)
    slider_int("会心结束距离（原距离百分比）", "critical_end_percent", 100, 300)
    slider_int("距离减伤（百分比）", "distance_damage_percent", 0, 100)
    local distance_rate = (tonumber(config.distance_damage_percent) or 50) / 100
    if not number_equal(tonumber(config.distance_damage_rate), distance_rate) then
        config.distance_damage_rate = distance_rate
        save_config()
    end
    if imgui.button("恢复原版参数") then restore_all() end
    imgui.tree_pop()
end)

re.on_config_save(function() save_config() end)

save_config()
log.info("[" .. MOD_NAME .. "] loaded. Runtime bow parameter adjustments are active.")
