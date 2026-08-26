local MOD_NAME = "LongSwordAssist"
local CONFIG_PATH = "LongSwordAssist_config.json"
local TRANSITION_PROBE_PATH = "LongSwordAssist_transition_probe.json"

local WEAPON_LONG_SWORD = 2
local FORESIGHT_TARGET_STATE = 295

local NODE_AUTO_IAI_ENTRY = 3716128725
local NODE_IAI_SUCCESS = 2004603551
local NODE_FORESIGHT_ENTRY = 532382550
local NODE_FORESIGHT_ACTIVE = 1265650183
local NODE_FORESIGHT_SUCCESS = 3993670187
local ACTION_FORESIGHT_COUNTER = 9124

local IAI_BASE_COUNTER_END = 8.0
local FORESIGHT_BASE_COUNTER_END = 30.0

local defaults = {
    enabled = true,
    auto_iai = false,
    auto_foresight = false,
    manual_iai_extension = true,
    manual_foresight_extension = true,
    multiplayer_compat = true,
    auto_detect_multiplayer = true,
    total_direction_arc = 120,
    iai_pre_frames = 6,
    iai_post_frames = 16,
    foresight_pre_frames = 6,
    foresight_post_frames = 12,
    auto_foresight_success_delay = 2,
    diagnostics = false,
}

local function merge_defaults(value)
    if type(value) ~= "table" then value = {} end
    for key, default_value in pairs(defaults) do
        if value[key] == nil then value[key] = default_value end
    end
    return value
end

local config = merge_defaults(json.load_file(CONFIG_PATH))

local function save_config()
    json.dump_file(CONFIG_PATH, config)
end

local function safe_call(object, method, ...)
    if object == nil then return nil end
    local arguments = { ... }
    local ok, result = pcall(function()
        return object:call(method, table.unpack(arguments))
    end)
    if ok then return result end
    return nil
end

local function safe_field(object, name)
    if object == nil then return nil end
    local ok, result = pcall(function() return object:get_field(name) end)
    if ok then return result end
    return nil
end

local function safe_set_field(object, name, value)
    if object == nil then return false end
    return pcall(function() object:set_field(name, value) end)
end

local function managed_argument(value)
    local ok, result = pcall(function() return sdk.to_managed_object(value) end)
    if ok then return result end
    return nil
end

local function type_name(object)
    if object == nil then return "nil" end
    local ok, result = pcall(function()
        return object:get_type_definition():get_full_name()
    end)
    if ok and result ~= nil then return tostring(result) end
    return tostring(object)
end


local function container_elements(container)
    if container == nil then return {} end
    if type(container) == "table" then return container end
    local ok, elements = pcall(function() return container:get_elements() end)
    if ok and type(elements) == "table" then return elements end
    local result = {}
    pcall(function()
        for index = 0, container:size() - 1 do table.insert(result, container[index]) end
    end)
    return result
end

local function probe_value(value)
    local kind = type(value)
    if value == nil or kind == "number" or kind == "boolean" or kind == "string" then return value end
    return tostring(value)
end

local function snapshot_transition_object(object)
    local result = { type = type_name(object), fields = {}, getters = {}, methods = {} }
    if object == nil then return result end
    local current = object:get_type_definition()
    local depth = 0
    while current ~= nil and depth < 6 do
        for _, field in ipairs(container_elements(current:get_fields())) do
            local ok, value = pcall(function() return field:get_data(object) end)
            if ok then result.fields[field:get_name()] = probe_value(value) end
        end
        for _, method in ipairs(container_elements(current:get_methods())) do
            local name = method:get_name()
            if name:find("Transition") or name:find("Selector") or name:find("Exit")
                or name:find("Frame") or name:find("State") or name:find("Condition") then
                result.methods[name] = method:get_num_params()
                if method:get_num_params() == 0 and name:find("get_") == 1 then
                    local ok, value = pcall(function() return method:call(object) end)
                    if ok then result.getters[name] = probe_value(value) end
                end
            end
        end
        current = current:get_parent_type()
        depth = depth + 1
    end
    return result
end

