local MOD_NAME = "BowAssist"
local CONFIG_PATH = "BowAssist_config.json"
local CAPTURE_PATH = "BowAssist_capture.json"
-- Compatibility fallback from the currently working sample. Runtime
-- resolution is attempted first so future BHVT changes can be adapted.
local DODGEBOLT_NODE_FALLBACK = 2692283689
-- This build reports Bow exclusively as runtime weapon type 13.
local BOW_RUNTIME_TYPE = 13
-- In the Motion FSM dump, 4281..4284 are NodeIndex values for the four
-- directional Dodgebolt nodes. Act10 is read from each node's action array;
-- these numbers are not global Action IDs.
local BOW_DODGEBOLT_NODE_START = 4281
local BOW_DODGEBOLT_NODE_END = 4284
-- The working Lua bow sample resolves the four windows directly from the
-- Motion FSM action table. Its version offset is Action_gx = 61.
local BOW_DODGEBOLT_ACTIONS = {
    { direction = "前", source_index = 9173, index = 9234 },
    { direction = "后", source_index = 9226, index = 9287 },
    { direction = "左", source_index = 9190, index = 9251 },
    { direction = "右", source_index = 9208, index = 9269 },
}

local defaults = {
    enabled = true,
    diagnostics = true,
    multiplayer_compat = true,
    auto_detect_multiplayer = true,
    auto_gp = false,
    auto_dodgebolt = false,
    manual_dodgebolt_extension = true,
    dodgebolt_post_frames = 12,
}

local config = json.load_file(CONFIG_PATH)
if type(config) ~= "table" then config = {} end
for key, value in pairs(defaults) do
    if config[key] == nil then config[key] = value end
end

local function save_config()
    json.dump_file(CONFIG_PATH, config)
end

local function safe_call(object, method, ...)
    if object == nil then return nil end
    local args = { ... }
    local ok, result = pcall(function() return object:call(method, table.unpack(args)) end)
    return ok and result or nil
end

local function safe_field(object, name)
    if object == nil then return nil end
    local ok, result = pcall(function() return object:get_field(name) end)
    return ok and result or nil
end

local function safe_set_field(object, name, value)
    if object == nil then return false end
    local ok = pcall(function() object:set_field(name, value) end)
    return ok
end

local function managed_argument(value)
    local ok, result = pcall(function() return sdk.to_managed_object(value) end)
    return ok and result or nil
end

local function type_name(object)
    if object == nil then return "nil" end
    local ok, result = pcall(function() return object:get_type_definition():get_full_name() end)
    return ok and tostring(result) or tostring(object)
end

local STATIC_ACTION_BIT = 1073741824

local function container_size(container)
    if container == nil then return 0 end
    local ok, size = pcall(function() return container:size() end)
    if ok and size ~= nil then return tonumber(size) or 0 end
    ok, size = pcall(function() return container:get_size() end)
    if ok and size ~= nil then return tonumber(size) or 0 end
    return 0
end

-- Node action arrays store either a normal global index or a static-action
-- index with bit 30 set. Keep the raw value so the tree can resolve the
-- correct action table.
local function get_tree_action(tree, raw_index)
    if tree == nil then return nil end
    local index = tonumber(raw_index)
    if index == nil then return nil end

    local ok, action = pcall(function() return tree:get_action(index) end)
    if ok and action ~= nil then return action end

    if index < STATIC_ACTION_BIT then
        local ok_actions, actions = pcall(function() return tree:get_actions() end)
        if ok_actions and actions ~= nil then
            local ok_item, item = pcall(function() return actions[index] end)
            if ok_item and item ~= nil then return item end
        end
    else
        local static_index = index - STATIC_ACTION_BIT
        local ok_data, data = pcall(function() return tree:get_data() end)
        local static_actions = ok_data and data and safe_call(data, "get_static_actions") or nil
        if static_actions ~= nil then
            local ok_item, item = pcall(function() return static_actions[static_index] end)
            if ok_item and item ~= nil then return item end
        end
    end
    return nil
end

local function get_tree_node(tree, node_id)
    if tree == nil or node_id == nil then return nil end
    local id = tonumber(node_id)
    if id == nil then return nil end
    local ok, node = pcall(function() return tree:get_node_by_id(id) end)
    return ok and node or nil
end

local runtime = {
    player_manager = nil,
    master_player = nil,
    master_index = nil,
    game_object = nil,
    behavior_tree = nil,
    motion_tree = nil,
    motion_tree_key = nil,
    player_quest_base = nil,
    motion_control = nil,
    weapon_type = -1,
    bank_id = -1,
    motion_id = -1,
    node_id = "0",
    motion_frame = 0.0,
    multiplayer = false,
    online_session = false,
    quest_status = -1,
    player_count = -1,
    multiplayer_signal = "未检测",
    last_source = "无",
    last_owner_type = -1,
    last_damage_flow = -1,
    damage_events = 0,
    gp_check_events = 0,
    last_gp_check_type = -1,
    last_gp_result = -1,
    motion_events = 0,
    last_marker = "无",
    reflex_action_events = 0,
    reflex_condition_events = 0,
    reflex_action_count = 0,
    reflex_condition_count = 0,
    last_reflex_signature = "无",
    last_reflex_condition = "无",
    auto_trigger_count = 0,
    last_auto_trigger = "无",
    last_reject_reason = "无",
    dodgebolt_node_id = nil,
    pending_auto_frames = 0,
    auto_protected_count = 0,
    motion_reflex_target_count = 0,
    motion_reflex_modified_count = 0,
    motion_reflex_last_target = "无",
    motion_reflex_active_target = "无",
    motion_tree_node_count = 0,
    motion_reflex_probe = "无",
    known_action_target_count = 0,
    known_action_modified_count = 0,
    known_action_probe = "无",
}

local capture = {
    mod = MOD_NAME,
    game_version = "16.0.2.0",
    events = {},
}

local last_motion_key = nil
local dirty = false
local MAX_EVENTS = 800
local frame_counter = 0
local last_reflex_scan_frame = -1000
local reflex_action_signatures = {}
local reflex_condition_signatures = {}
local motion_reflex_targets = {}
local motion_reflex_original_ends = {}
local known_action_original_ends = {}
local last_motion_reflex_scan_frame = -1000
local last_motion_reflex_scan_motion = -1

local function append_event(kind, extra)
    local event = {
        kind = kind,
        clock = os.clock(),
        weapon_type = runtime.weapon_type,
        bank_id = runtime.bank_id,
        motion_id = runtime.motion_id,
        node_id = runtime.node_id,
        motion_frame = runtime.motion_frame,
    }
    if type(extra) == "table" then
        for key, value in pairs(extra) do event[key] = value end
    end
    table.insert(capture.events, event)
    while #capture.events > MAX_EVENTS do table.remove(capture.events, 1) end
    dirty = true
end

local function save_capture()
    capture.config = config
    capture.runtime = {
        weapon_type = runtime.weapon_type,
        bank_id = runtime.bank_id,
        motion_id = runtime.motion_id,
        node_id = runtime.node_id,
        motion_frame = runtime.motion_frame,
        multiplayer = runtime.multiplayer,
        online_session = runtime.online_session,
        quest_status = runtime.quest_status,
        player_count = runtime.player_count,
        multiplayer_signal = runtime.multiplayer_signal,
        last_source = runtime.last_source,
        last_owner_type = runtime.last_owner_type,
        last_damage_flow = runtime.last_damage_flow,
        damage_events = runtime.damage_events,
        gp_check_events = runtime.gp_check_events,
        last_gp_check_type = runtime.last_gp_check_type,
        last_gp_result = runtime.last_gp_result,
        motion_events = runtime.motion_events,
        last_marker = runtime.last_marker,
        reflex_action_events = runtime.reflex_action_events,
        reflex_condition_events = runtime.reflex_condition_events,
        reflex_action_count = runtime.reflex_action_count,
        reflex_condition_count = runtime.reflex_condition_count,
        last_reflex_signature = runtime.last_reflex_signature,
        last_reflex_condition = runtime.last_reflex_condition,
        auto_trigger_count = runtime.auto_trigger_count,
        last_auto_trigger = runtime.last_auto_trigger,
        last_reject_reason = runtime.last_reject_reason,
        dodgebolt_node_id = runtime.dodgebolt_node_id,
        pending_auto_frames = runtime.pending_auto_frames,
        auto_protected_count = runtime.auto_protected_count,
        motion_reflex_target_count = runtime.motion_reflex_target_count,
        motion_reflex_modified_count = runtime.motion_reflex_modified_count,
        motion_reflex_last_target = runtime.motion_reflex_last_target,
        motion_reflex_active_target = runtime.motion_reflex_active_target,
        motion_tree_node_count = runtime.motion_tree_node_count,
        motion_reflex_probe = runtime.motion_reflex_probe,
        known_action_target_count = runtime.known_action_target_count,
        known_action_modified_count = runtime.known_action_modified_count,
        known_action_probe = runtime.known_action_probe,
    }
    json.dump_file(CAPTURE_PATH, capture)
    dirty = false
end

local gp_check_context = nil

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
    if runtime.motion_control ~= nil then
        runtime.motion_id = safe_call(runtime.motion_control, "get_OldMotionID")
            or safe_field(runtime.motion_control, "_OldMotionID") or -1
        runtime.bank_id = safe_call(runtime.motion_control, "get_OldBankID")
            or safe_field(runtime.motion_control, "_OldBankID") or -1
    end
    if runtime.game_object ~= nil then
        runtime.behavior_tree = safe_call(runtime.game_object, "getComponent(System.Type)",
            sdk.typeof("via.behaviortree.BehaviorTree"))
        local motion_fsm = safe_call(runtime.game_object, "getComponent(System.Type)",
            sdk.typeof("via.motion.MotionFsm2"))
        local motion_layer = safe_call(motion_fsm, "getLayer", 0)
        local ok_tree, motion_tree = pcall(function()
            return motion_layer and motion_layer:get_tree_object() or nil
        end)
        if ok_tree and motion_tree ~= runtime.motion_tree then
            runtime.motion_tree = motion_tree
            runtime.motion_tree_key = tostring(motion_tree)
            motion_reflex_targets = {}
            motion_reflex_original_ends = {}
            known_action_original_ends = {}
            runtime.motion_reflex_target_count = 0
            runtime.motion_reflex_modified_count = 0
            runtime.known_action_target_count = 0
            runtime.known_action_modified_count = 0
            runtime.motion_reflex_last_target = "无"
            runtime.motion_reflex_active_target = "无"
            last_motion_reflex_scan_frame = -1000
            last_motion_reflex_scan_motion = -1
        end
        if runtime.motion_tree ~= nil then
            local ok_nodes, nodes = pcall(function() return runtime.motion_tree:get_nodes() end)
            if ok_nodes and nodes ~= nil then
                local ok_size, size = pcall(function() return nodes:size() end)
                runtime.motion_tree_node_count = ok_size and tonumber(size) or 0
            end
        end
    end
    local node = safe_call(runtime.behavior_tree, "getCurrentNodeID", 0)
    if node ~= nil then runtime.node_id = tostring(node) end
    local layer = safe_call(runtime.master_player, "getMotionLayer", 0)
    runtime.motion_frame = safe_call(layer, "get_Frame") or 0.0
    return true