local runtime = {
    player_manager = nil,
    master_player = nil,
    master_index = nil,
    game_object = nil,
    motion_control = nil,
    behavior_tree = nil,
    motion_tree = nil,
    motion_tree_key = nil,
    weapon_type = -1,
    bank_id = -1,
    motion_id = -1,
    node_id = "0",
    motion_frame = 0.0,
    source_angle = nil,
    source_name = "",
    foresight_window_extended = false,
    multiplayer = false,
    foresight_legal = false,
    nodes_ready = false,
    iai_entry_ready = false,
    cooldown = 0,
    pending_foresight = 0,
    pending_foresight_age = 0,
    player_quest_base = nil,
    reflex_object = nil,
    reflex_original_end = nil,
    reflex_action = nil,
    foresight_counter_object = nil,
    foresight_counter_original_end = nil,
    foresight_counter_value = FORESIGHT_BASE_COUNTER_END,
    foresight_counter_ready = false,
    transition_probe_done = false,
    last_trigger = "none",
    last_request = "无",
    last_request_node = 0,
    last_request_result = false,
    last_damage_flow = -1,
    foresight_legal_grace = 0,
    last_event_motion = -1,
    last_foresight_hit_frame = -1.0,
    last_event_legal = false,
    last_reject_reason = "无",
}

local condition_originals = {}
local foresight_entry_conditions = {}
local foresight_window_conditions = {}
local iai_conditions = {}
local scan_index = 0
local scan_complete = false

local function object_position(game_object)
    local transform = safe_call(game_object, "get_Transform")
    return safe_call(transform, "get_Position")
end

local function object_rotation(game_object)
    local transform = safe_call(game_object, "get_Transform")
    return safe_call(transform, "get_Rotation")
end

local function quaternion_forward(rotation)
    if rotation == nil then return nil end
    local ok, result = pcall(function()
        local x, y, z, w = rotation.x, rotation.y, rotation.z, rotation.w
        return {
            x = 2.0 * (x * z + w * y),
            z = 1.0 - 2.0 * (x * x + y * y),
        }
    end)
    if ok then return result end
    return nil
end

local function signed_source_angle(player_position, player_forward, source_position)
    if player_position == nil or player_forward == nil or source_position == nil then return nil end
    local dx = source_position.x - player_position.x
    local dz = source_position.z - player_position.z
    local source_length = math.sqrt(dx * dx + dz * dz)
    local forward_length = math.sqrt(player_forward.x * player_forward.x + player_forward.z * player_forward.z)
    if source_length < 0.0001 or forward_length < 0.0001 then return nil end

    dx, dz = dx / source_length, dz / source_length
    local fx, fz = player_forward.x / forward_length, player_forward.z / forward_length
    local dot = math.max(-1.0, math.min(1.0, fx * dx + fz * dz))
    local cross = fx * dz - fz * dx
    local angle = math.deg(math.acos(dot))
    if cross < 0 then angle = -angle end
    return angle
end

local function signed_direction_angle(player_forward, direction)
    if player_forward == nil or direction == nil then return nil end
    local dx, dz = -direction.x, -direction.z
    local direction_length = math.sqrt(dx * dx + dz * dz)
    local forward_length = math.sqrt(player_forward.x * player_forward.x + player_forward.z * player_forward.z)
    if direction_length < 0.0001 or forward_length < 0.0001 then return nil end
    dx, dz = dx / direction_length, dz / direction_length
    local fx, fz = player_forward.x / forward_length, player_forward.z / forward_length
    local dot = math.max(-1.0, math.min(1.0, fx * dx + fz * dz))
    local cross = fx * dz - fz * dx
    local angle = math.deg(math.acos(dot))
    if cross < 0 then angle = -angle end
    return angle
end

local function vector_contains(vector, expected)
    if vector == nil then return false end
    local ok, result = pcall(function()
        for index = 0, vector:size() - 1 do
            if tonumber(vector[index]) == expected then return true end
        end
        return false
    end)
    return ok and result or false
end

local function get_motion_tree()
    if runtime.game_object == nil then return nil end
    local motion_fsm = safe_call(
        runtime.game_object,
        "getComponent(System.Type)",
        sdk.typeof("via.motion.MotionFsm2")
    )
    local layer = safe_call(motion_fsm, "getLayer", 0)
    if layer == nil then return nil end
    local ok, tree = pcall(function() return layer:get_tree_object() end)
    if ok then return tree end
    return nil
end

local function write_transition_probe()
    if runtime.motion_tree == nil or runtime.transition_probe_done then return end
    if runtime.bank_id ~= 100 or runtime.motion_id ~= 147 then return end
    local active_node = runtime.motion_tree:get_node_by_id(tonumber(runtime.node_id))
    if active_node == nil then return end
    local output = { nodes = {} }
    local node_ids = { 3319244464, 532382550, 1265650183, 3239070790, 3993670187, 941394064 }
    for _, node_id in ipairs(node_ids) do
        local node = runtime.motion_tree:get_node_by_id(node_id)
        output.nodes[tostring(node_id)] = {
            node = snapshot_transition_object(node),
            data = snapshot_transition_object(node and node:get_data() or nil),
            selector = snapshot_transition_object(node and node:get_selector() or nil),
        }
    end
    output.active_node_id = runtime.node_id
    output.active_motion_frame = runtime.motion_frame
    output.active_node = snapshot_transition_object(active_node)
    output.active_data = snapshot_transition_object(active_node:get_data())
    output.active_selector = snapshot_transition_object(active_node:get_selector())
    json.dump_file(TRANSITION_PROBE_PATH, output)
    runtime.transition_probe_done = true
    log.info("[LongSwordAssist] Transition probe saved")
end

local function reset_tree_state(tree)
    if runtime.foresight_counter_object ~= nil and runtime.foresight_counter_original_end ~= nil then
        safe_set_field(runtime.foresight_counter_object, "_EndFrame", runtime.foresight_counter_original_end)
    end
    runtime.motion_tree = tree
    runtime.motion_tree_key = tostring(tree)
    condition_originals = {}
    foresight_entry_conditions = {}
    foresight_window_conditions = {}
    iai_conditions = {}
    scan_index = 0
    scan_complete = false
    runtime.foresight_counter_object = nil
    runtime.foresight_counter_original_end = nil
    runtime.foresight_counter_value = FORESIGHT_BASE_COUNTER_END
    runtime.foresight_counter_ready = false
    runtime.foresight_window_extended = false
    runtime.transition_probe_done = false
end

local function refresh_player()
    if runtime.player_manager == nil then
        runtime.player_manager = sdk.get_managed_singleton("snow.player.PlayerManager")
    end
    if runtime.player_manager == nil then return false end

    runtime.master_player = safe_call(runtime.player_manager, "findMasterPlayer")
    if runtime.master_player == nil then return false end

    runtime.master_index = safe_field(runtime.master_player, "_PlayerIndex")
    runtime.weapon_type = safe_field(runtime.master_player, "_playerWeaponType") or -1
    runtime.game_object = safe_call(runtime.master_player, "get_GameObject")
    runtime.motion_control = safe_field(runtime.master_player, "_RefPlayerMotionCtrl")

    if runtime.game_object ~= nil then
        runtime.behavior_tree = safe_call(
            runtime.game_object,
            "getComponent(System.Type)",
            sdk.typeof("via.behaviortree.BehaviorTree")
        )
    end

    if runtime.motion_control ~= nil then
        runtime.motion_id = safe_call(runtime.motion_control, "get_OldMotionID")
            or safe_field(runtime.motion_control, "_OldMotionID") or -1
        runtime.bank_id = safe_call(runtime.motion_control, "get_OldBankID")
            or safe_field(runtime.motion_control, "_OldBankID") or -1
    end

    if runtime.behavior_tree ~= nil then
        local node = safe_call(runtime.behavior_tree, "getCurrentNodeID", 0)
        if node ~= nil then runtime.node_id = tostring(node) end
    end

    local motion_layer = safe_call(runtime.master_player, "getMotionLayer", 0)
    runtime.motion_frame = safe_call(motion_layer, "get_Frame") or 0.0

    local tree = get_motion_tree()
    if tree ~= nil and tostring(tree) ~= runtime.motion_tree_key then
        reset_tree_state(tree)
    end
    return true
end

local function get_active_reflex()
    local object = runtime.player_quest_base
    if object == nil then return nil end
    local reflex = safe_call(object, "get_DamageReflex")
        or safe_call(object, "get_DamageReflexInfo")
        or safe_field(object, "_DamageReflex")
        or safe_field(object, "<DamageReflex>k__BackingField")
    return reflex
end

local function get_action_object(index)
    if runtime.motion_tree == nil then return nil end
    local ok, result = pcall(function()
        local actions = runtime.motion_tree:get_actions()
        return actions and actions[index] or nil
    end)
    if ok then return result end
    return nil
end

local function apply_foresight_counter_window()
    local counter = runtime.foresight_counter_object or get_action_object(ACTION_FORESIGHT_COUNTER)
    if counter == nil or type_name(counter) ~= "snow.player.fsm.PlayerFsm2ActionSeeThroughAttack" then
        runtime.foresight_counter_ready = false
        runtime.foresight_window_extended = false
        return
    end

    local end_frame = safe_field(counter, "_EndFrame")
    if type(end_frame) ~= "number" then
        runtime.foresight_counter_ready = false
        runtime.foresight_window_extended = false
        return
    end

    if runtime.foresight_counter_object ~= counter then
        runtime.foresight_counter_object = counter
        runtime.foresight_counter_original_end = end_frame
    end

    local bonus = 0
    if config.enabled and config.manual_foresight_extension then
        bonus = config.foresight_post_frames
    end
    local base_end = runtime.foresight_counter_original_end
    if base_end <= 0 then base_end = FORESIGHT_BASE_COUNTER_END end
    local target = bonus > 0 and (FORESIGHT_BASE_COUNTER_END + bonus) or runtime.foresight_counter_original_end
    if end_frame ~= target then safe_set_field(counter, "_EndFrame", target) end
    runtime.foresight_counter_value = bonus > 0 and target or base_end
    runtime.foresight_counter_ready = true
    runtime.foresight_window_extended = bonus > 0