end

local function read_number(object, methods, fields)
    for _, method in ipairs(methods) do
        local value = safe_call(object, method)
        local number = tonumber(value)
        if number ~= nil then return number, method end
    end
    for _, field in ipairs(fields) do
        local value = safe_field(object, field)
        local number = tonumber(value)
        if number ~= nil then return number, field end
    end
    return nil, nil
end

local function refresh_multiplayer()
    if not config.auto_detect_multiplayer then
        runtime.multiplayer = false
        runtime.online_session = false
        runtime.quest_status = -1
        runtime.player_count = -1
        runtime.multiplayer_signal = "自动检测已关闭"
        return
    end

    local online = false
    local session_multi = false
    local quest_multi = false
    local signals = {}
    local network_names = {
        "snow.LobbyManager",
        "snow.SnowSessionManager",
        "snow.network.NetworkManager",
        "snow.network.session.MultiSessionManager",
    }
    local network_methods = {
        "get_IsMultiPlay", "get_IsMultiplay", "get_IsOnline",
        "get_IsOnlineMode", "isMultiPlay", "isMultiplay",
        "isOnline", "isOnlineMode",
    }

    for _, name in ipairs(network_names) do
        local singleton = sdk.get_managed_singleton(name)
        for _, method in ipairs(network_methods) do
            local value = safe_call(singleton, method)
            if value == true then
                online = true
                if method:lower():find("multi", 1, true) ~= nil then
                    session_multi = true
                end
                table.insert(signals, name .. "." .. method)
            end
        end
    end

    local quest_manager = sdk.get_managed_singleton("snow.QuestManager")
    local quest_status = safe_field(quest_manager, "_QuestStatus")
        or safe_call(quest_manager, "get_QuestStatus")
    runtime.quest_status = tonumber(quest_status) or -1
    local quest_active = runtime.quest_status == 2

    local quest_methods = {
        "get_IsMultiPlay", "get_IsMultiplay", "get_IsMultiplayerQuest",
        "get_IsMultiPlayerQuest", "isMultiPlay", "isMultiplay",
        "isMultiplayerQuest", "isMultiPlayerQuest",
    }
    for _, method in ipairs(quest_methods) do
        if safe_call(quest_manager, method) == true then
            quest_multi = true
            online = true
            table.insert(signals, "snow.QuestManager." .. method)
        end
    end

    local player_count, player_count_source = read_number(
        runtime.player_manager,
        {
            "getPlayerCount", "get_PlayerCount", "getPlayerNum", "get_PlayerNum",
            "getActivePlayerCount", "get_ActivePlayerCount",
            "getQuestPlayerCount", "get_QuestPlayerCount",
        },
        {
            "_PlayerCount", "<PlayerCount>k__BackingField", "_PlayerNum",
            "<PlayerNum>k__BackingField", "_ActivePlayerCount",
        }
    )
    runtime.player_count = player_count or -1
    local player_multi = player_count ~= nil and player_count > 1
    if player_multi then
        table.insert(signals, "PlayerManager." .. tostring(player_count_source))
    end

    runtime.online_session = online
    runtime.multiplayer = quest_active and (session_multi or quest_multi or player_multi)
    local state = "QuestStatus=" .. tostring(runtime.quest_status)
    if player_count ~= nil then state = state .. ";玩家数=" .. tostring(player_count) end
    if #signals > 0 then
        state = state .. ";信号=" .. table.concat(signals, ",")
    else
        state = state .. ";信号=未命中"
    end
    runtime.multiplayer_signal = state
end

local function is_bow_weapon()
    return runtime.weapon_type == BOW_RUNTIME_TYPE
end

local function valid_enemy_attack(owner_type, attack_type, attack_object)
    if owner_type ~= 1 then return false end
    if not config.multiplayer_compat then return true end
    if attack_object == nil then
        return attack_type:find("EmHitAttack", 1, true) ~= nil
            or attack_type:find("DummyHitAttack", 1, true) ~= nil
    end
    local name = tostring(safe_call(attack_object, "get_Name") or ""):lower()
    local is_monster_object = name:match("^em%d%d%d") ~= nil
    local is_monster_hit = attack_type:find("EmHitAttack", 1, true) ~= nil
        or attack_type:find("DummyHitAttack", 1, true) ~= nil
    return is_monster_object or is_monster_hit
end