end

local function restore_reflex_window()
    if runtime.reflex_object ~= nil and runtime.reflex_original_end ~= nil then
        safe_set_field(runtime.reflex_object, "_EndFrame", runtime.reflex_original_end)
    end
    runtime.reflex_object = nil
    runtime.reflex_original_end = nil
    runtime.reflex_action = nil
end

local function extend_active_reflex_window()
    local action = runtime.motion_id
    local extension = nil
    if config.enabled and config.manual_iai_extension and (action == 151 or action == 152 or action == 155 or action == 156) then
        extension = config.iai_post_frames
    end

    if extension == nil then
        restore_reflex_window()
        return
    end

    local reflex = get_active_reflex()
    if reflex == nil then return end
    local current_end = safe_field(reflex, "_EndFrame")
    if type(current_end) ~= "number" then return end

    if runtime.reflex_object ~= reflex or runtime.reflex_action ~= action then
        restore_reflex_window()
        runtime.reflex_object = reflex
        runtime.reflex_original_end = current_end
        runtime.reflex_action = action
    end

    local target_end = runtime.reflex_original_end + extension
    if current_end < target_end then
        safe_set_field(reflex, "_EndFrame", target_end)
    end
end

local function find_condition_object(index)
    if runtime.motion_tree == nil or index == nil or index < 0 or index >= 1073741824 then return nil end
    local ok, result = pcall(function() return runtime.motion_tree:get_conditions()[index] end)
    if ok then return result end
    return nil
end

local function remember_condition(target, index)
    local object = find_condition_object(index)
    if object == nil then return end
    if condition_originals[index] == nil then
        local pre_frame = safe_field(object, "PreFrame")
        local end_frame = safe_field(object, "EndFrame")
        if type(pre_frame) ~= "number" and type(end_frame) ~= "number" then return end
        condition_originals[index] = {
            object = object,
            pre_frame = type(pre_frame) == "number" and pre_frame or nil,
            end_frame = type(end_frame) == "number" and end_frame or nil,
        }
    end
    target[index] = true
end

local function scan_foresight_conditions()
    if runtime.motion_tree == nil or scan_complete then return end
    local nodes = runtime.motion_tree:get_nodes()
    if nodes == nil then return end

    local last_index = math.min(scan_index + 79, nodes:size() - 1)
    for node_index = scan_index, last_index do
        local node = nodes[node_index]
        if node ~= nil then
            local data = node:get_data()
            local states = data and data:get_states() or nil
            local conditions = data and data:get_transition_conditions() or nil
            if states ~= nil and conditions ~= nil then
                local count = math.min(states:size(), conditions:size())
                for transition = 0, count - 1 do
                    if tonumber(states[transition]) == FORESIGHT_TARGET_STATE then
                        remember_condition(foresight_entry_conditions, tonumber(conditions[transition]))
                    end
                end
            end
        end
    end

    scan_index = last_index + 1
    if scan_index >= nodes:size() then scan_complete = true end
end

local function find_foresight_window_conditions()
    if runtime.motion_tree == nil then return end
    local node_ids = { 532382550, 2839200054, 3239070790 }
    for _, node_id in ipairs(node_ids) do
        local node = runtime.motion_tree:get_node_by_id(node_id)
        local data = node and node:get_data() or nil
        local conditions = data and data:get_transition_conditions() or nil
        if conditions ~= nil then
            for index = 0, conditions:size() - 1 do
                local condition_index = tonumber(conditions[index])
                local object = find_condition_object(condition_index)
                local start_frame = safe_field(object, "StartFrame")
                local end_frame = safe_field(object, "EndFrame")
                local command = safe_field(object, "CmdType")
                if (command == 155 or command == 196 or command == 37 or command == 38)
                    and start_frame == 38.0 and end_frame == 52.0 then
                    remember_condition(foresight_window_conditions, condition_index)
                end
            end
        end
    end
end

local function find_iai_conditions()
    if runtime.motion_tree == nil or next(iai_conditions) ~= nil then return end
    local node_ids = { 3550856967, 2346527105, 1498247531 }
    for _, node_id in ipairs(node_ids) do
        local node = runtime.motion_tree:get_node_by_id(node_id)
        local data = node and node:get_data() or nil
        local conditions = data and data:get_transition_conditions() or nil
        if conditions ~= nil then
            for index = 0, conditions:size() - 1 do
                local condition_index = tonumber(conditions[index])
                local object = find_condition_object(condition_index)
                local command = safe_field(object, "CmdType")
                if command == 2 or command == 8 then
                    remember_condition(iai_conditions, condition_index)
                end
            end
        end
    end
end

local function apply_input_buffers()
    runtime.foresight_window_extended = false
    for index, original in pairs(condition_originals) do
        local bonus = 0
        if config.enabled and config.manual_foresight_extension and foresight_entry_conditions[index] then
            bonus = config.foresight_pre_frames
        elseif config.enabled and config.manual_iai_extension and iai_conditions[index] then
            bonus = config.iai_pre_frames
        end
        if original.pre_frame ~= nil then
            safe_set_field(original.object, "PreFrame", original.pre_frame + bonus)
        end
        if original.end_frame ~= nil then safe_set_field(original.object, "EndFrame", original.end_frame) end
    end
end

local function current_action_allows_foresight()
    local fallback_actions = {
        [4] = true, [5] = true, [6] = true, [7] = true, [8] = true,
        [10] = true, [13] = true, [14] = true, [15] = true,
        [101] = true, [102] = true, [103] = true, [104] = true,
        [105] = true, [106] = true, [107] = true, [108] = true,
        [109] = true, [307] = true,
    }
    if runtime.bank_id == 100 and fallback_actions[runtime.motion_id] == true then
        return true
    end
    if runtime.motion_tree == nil then return false end
    local node = runtime.motion_tree:get_node_by_id(tonumber(runtime.node_id))
    local depth = 0
    while node ~= nil and depth < 8 do
        local data = node:get_data()
        if data ~= nil and vector_contains(data:get_states(), FORESIGHT_TARGET_STATE) then
            return true
        end
        local parent_index = data and tonumber(data.parent) or nil
        if parent_index == nil or parent_index < 0 or parent_index >= runtime.motion_tree:get_nodes():size() then
            break
        end
        node = runtime.motion_tree:get_nodes()[parent_index]
        depth = depth + 1
    end
    return false
end

local function validate_nodes()
    runtime.iai_entry_ready = false
    if runtime.motion_tree == nil then
        runtime.nodes_ready = runtime.behavior_tree ~= nil
        runtime.iai_entry_ready = runtime.behavior_tree ~= nil
        return
    end
    local ids = {
        NODE_IAI_SUCCESS,
        NODE_FORESIGHT_ENTRY,
        NODE_FORESIGHT_ACTIVE,
        NODE_FORESIGHT_SUCCESS,
    }
    for _, id in ipairs(ids) do
        if runtime.motion_tree:get_node_by_id(id) == nil then
            runtime.nodes_ready = false
            return
        end
    end
    runtime.nodes_ready = runtime.behavior_tree ~= nil
    runtime.iai_entry_ready = runtime.behavior_tree ~= nil
end

local function jump_to_node(node_id)
    if runtime.behavior_tree == nil then return false end
    -- The legacy auto-Iai script uses the generic overload; network player
    -- proxies do not always expose the fully-qualified signature.
    local generic_ok = pcall(function()
        runtime.behavior_tree:call("setCurrentNode", node_id, nil, nil)
    end)
    if generic_ok then
        runtime.last_request_node = node_id
        runtime.last_request_result = true
        return true
    end
    local explicit_ok = pcall(function()
        runtime.behavior_tree:call(
            "setCurrentNode(System.UInt64, System.UInt32, via.behaviortree.SetNodeInfo)",
            node_id,
            nil,
            nil
        )
    end)
    runtime.last_request_node = node_id
    runtime.last_request_result = explicit_ok
    return explicit_ok
end

local function valid_enemy_attack(owner_type, attack_type, attack_object)
    if owner_type ~= 1 then return false end
    if not config.multiplayer_compat then return true end
    if attack_object == nil then
        -- Multiplayer damage can arrive without an AttackObject. OwnerType 1
        -- is the monster-side event used by the legacy auto-Iai script.
        return true
    end
    if type_name(attack_object) ~= "via.GameObject" then return false end
    local name = tostring(safe_call(attack_object, "get_Name") or ""):lower()
    local is_monster_object = name:match("^em%d%d%d") ~= nil
    local is_monster_hit = attack_type:find("EmHitAttack") ~= nil or attack_type:find("DummyHitAttack") ~= nil
    return is_monster_object or is_monster_hit
end

local function within_facing_arc(angle)
    return angle ~= nil and math.abs(angle) <= (config.total_direction_arc * 0.5)
end