local function resolve_dodgebolt_node()
    if runtime.behavior_tree == nil then return nil end
    local nodes = safe_call(runtime.behavior_tree, "get_nodes")
    if nodes == nil then return nil end
    local ok_size, size = pcall(function() return nodes:get_size() end)
    if not ok_size or size == nil then return nil end

    -- Resolve the entry node from its original bow action type instead of a
    -- version-specific numeric node ID.
    for node_index = 0, size - 1 do
        local node = nodes[node_index]
        local data = safe_call(node, "get_data")
        local node_actions = safe_call(data, "get_actions")
        if node_actions ~= nil then
            local ok_actions, action_size = pcall(function() return node_actions:get_size() end)
            if ok_actions and action_size ~= nil then
                for action_index = 0, action_size - 1 do
                    local global_index = tonumber(node_actions[action_index])
                    local action = get_tree_action(runtime.behavior_tree, global_index)
                    local name = type_name(action)
                    if name:find("PlayerFsm2ActionBowEscapeSwordArrow", 1, true) then
                        local node_id = safe_call(node, "get_id")
                        if node_id ~= nil then
                            runtime.dodgebolt_node_id = tonumber(node_id) or node_id
                            return runtime.dodgebolt_node_id
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function jump_to_dodgebolt()
    if runtime.behavior_tree == nil then return false end
    local target = runtime.dodgebolt_node_id or resolve_dodgebolt_node()
    local used_fallback = target == nil
    if used_fallback then target = DODGEBOLT_NODE_FALLBACK end
    if used_fallback then
        runtime.last_reject_reason = "未解析到原版闪身箭斩节点，使用兼容节点"
    end
    local current = safe_call(runtime.behavior_tree, "getCurrentNodeID", 0)
    if tonumber(current) == tonumber(target) then
        runtime.auto_protected_count = runtime.auto_protected_count + 1
        runtime.last_auto_trigger = "自动GP成功"
        runtime.last_reject_reason = "自动GP成功"
        return true
    end
    local ok = pcall(function()
        runtime.behavior_tree:call(
            "setCurrentNode(System.UInt64, System.UInt32, via.behaviortree.SetNodeInfo)",
            target, nil, nil)
    end)
    if ok then
        runtime.auto_trigger_count = runtime.auto_trigger_count + 1
        runtime.auto_protected_count = runtime.auto_protected_count + 1
        runtime.last_auto_trigger = "自动GP请求"
        runtime.last_reject_reason = "无"
        runtime.pending_auto_frames = 60
        append_event("自动 GP", { target_node = target })
        return true
    end
    runtime.last_reject_reason = "原版闪身箭斩节点调用失败"
    return false
end

local function find_player_argument(args, first_index, last_index)
    for index = first_index, last_index do
        local candidate = managed_argument(args[index])
        if candidate ~= nil and safe_field(candidate, "_PlayerIndex") ~= nil then
            return candidate
        end
    end
    return nil
end

local function marker(label)
    runtime.last_marker = label
    append_event("标记", { marker = label })
    save_capture()
end

local function get_active_reflex()
    local object = runtime.player_quest_base
    if object == nil then return nil end
    return safe_call(object, "get_DamageReflex")
        or safe_call(object, "get_DamageReflexInfo")
        or safe_field(object, "_DamageReflex")
        or safe_field(object, "<DamageReflex>k__BackingField")
end

local function restore_dodgebolt_window()
    if runtime.reflex_object ~= nil and runtime.reflex_original_end ~= nil then
        pcall(function() runtime.reflex_object:set_field("_EndFrame", runtime.reflex_original_end) end)
    end
    runtime.reflex_object = nil
    runtime.reflex_original_end = nil
    runtime.reflex_motion_id = -1
end

local function restore_motion_reflex_windows()
    for object, original_end in pairs(motion_reflex_original_ends) do
        safe_set_field(object, "_EndFrame", original_end)
    end
    motion_reflex_original_ends = {}
    runtime.motion_reflex_target_count = 0
    runtime.motion_reflex_modified_count = 0
    runtime.motion_reflex_active_target = "无"
end

local function restore_known_action_windows()
    for object, original_end in pairs(known_action_original_ends) do
        safe_set_field(object, "_EndFrame", original_end)
    end
    known_action_original_ends = {}
    runtime.known_action_target_count = 0
    runtime.known_action_modified_count = 0
    runtime.motion_reflex_last_target = "未启用"
    runtime.motion_reflex_active_target = "无"
end

-- Direct Action-table route used by the working bow Lua sample. This is
-- separate from the NodeIndex probe because the GP Action may be a generated
-- object that is not exposed through the node's Act10 list.
local function apply_known_action_windows()
    if runtime.motion_tree == nil then return end
    if not config.enabled or not config.manual_dodgebolt_extension then
        restore_known_action_windows()
        return
    end

    local target_count = 0
    local modified_count = 0
    local seen_actions = {}
    local seen_modified = {}
    local probe = {}
    local directions = {}
    for _, spec in ipairs(BOW_DODGEBOLT_ACTIONS) do
        local selected = nil
        local selected_index = nil
        local candidates = {
            spec.index,
            spec.source_index,
            spec.index + STATIC_ACTION_BIT,
            spec.source_index + STATIC_ACTION_BIT,
        }
        for _, index in ipairs(candidates) do
            local action = get_tree_action(runtime.motion_tree, index)
            local name = type_name(action)
            local start_frame = safe_field(action, "_StartFrame")
            local end_frame = safe_field(action, "_EndFrame")
            probe[#probe + 1] = string.format("%s[%d]=%s", spec.direction, index, name)
            if selected == nil and action ~= nil
                and (name:find("ActionDamageReflex", 1, true) ~= nil
                    or (type(start_frame) == "number" and type(end_frame) == "number")) then
                selected = action
                selected_index = index
            end
        end

        if selected ~= nil then
            local end_frame = safe_field(selected, "_EndFrame")
            if type(end_frame) == "number" then
                if not seen_actions[selected] then
                    seen_actions[selected] = true
                    target_count = target_count + 1
                end
                table.insert(directions, string.format("%s(Action %d)", spec.direction, selected_index))
                if known_action_original_ends[selected] == nil then
                    known_action_original_ends[selected] = end_frame
                end
                local target_end = known_action_original_ends[selected]
                    + (tonumber(config.dodgebolt_post_frames) or 0)
                local write_ok = end_frame >= target_end
                    or safe_set_field(selected, "_EndFrame", target_end)
                if write_ok and not seen_modified[selected] then
                    seen_modified[selected] = true
                    modified_count = modified_count + 1
                end
                runtime.motion_reflex_active_target = string.format(
                    "Action %s[%d] %s", spec.direction, selected_index, type_name(selected))
                if config.diagnostics then
                    local key = "known/" .. tostring(selected_index)
                    if not motion_reflex_targets[key] then
                        motion_reflex_targets[key] = true
                        append_event("弓闪身箭斩 Action", {
                            direction = spec.direction,
                            action_index = selected_index,
                            action_type = type_name(selected),
                            end_frame = end_frame,
                            target_end_frame = target_end,
                        })
                    end
                end
            end
        end
    end
    runtime.known_action_target_count = target_count
    runtime.known_action_modified_count = modified_count
    runtime.known_action_probe = table.concat(probe, " | ")
    if target_count > 0 then
        runtime.motion_reflex_last_target = string.format(
            "%s；目标/修改 %d/%d",
            table.concat(directions, "、"), target_count, modified_count)
    else
        runtime.motion_reflex_last_target = "未找到四向 Action"
    end
    if target_count > 0 then
        runtime.motion_reflex_target_count = target_count
        runtime.motion_reflex_modified_count = modified_count
    end
end

local function extend_dodgebolt_window()
    if runtime.motion_tree == nil and runtime.behavior_tree == nil then return end
    if not config.enabled or not config.manual_dodgebolt_extension then
        restore_motion_reflex_windows()
        return
    end

    local active_motion = runtime.motion_id == 202 or runtime.motion_id == 203
        or runtime.motion_id == 204 or runtime.motion_id == 205
        or runtime.motion_id == 452 or runtime.motion_id == 456
    if not active_motion then
        if next(motion_reflex_original_ends) ~= nil then restore_motion_reflex_windows() end
        runtime.motion_reflex_probe = "无"
        return
    end
    if runtime.motion_id == last_motion_reflex_scan_motion
        and frame_counter - last_motion_reflex_scan_frame < 30 then
        return
    end
    last_motion_reflex_scan_frame = frame_counter
    last_motion_reflex_scan_motion = runtime.motion_id

    local target_count = 0
    local modified_count = 0
    local seen_actions = {}
    local seen_modified = {}
    local probe = {}
    local probe_seen = {}
    local function add_probe(label, raw_index, action)
        if #probe >= 16 then return end
        local raw = tostring(raw_index or "nil")
        local name = type_name(action)
        local item = label .. "=" .. raw .. ":" .. name
        if not probe_seen[item] then
            probe_seen[item] = true
            probe[#probe + 1] = item
        end
    end

    local function process_action(tree_info, node_label, action_slot, raw_index)
        local tree = tree_info.object
        local action = get_tree_action(tree, raw_index)
        add_probe(tree_info.label .. "/" .. node_label .. "/Act" .. action_slot, raw_index, action)
        if action == nil then return false end
        local name = type_name(action)
        local start_frame = safe_field(action, "_StartFrame")
        local end_frame = safe_field(action, "_EndFrame")
        -- Some builds expose the bow reflex as a generic Action object rather
        -- than the named PlayerFsm2ActionDamageReflex subclass. The two frame
        -- fields are the stable discriminator for this action in Act10.
        local is_reflex = name:find("ActionDamageReflex", 1, true) ~= nil
            or (type(start_frame) == "number" and type(end_frame) == "number")
        if not is_reflex or type(end_frame) ~= "number" then return false end
        if not seen_actions[action] then
            seen_actions[action] = true
            target_count = target_count + 1
        end
        if motion_reflex_original_ends[action] == nil then
            motion_reflex_original_ends[action] = end_frame
        end
        local target_end = motion_reflex_original_ends[action] + (tonumber(config.dodgebolt_post_frames) or 0)
        local write_ok = end_frame >= target_end or safe_set_field(action, "_EndFrame", target_end)
        if write_ok and not seen_modified[action] then
            seen_modified[action] = true
            modified_count = modified_count + 1
        end
        runtime.motion_reflex_active_target = string.format("%s %s Act%d[%s] %s",
            tree_info.label, node_label, action_slot, tostring(raw_index), name)
        local key = tree_info.label .. "/" .. node_label .. "/" .. action_slot .. "/" .. tostring(raw_index)
        if config.diagnostics and not motion_reflex_targets[key] then
            motion_reflex_targets[key] = true
            append_event("Motion FSM Act10", {
                tree = tree_info.label,
                node = node_label,
                action_slot = action_slot,
                raw_action_index = tonumber(raw_index),
                action_type = name,
                start_frame = start_frame,
                end_frame = end_frame,
                target_end_frame = target_end,
            })
        end
        return true
    end

    local function process_node(tree_info, node, node_label)
        if node == nil then return false end
        local data = safe_call(node, "get_data")
        local actions = safe_call(data, "get_actions")
        if actions == nil then return false end
        local found = false
        -- Act10 is index 10 in the BHVT display; index 9 is retained for
        -- builds/tools that display action slots as one-based labels.
        for _, action_slot in ipairs({ 10, 9 }) do
            local raw_index = actions[action_slot]
            if process_action(tree_info, node_label, action_slot, raw_index) then found = true end
        end
        return found
    end

    -- 4281..4284 are node indices, not action indices. Probe Act10 on each
    -- node directly so the four directional windows are covered together.
    if runtime.motion_tree ~= nil then
        local tree_info = { object = runtime.motion_tree, label = "Motion FSM" }
        local nodes = safe_call(runtime.motion_tree, "get_nodes")
        for node_index = BOW_DODGEBOLT_NODE_START, BOW_DODGEBOLT_NODE_END do
            local node = nodes and nodes[node_index] or nil
            process_node(tree_info, node, "NodeIndex " .. tostring(node_index))
        end
    end

    -- Keep the current BHVT node as a diagnostic fallback in case a game
    -- update changes the Motion FSM node ordering.
    if runtime.behavior_tree ~= nil then
        process_node({ object = runtime.behavior_tree, label = "玩家 BHVT" },
            get_tree_node(runtime.behavior_tree, runtime.node_id),
            "当前Node " .. tostring(runtime.node_id))
    end

    if target_count > 0 then
        runtime.motion_reflex_target_count = target_count
        runtime.motion_reflex_modified_count = modified_count
    else
        runtime.motion_reflex_target_count = runtime.known_action_target_count
        runtime.motion_reflex_modified_count = runtime.known_action_modified_count
    end
    runtime.motion_reflex_probe = #probe > 0 and table.concat(probe, " | ") or "未读取到Act10"
end

-- The bow's GP path has not reached the damage-check hook in this build.
-- Inspect the BHVT action/condition objects directly to locate the real window.
local function scan_reflex_nodes()
    if runtime.behavior_tree == nil then return end
    local nodes = safe_call(runtime.behavior_tree, "get_nodes")
    local action_count = 0
    local condition_count = 0
    if nodes == nil then return end
    local ok_size, size = pcall(function() return nodes:get_size() end)
    if not ok_size or size == nil then return end
    for node_index = 0, size - 1 do
        local node = nodes[node_index]
        local data = safe_call(node, "get_data")
        local node_actions = safe_call(data, "get_actions")
        if node_actions ~= nil then
            local ok_actions, action_size = pcall(function() return node_actions:get_size() end)
            if ok_actions and action_size ~= nil then
                for action_index = 0, action_size - 1 do
                    local global_index = tonumber(node_actions[action_index])
                    if global_index ~= nil then
                        local action = get_tree_action(runtime.behavior_tree, global_index)
                        local name = type_name(action)
                        if name:find("PlayerFsm2ActionDamageReflex", 1, true) then
                            action_count = action_count + 1
                            local id = safe_field(action, "v1_ID") or safe_field(action, "_ID") or -1
                            local reflex_type = safe_field(action, "_Type") or -1
                            local start_frame = safe_field(action, "_StartFrame") or -1
                            local end_frame = safe_field(action, "_EndFrame") or -1
                            local key = string.format("%d/%d", node_index, action_index)
                            local action_signature = string.format("%s:%s:%s:%s:%s", key,
                                tostring(id), tostring(reflex_type), tostring(start_frame), tostring(end_frame))
                            if action_signature ~= reflex_action_signatures[key] then
                                reflex_action_signatures[key] = action_signature
                                runtime.last_reflex_signature = action_signature
                                runtime.reflex_action_events = runtime.reflex_action_events + 1
                                append_event("反射动作", {
                                    node_index = node_index,
                                    action_index = action_index,
                                    action_type = name,
                                    action_id = id,
                                    reflex_type = reflex_type,
                                    start_frame = start_frame,
                                    end_frame = end_frame,
                                })
                            end
                        end
                    end
                end
            end
        end
        local transition_conditions = safe_call(data, "get_transition_conditions")
        if transition_conditions ~= nil then
            local ok_conditions, condition_size = pcall(function() return transition_conditions:get_size() end)
            if ok_conditions and condition_size ~= nil then
                for condition_index = 0, condition_size - 1 do
                    local global_index = tonumber(transition_conditions[condition_index])
                    local condition = global_index and safe_call(runtime.behavior_tree, "get_condition", global_index) or nil
                    local name = type_name(condition)
                    if name:find("PlayerFsm2ConditionDamageReflexSuccess", 1, true) then
                        condition_count = condition_count + 1
                        local id = safe_field(condition, "v1_ID") or -1
                        local value = safe_field(condition, "v2_Condition")
                        local key = string.format("%d/%d", node_index, condition_index)
                        local condition_signature = string.format("%s:%s:%s", key, tostring(id), tostring(value))
                        if condition_signature ~= reflex_condition_signatures[key] then
                            reflex_condition_signatures[key] = condition_signature
                            runtime.last_reflex_condition = condition_signature
                            runtime.reflex_condition_events = runtime.reflex_condition_events + 1
                            append_event("反射成功条件", {
                                node_index = node_index,
                                condition_index = condition_index,
                                condition_type = name,
                                condition_id = id,
                                condition_value = value,
                            })
                        end
                    end
                end
            end
        end
    end
    runtime.reflex_action_count = action_count
    runtime.reflex_condition_count = condition_count
end

re.on_frame(function()
    frame_counter = frame_counter + 1
    if not refresh_player() then return end
    if not is_bow_weapon() then return end
    apply_known_action_windows()
    extend_dodgebolt_window()
    if runtime.pending_auto_frames > 0 then
        runtime.pending_auto_frames = runtime.pending_auto_frames - 1
        if runtime.motion_id == 452 or runtime.motion_id == 456 then
            runtime.last_auto_trigger = "自动GP成功"
            runtime.last_reject_reason = "自动GP成功"
            runtime.pending_auto_frames = 0
            append_event("自动 GP 执行确认", { confirmed_motion = runtime.motion_id })
        elseif runtime.pending_auto_frames == 0 and runtime.last_auto_trigger == "自动GP请求" then
            runtime.last_auto_trigger = "自动GP未进入动作"
            runtime.last_reject_reason = "原版节点未进入闪身箭斩动作"
        end
    end
    local key = string.format("%d/%d/%s", runtime.bank_id, runtime.motion_id, runtime.node_id)
    if key ~= last_motion_key then
        last_motion_key = key
        runtime.motion_events = runtime.motion_events + 1
        append_event("动作变化")
    end
    if config.diagnostics and frame_counter - last_reflex_scan_frame >= 30 then
        last_reflex_scan_frame = frame_counter
        scan_reflex_nodes()
    end
    refresh_multiplayer()
    if config.diagnostics and dirty and (#capture.events % 20 == 0) then save_capture() end
end)

local quest_type = sdk.find_type_definition("snow.player.PlayerQuestBase")
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

local damage_method = quest_type and quest_type:get_method("checkCalcDamage_DamageSide") or nil
if damage_method ~= nil then
    local damage_context = nil
    sdk.hook(damage_method,
        function(args)
            damage_context = nil
            if not config.enabled or not refresh_player() or not is_bow_weapon() then return end
            local receiver = managed_argument(args[2])
            if safe_field(receiver, "_PlayerIndex") ~= runtime.master_index then return end
            runtime.player_quest_base = receiver
            local hit_info = managed_argument(args[3])
            local attack_data = safe_call(hit_info, "get_AttackData")
            local owner_type = safe_call(attack_data, "get_OwnerType")
            local attack_object = safe_call(hit_info, "get_AttackObject")
                or safe_field(hit_info, "<AttackObject>k__BackingField")
            runtime.last_owner_type = owner_type or -1
            runtime.last_source = tostring(safe_call(attack_object, "get_Name") or "未知来源")
            runtime.damage_events = runtime.damage_events + 1
            damage_context = {
                owner_type = owner_type or -1,
                attack_type = type_name(attack_data),
                attack_object = attack_object,
            }
            if config.diagnostics then append_event("受击", {
                owner_type = owner_type,
                owner_type_name = type_name(attack_data),
                source = runtime.last_source,
                attack_object_type = type_name(attack_object),
            }) end
        end,
        function(retval)
            local context = damage_context
            damage_context = nil
            if context == nil or not is_bow_weapon() then return retval end
            local ok, flow = pcall(function() return sdk.to_int64(retval) end)
            if not ok then return retval end
            runtime.last_damage_flow = flow

            local auto_enabled = config.auto_gp or config.auto_dodgebolt
            if flow == 0 and auto_enabled then
                if valid_enemy_attack(context.owner_type, context.attack_type, context.attack_object) then
                    if jump_to_dodgebolt() then
                        runtime.last_damage_flow = 1
                        if config.diagnostics then
                            append_event("自动 GP 拦截", { original_flow = flow })
                        end
                        return sdk.to_ptr(1)
                    end
                else
                    runtime.last_reject_reason = "攻击来源不是怪物"
                end
            end
            return retval
        end
    )
end

local reflex_method = quest_type and quest_type:get_method(
    "checkDamageReflexNoDamageHitEnable(snow.player.DamageReflexInfo.Type, snow.DamageReceiver.HitInfo, snow.hit.userdata.BaseHitAttackRSData, snow.hit.DamageFlowInfoBase)"
)
if reflex_method ~= nil then
    sdk.hook(reflex_method,
        function(args)
            gp_check_context = nil
            if not config.diagnostics or not refresh_player() or not is_bow_weapon() then return end
            local receiver = find_player_argument(args, 2, 6)
            if safe_field(receiver, "_PlayerIndex") ~= runtime.master_index then return end
            local check_type = -1
            for index = 2, 6 do
                local value = tonumber(args[index])
                if value ~= nil then check_type = value; break end
            end
            runtime.gp_check_events = runtime.gp_check_events + 1
            runtime.last_gp_check_type = check_type
            gp_check_context = {
                check_type = check_type,
                motion_id = runtime.motion_id,
                node_id = runtime.node_id,
                motion_frame = runtime.motion_frame,
            }
        end,
        function(retval)
            if gp_check_context == nil then return retval end
            local context = gp_check_context
            gp_check_context = nil
            local ok, result = pcall(function() return sdk.to_int64(retval) end)
            runtime.last_gp_result = ok and result or tostring(retval)
            context.result = runtime.last_gp_result
            append_event("GP判定", context)
            return retval
        end
    )
end

local function checkbox(label, key)
    local changed, value = imgui.checkbox(label, config[key])
    if changed then config[key] = value; save_config() end
end

local function slider_int(label, key, min_value, max_value)
    local changed, value = imgui.slider_int(label, config[key], min_value, max_value)
    if changed then config[key] = value; save_config() end
end

re.on_draw_ui(function()
    if not imgui.tree_node("弓箭辅助（诊断版）") then return end
    checkbox("启用 Mod", "enabled")
    checkbox("自动 GP（自动发动闪身箭斩）", "auto_gp")
    checkbox("自动闪身箭斩兼容开关", "auto_dodgebolt")
    checkbox("延长手动闪身箭斩判定", "manual_dodgebolt_extension")
    checkbox("联机兼容模式", "multiplayer_compat")
    checkbox("自动检测多人任务", "auto_detect_multiplayer")
    slider_int("手动闪身箭斩延后帧", "dodgebolt_post_frames", 0, 60)
    if imgui.tree_node("运行状态") then
        imgui.text("武器类型：" .. tostring(runtime.weapon_type) .. "（弓为 13）")
        imgui.text("动作库 / 动作：" .. tostring(runtime.bank_id) .. " / " .. tostring(runtime.motion_id))
        imgui.text("当前节点：" .. runtime.node_id)
        imgui.text("动作帧：" .. string.format("%.2f", runtime.motion_frame))
        imgui.text("多人任务（任务中）：" .. (runtime.multiplayer and "是" or "否"))
        imgui.text("联机会话 / 集会所：" .. (runtime.online_session and "是" or "否"))
        imgui.text("任务状态：" .. tostring(runtime.quest_status)
            .. "；玩家数：" .. tostring(runtime.player_count))
        imgui.text("多人检测来源：" .. runtime.multiplayer_signal)
        imgui.text("动作变化数：" .. tostring(runtime.motion_events))
        imgui.text("受击事件数：" .. tostring(runtime.damage_events))
        imgui.text("最近攻击来源：" .. runtime.last_source)
        imgui.text("最近攻击方类型：" .. tostring(runtime.last_owner_type))
        imgui.text("最近伤害流程：" .. tostring(runtime.last_damage_flow))
        imgui.text("GP 判定次数：" .. tostring(runtime.gp_check_events))
        imgui.text("最近 GP 类型 / 返回值：" .. tostring(runtime.last_gp_check_type)
            .. " / " .. tostring(runtime.last_gp_result))
        imgui.text("最近标记：" .. runtime.last_marker)
        imgui.text("自动 GP 触发次数：" .. tostring(runtime.auto_trigger_count))
        imgui.text("自动 GP 拦截次数：" .. tostring(runtime.auto_protected_count))
        imgui.text("最近自动动作：" .. runtime.last_auto_trigger)
        imgui.text("最近状态：" .. runtime.last_reject_reason)
        imgui.text("闪身箭斩节点：" .. tostring(runtime.dodgebolt_node_id or "兼容回退"))
        imgui.text("反射动作 / 成功条件：" .. tostring(runtime.reflex_action_count)
            .. " / " .. tostring(runtime.reflex_condition_count))
        imgui.text("反射扫描事件：" .. tostring(runtime.reflex_action_events)
            .. " / " .. tostring(runtime.reflex_condition_events))
        imgui.text("最近反射动作：" .. runtime.last_reflex_signature)
        imgui.text("最近成功条件：" .. runtime.last_reflex_condition)
        imgui.text("Motion FSM Act10 目标 / 已修改：" .. tostring(runtime.motion_reflex_target_count)
            .. " / " .. tostring(runtime.motion_reflex_modified_count))
        imgui.text("Motion FSM 节点数：" .. tostring(runtime.motion_tree_node_count))
        imgui.text("Motion FSM 目标摘要：" .. runtime.motion_reflex_last_target)
        imgui.text("Act10 探测：" .. runtime.motion_reflex_probe)
        imgui.text("已知 Action 目标 / 已修改：" .. tostring(runtime.known_action_target_count)
            .. " / " .. tostring(runtime.known_action_modified_count))
        imgui.text("Action 探测：" .. string.sub(runtime.known_action_probe, 1, 260))
        imgui.tree_pop()
    end
    if imgui.tree_node("采集标记") then
        if imgui.button("标记：基础动作") then marker("基础动作") end
        if imgui.button("标记：四向闪身箭斩") then marker("四向闪身箭斩") end
        if imgui.button("标记：GP 过早") then marker("GP 过早") end
        if imgui.button("标记：GP 成功") then marker("GP 成功") end
        if imgui.button("标记：GP 过晚") then marker("GP 过晚") end
        if imgui.button("清空采集") then
            capture.events = {}
            runtime.damage_events = 0
            runtime.gp_check_events = 0
            runtime.reflex_action_events = 0
            runtime.reflex_condition_events = 0
            runtime.motion_reflex_target_count = 0
            runtime.motion_reflex_modified_count = 0
            runtime.motion_reflex_last_target = "无"
            runtime.motion_reflex_active_target = "无"
            runtime.motion_reflex_probe = "无"
            runtime.known_action_target_count = 0
            runtime.known_action_modified_count = 0
            runtime.known_action_probe = "无"
            runtime.auto_trigger_count = 0
            runtime.auto_protected_count = 0
            runtime.last_reflex_signature = "无"
            runtime.last_reflex_condition = "无"
            reflex_action_signatures = {}
            reflex_condition_signatures = {}
            motion_reflex_targets = {}
            known_action_original_ends = {}
            save_capture()
        end
        if imgui.button("保存采集") then save_capture() end
        imgui.tree_pop()
    end
    imgui.tree_pop()
end)

re.on_config_save(function()
    save_config()
    if dirty then save_capture() end
end)

save_config()
log.info("[BowAssist] Diagnostic build loaded. Automatic actions are inactive.")