local function eligible_auto_iai()
    if runtime.bank_id ~= 100 then return false end
    if runtime.motion_id == 151 then return runtime.motion_frame >= 76.0 end
    if runtime.motion_id == 152 then return true end
    if runtime.motion_id == 156 then return runtime.motion_frame >= 38.0 end
    return false
end

local function refresh_multiplayer()
    if not config.auto_detect_multiplayer then return end
    local observed = false
    local names = { "snow.LobbyManager", "snow.SnowSessionManager", "snow.network.NetworkManager" }
    local methods = { "get_IsMultiPlay", "get_IsMultiplay", "isMultiPlay", "isMultiplay" }
    for _, name in ipairs(names) do
        local singleton = sdk.get_managed_singleton(name)
        for _, method in ipairs(methods) do
            local value = safe_call(singleton, method)
            if type(value) == "boolean" and value then observed = true end
        end
    end
    runtime.multiplayer = observed
end

local maintenance_counter = 0

local foresight_motion_ids = {
    [4] = true, [5] = true, [6] = true, [7] = true, [8] = true,
    [10] = true, [13] = true, [14] = true, [15] = true,
    [101] = true, [102] = true, [103] = true, [104] = true,
    [105] = true, [106] = true, [107] = true, [108] = true,
    [109] = true, [307] = true,
}

local motion_control_type = sdk.find_type_definition("snow.player.PlayerMotionControl")
local late_update_method = motion_control_type and motion_control_type:get_method("lateUpdate") or nil
if late_update_method ~= nil then
    sdk.hook(late_update_method,
        function(args)
            local motion_control = managed_argument(args[2])
            local ref_player = safe_field(motion_control, "_RefPlayerBase")
            if ref_player == nil or runtime.master_index == nil then return end
            if safe_field(ref_player, "_PlayerIndex") ~= runtime.master_index then return end
            local bank = safe_field(motion_control, "_OldBankID")
            local motion = safe_field(motion_control, "_OldMotionID")
            if bank == 100 and foresight_motion_ids[motion] then
                runtime.foresight_legal_grace = 12
                runtime.last_event_motion = motion
                runtime.last_event_legal = true
            end
        end,
        function(retval) return retval end
    )
end

re.on_frame(function()
    if not refresh_player() then return end

    if runtime.cooldown > 0 then runtime.cooldown = runtime.cooldown - 1 end
    if runtime.pending_foresight > 0 then
        runtime.pending_foresight = runtime.pending_foresight - 1
        runtime.pending_foresight_age = runtime.pending_foresight_age + 1
        if runtime.motion_id == 147
            and runtime.motion_frame >= config.auto_foresight_success_delay
            and tonumber(runtime.node_id) ~= NODE_FORESIGHT_SUCCESS then
            if jump_to_node(NODE_FORESIGHT_SUCCESS) then
                runtime.last_trigger = "auto foresight"
                runtime.pending_foresight = 0
                runtime.pending_foresight_age = 0
            end
        end
        if runtime.pending_foresight == 0 then runtime.pending_foresight_age = 0 end
    end

    apply_foresight_counter_window()
    extend_active_reflex_window()

    scan_foresight_conditions()
    find_iai_conditions()
    find_foresight_window_conditions()
    runtime.foresight_legal = current_action_allows_foresight()
    if runtime.foresight_legal then
        runtime.foresight_legal_grace = 12
    elseif runtime.foresight_legal_grace > 0 then
        runtime.foresight_legal_grace = runtime.foresight_legal_grace - 1
    end

    maintenance_counter = maintenance_counter + 1
    if maintenance_counter >= 120 then
        maintenance_counter = 0
        validate_nodes()
        refresh_multiplayer()
        apply_input_buffers()
    end
end)

local damage_context = nil
local quest_type = sdk.find_type_definition("snow.player.PlayerQuestBase")
local damage_method = quest_type and quest_type:get_method("checkCalcDamage_DamageSide") or nil

local quest_update_method = quest_type and quest_type:get_method("update") or nil
if quest_update_method ~= nil then
    sdk.hook(quest_update_method,
        function(args)
            local quest_object = managed_argument(args[2])
            local player_index = safe_field(quest_object, "_PlayerIndex")
            if player_index ~= nil and player_index == runtime.master_index then
                runtime.player_quest_base = quest_object
            end
        end,
        function(retval) return retval end
    )
end

if damage_method ~= nil then
    sdk.hook(damage_method,
        function(args)
            damage_context = nil
            local cached_bank = runtime.bank_id
            local cached_motion = runtime.motion_id
            local cached_motion_frame = runtime.motion_frame
            if not config.enabled or not refresh_player() then return end
            if runtime.weapon_type ~= WEAPON_LONG_SWORD or runtime.behavior_tree == nil then return end

            local receiver = managed_argument(args[2])
            if safe_field(receiver, "_PlayerIndex") ~= runtime.master_index then return end
            runtime.player_quest_base = receiver

            local hit_info = managed_argument(args[3])
            local attack_data = safe_call(hit_info, "get_AttackData")
            local owner_type = safe_call(attack_data, "get_OwnerType")
            local attack_type = type_name(attack_data)
            local attack_object = safe_call(hit_info, "get_AttackObject")
                or safe_field(hit_info, "<AttackObject>k__BackingField")

            if not valid_enemy_attack(owner_type, attack_type, attack_object) then return end

            local player_position = object_position(runtime.game_object)
            local player_forward = quaternion_forward(object_rotation(runtime.game_object))
            local source_position = object_position(attack_object)
            local source_angle = signed_source_angle(player_position, player_forward, source_position)
            if source_angle == nil then
                local damaged_direction = safe_call(hit_info, "get_DamagedDirection")
                    or safe_field(hit_info, "<DamagedDirection>k__BackingField")
                source_angle = signed_direction_angle(player_forward, damaged_direction)
            end

            local foresight_hit_frame = nil
            if runtime.bank_id == 100 and runtime.motion_id == 147 then
                foresight_hit_frame = runtime.motion_frame
            elseif cached_bank == 100 and cached_motion == 147 then
                foresight_hit_frame = cached_motion_frame
            end

            runtime.source_angle = source_angle
            runtime.source_name = tostring(safe_call(attack_object, "get_Name")
                or (attack_object == nil and "多人同步怪物攻击" or ""))
            runtime.last_event_motion = foresight_hit_frame ~= nil and 147 or runtime.motion_id
            runtime.last_foresight_hit_frame = foresight_hit_frame or -1.0
            runtime.last_event_legal = runtime.foresight_legal or runtime.foresight_legal_grace > 0
            runtime.last_reject_reason = "无"

            damage_context = {
                can_face = within_facing_arc(source_angle),
                manual_iai = config.manual_iai_extension
                    and runtime.bank_id == 100
                    and runtime.motion_id == 155
                    and runtime.motion_frame > IAI_BASE_COUNTER_END
                    and runtime.motion_frame <= IAI_BASE_COUNTER_END + config.iai_post_frames,
                manual_foresight = config.manual_foresight_extension
                    and foresight_hit_frame ~= nil
                    and runtime.foresight_window_extended
                    and foresight_hit_frame > FORESIGHT_BASE_COUNTER_END
                    and foresight_hit_frame <= runtime.foresight_counter_value,
                auto_iai = config.auto_iai and runtime.behavior_tree ~= nil and eligible_auto_iai(),
                auto_foresight = config.auto_foresight
                    and (runtime.foresight_legal or runtime.foresight_legal_grace > 0),
            }
        end,
        function(retval)
            if damage_context == nil then return retval end
            local context = damage_context
            damage_context = nil

            local ok, flow = pcall(function() return sdk.to_int64(retval) end)
            if not ok then return retval end
            runtime.last_damage_flow = flow
            if flow == 2 then
                if context.manual_iai then runtime.last_trigger = "manual iai extended window" end
                if context.manual_foresight then runtime.last_trigger = "manual foresight extended window" end
                return retval
            end
            if (flow ~= 0 and flow ~= 2) or runtime.cooldown > 0 then return retval end

            if context.can_face and context.auto_iai and jump_to_node(NODE_AUTO_IAI_ENTRY) then
                runtime.last_trigger = "auto iai"
                runtime.last_request = "自动居合"
                runtime.cooldown = 15
                return sdk.to_ptr(1)
            end

            local foresight_node = runtime.nodes_ready and NODE_FORESIGHT_ENTRY or NODE_FORESIGHT_ACTIVE
            if context.can_face and context.auto_foresight and jump_to_node(foresight_node) then
                runtime.pending_foresight = 45
                runtime.pending_foresight_age = 0
                runtime.last_request = "自动见切起手"
                runtime.cooldown = 15
                return sdk.to_ptr(1)
            end

            if config.auto_foresight and not context.can_face then
                runtime.last_reject_reason = "攻击不在正面角度范围"
            elseif config.auto_foresight and not context.auto_foresight then
                runtime.last_reject_reason = "伤害到来时没有可见切动作缓存"
            elseif config.auto_foresight then
                runtime.last_reject_reason = "见切节点调用失败"
            end

            return retval
        end
    )
else
    log.error("[LongSwordAssist] checkCalcDamage_DamageSide was not found")
end

local function checkbox(label, key)
    local changed, value = imgui.checkbox(label, config[key])
    if changed then
        config[key] = value
        apply_input_buffers()
        save_config()
    end
end

local function slider_int(label, key, minimum, maximum)
    local changed, value = imgui.slider_int(label, config[key], minimum, maximum)
    if changed then
        config[key] = value
        apply_input_buffers()
        save_config()
    end
end

local function reset_defaults()
    for key, value in pairs(defaults) do config[key] = value end
    apply_input_buffers()
    save_config()
end

local function trigger_text(value)
    local names = {
        ["none"] = "无",
        ["auto iai"] = "自动居合",
        ["auto foresight"] = "自动见切",
        ["manual iai grace"] = "手动居合延长判定",
        ["manual foresight grace"] = "手动见切延长判定",
        ["manual iai extended window"] = "手动居合延长判定",
        ["manual foresight extended window"] = "手动见切延长判定",
    }
    return names[value] or tostring(value)
end

re.on_draw_ui(function()
    if not imgui.tree_node("太刀辅助") then return end

    checkbox("启用 Mod", "enabled")
    checkbox("自动居合", "auto_iai")
    checkbox("自动见切", "auto_foresight")
    checkbox("延长手动居合判定", "manual_iai_extension")
    checkbox("延长手动见切判定", "manual_foresight_extension")

    if imgui.tree_node("方向限制") then
        slider_int("正面判定总角度", "total_direction_arc", 30, 360)
        imgui.text("左右各：" .. string.format("%.1f", config.total_direction_arc * 0.5) .. " 度")
        imgui.tree_pop()
    end

    if imgui.tree_node("手动判定时间") then
        slider_int("居合提前输入帧", "iai_pre_frames", 0, 30)
        slider_int("居合延后判定帧", "iai_post_frames", 0, 60)
        slider_int("见切提前输入帧", "foresight_pre_frames", 0, 30)
        slider_int("见切延后判定帧", "foresight_post_frames", 0, 60)
        slider_int("自动见切成功分支延迟", "auto_foresight_success_delay", 0, 10)
        imgui.tree_pop()
    end

    if imgui.tree_node("联机设置") then
        checkbox("联机兼容模式", "multiplayer_compat")
        checkbox("自动检测多人任务", "auto_detect_multiplayer")
        imgui.text("检测到多人任务：" .. (runtime.multiplayer and "是" or "否"))
        imgui.tree_pop()
    end

    if imgui.tree_node("运行状态") then
        imgui.text("武器类型：" .. tostring(runtime.weapon_type))
        imgui.text("动作库 / 动作：" .. tostring(runtime.bank_id) .. " / " .. tostring(runtime.motion_id))
        imgui.text("当前节点：" .. runtime.node_id)
        imgui.text("动作帧：" .. string.format("%.2f", runtime.motion_frame))
        imgui.text("核心节点就绪：" .. (runtime.nodes_ready and "是" or "否"))
        imgui.text("自动居合节点就绪：" .. (runtime.iai_entry_ready and "是" or "否"))
        imgui.text("当前动作允许见切：" .. (runtime.foresight_legal and "是" or "否"))
        imgui.text("见切成功判定动作就绪：" .. (runtime.foresight_counter_ready and "是" or "否"))
        imgui.text("见切成功判定结束帧：" .. string.format("%.2f", runtime.foresight_counter_value))
        imgui.text("攻击来源角度：" .. (runtime.source_angle and string.format("%.2f", runtime.source_angle) or "无"))
        imgui.text("攻击来源：" .. runtime.source_name)
        imgui.text("最近触发：" .. trigger_text(runtime.last_trigger))
        imgui.text("最近请求：" .. runtime.last_request)
        imgui.text("请求节点：" .. tostring(runtime.last_request_node))
        imgui.text("节点调用成功：" .. (runtime.last_request_result and "是" or "否"))
        imgui.text("最近伤害流程：" .. tostring(runtime.last_damage_flow))
        imgui.text("伤害瞬间动作：" .. tostring(runtime.last_event_motion))
        imgui.text("见切命中缓存帧：" .. (runtime.last_foresight_hit_frame >= 0
            and string.format("%.2f", runtime.last_foresight_hit_frame) or "无"))
        imgui.text("见切动作缓存：" .. tostring(runtime.foresight_legal_grace))
        imgui.text("伤害瞬间允许见切：" .. (runtime.last_event_legal and "是" or "否"))
        imgui.text("最近拒绝原因：" .. runtime.last_reject_reason)
        imgui.text("FSM 扫描：" .. (scan_complete and "完成" or "进行中"))
        imgui.tree_pop()
    end

    if imgui.button("恢复默认设置") then reset_defaults() end
    imgui.tree_pop()
end)

re.on_config_save(function()
    save_config()
end)

save_config()
log.info("[LongSwordAssist] Functional build loaded. Automatic actions default to off.")
