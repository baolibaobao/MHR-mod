-- Runtime-only capture for a manually successful Kamui Iai.
-- It does not change actions, nodes, damage flow, or input handling.

local CAPTURE_PATH = "LongSwordKamui_capture.json"
local WEAPON_LONG_SWORD = 2
local KAMUI_READY_MOTION = 161
local KAMUI_SUCCESS_MOTION = 162
local STATIC_ENTRY_NODE = 2874088718
local STATIC_SUCCESS_NODE = 2605267967
local MAX_HISTORY = 180

local runtime = {
    player_manager = nil,
    master_player = nil,
    master_index = nil,
    game_object = nil,
    motion_control = nil,
    behavior_tree = nil,
    motion_layer = nil,
    motion_tree = nil,
    weapon_type = -1,
    bank_id = -1,
    motion_id = -1,
    motion_frame = 0.0,
    behavior_node_id = 0,
    motion_node_id = 0,
    previous = nil,
    history = {},
    transition_count = 0,
    saved = false,
    last_error = "无",
}

local capture = {
    mod = "LongSwordKamuiCapture",
    game_version = "16.0.2.0",
    purpose = "手动神威居合 Motion 161 -> 162 运行时采集",
    transitions = {},
}

-- Keep a previous capture across game launches.  The old script wrote an
-- empty runtime object unconditionally at load time, which erased a valid
-- manual transition before it could be inspected.
local saved_capture = json.load_file(CAPTURE_PATH)
if type(saved_capture) == "table" and type(saved_capture.transitions) == "table" then
    capture = saved_capture
end

local function safe_call(object, method, ...)
    if object == nil then return nil end
    local args = { ... }
    local ok, result = pcall(function() return object:call(method, table.unpack(args)) end)
    if ok then return result end
    return nil
end

local function safe_field(object, name)
    if object == nil then return nil end
    local ok, result = pcall(function() return object:get_field(name) end)
    if ok then return result end
    return nil
end

-- Motion FSM tree/node objects are native wrappers rather than managed
-- objects. Their methods must be invoked through the Lua userdata directly.
local function direct_call(object, method, ...)
    if object == nil then return nil end
    local args = { ... }
    local ok, result = pcall(function()
        local function_value = object[method]
        if function_value == nil then return nil end
        return function_value(object, table.unpack(args))
    end)
    if ok then return result end
    return nil
end

local function direct_field(object, name)
    if object == nil then return nil end
    local ok, result = pcall(function() return object[name] end)
    if ok then return result end
    return nil
end

local function managed_argument(value)
    local ok, result = pcall(function() return sdk.to_managed_object(value) end)
    if ok then return result end
    return nil
end

local function type_name(object)
    if object == nil then return "nil" end
    local ok, result = pcall(function() return object:get_type_definition():get_full_name() end)
    if ok and result ~= nil then return tostring(result) end
    return tostring(object)
end

local function array_size(array)
    if array == nil then return 0 end
    local ok, result = pcall(function() return array:size() end)
    if ok and result ~= nil then return tonumber(result) or 0 end
    return 0
end

local function array_at(array, index)
    if array == nil then return nil end
    local ok, result = pcall(function() return array[index] end)
    if ok then return result end
    return nil
end

local function value_summary(value)
    local kind = type(value)
    if value == nil or kind == "number" or kind == "boolean" or kind == "string" then
        return value
    end
    return { type = type_name(value), text = tostring(value) }
end

local function snapshot_object(object)
    local result = { type = type_name(object), fields = {} }
    if object == nil then return result end

    local ok = pcall(function()
        local current = object:get_type_definition()
        local depth = 0
        while current ~= nil and depth < 6 do
            local fields = current:get_fields()
            if fields ~= nil then
                for index = 0, array_size(fields) - 1 do
                    local field = array_at(fields, index)
                    if field ~= nil then
                        local name = field:get_name()
                        local field_ok, value = pcall(function() return field:get_data(object) end)
                        if field_ok then result.fields[name] = value_summary(value) end
                    end
                end
            end
            current = current:get_parent_type()
            depth = depth + 1
        end
    end)
    if not ok then result.read_error = true end
    return result
end

local function number_array(array)
    local result = {}
    for index = 0, array_size(array) - 1 do
        local value = array_at(array, index)
        local number = tonumber(value)
        result[#result + 1] = number ~= nil and number or tostring(value)
    end
    return result
end

local function vector_array(array)
    local result = {}
    for index = 0, array_size(array) - 1 do
        local nested = array_at(array, index)
        result[#result + 1] = number_array(nested)
    end
    return result
end

local function get_node(tree, node_id)
    if tree == nil or node_id == nil or tonumber(node_id) == 0 then return nil end
    local id = tonumber(node_id)
    local ok, node = pcall(function() return tree:get_node_by_id(id) end)
    if ok and node ~= nil then return node end
    -- Some REFramework builds expose only the index accessor on the native
    -- wrapper.  Resolve the ID without treating an accessor miss as absent.
    local count = tonumber(direct_call(tree, "get_node_count") or 0) or 0
    for index = 0, count - 1 do
        local candidate = direct_call(tree, "get_node", index)
        local candidate_id = candidate and tonumber(direct_call(candidate, "get_id") or 0) or 0
        if candidate ~= nil and candidate_id == id then return candidate end
    end
    return nil
end

local function node_id(node)
    return tonumber(direct_call(node, "get_id") or 0) or 0
end

local function node_snapshot(tree, node)
    if node == nil then return nil end
    local data = direct_call(node, "get_data")
    local snapshot = {
        id = node_id(node),
        name = tostring(direct_call(node, "get_name") or ""),
        full_name = tostring(direct_call(node, "get_full_name") or ""),
        type = type_name(node),
        data = snapshot_object(data),
        actions = number_array(direct_call(data, "get_actions")),
        states = number_array(direct_call(data, "get_states")),
        states_2 = number_array(direct_call(data, "get_states_2")),
        transition_conditions = number_array(direct_call(data, "get_transition_conditions")),
        transition_ids = number_array(direct_call(data, "get_transition_ids")),
        transition_attributes = number_array(direct_call(data, "get_transition_attributes")),
        transition_events = vector_array(direct_call(data, "get_transition_events")),
        parent_index = tonumber(direct_field(data, "parent") or safe_field(data, "parent") or 0) or 0,
        children = {},
        action_objects = {},
        condition_objects = {},
        transition_objects = {},
    }

    local children = direct_call(node, "get_children")
    for index = 0, array_size(children) - 1 do
        snapshot.children[#snapshot.children + 1] = node_id(array_at(children, index))
    end

    local actions = direct_call(tree, "get_actions")
    for _, index in ipairs(snapshot.actions) do
        if type(index) == "number" and index >= 0 then
            local action = array_at(actions, index)
            snapshot.action_objects[#snapshot.action_objects + 1] = {
                index = index,
                object = snapshot_object(action),
            }
        end
    end

    local conditions = direct_call(tree, "get_conditions")
    local static_conditions = direct_call(tree, "get_static_conditions")
    for _, index in ipairs(snapshot.transition_conditions) do
        if type(index) == "number" and index >= 0 then
            local condition = nil
            local condition_ok, direct_condition = pcall(function() return tree:get_condition(index) end)
            if condition_ok then condition = direct_condition end
            if condition == nil and index >= 1073741824 and static_conditions ~= nil then
                condition = array_at(static_conditions, index % 1073741824)
            end
            if condition == nil and index < 1073741824 then
                condition = array_at(conditions, index)
            end
            snapshot.condition_objects[#snapshot.condition_objects + 1] = {
                index = index,
                object = snapshot_object(condition),
            }
        end
    end

    local transitions = direct_call(tree, "get_transitions")
    for transition_index, event_indices in ipairs(snapshot.transition_events) do
        for _, event_index in ipairs(event_indices) do
            if type(event_index) == "number" and event_index >= 0 then
                local event = array_at(transitions, event_index)
                snapshot.transition_objects[#snapshot.transition_objects + 1] = {
                    transition = transition_index - 1,
                    index = event_index,
                    object = snapshot_object(event),
                }
            end
        end
    end
    return snapshot
end

local function collect_related_nodes(tree, ids, output, depth)
    if tree == nil or depth < 0 then return end
    for _, raw_id in ipairs(ids) do
        local id = tonumber(raw_id) or 0
        if id ~= 0 and output[tostring(id)] == nil then
            local node = get_node(tree, id)
            if node ~= nil then
                local snapshot = node_snapshot(tree, node)
                output[tostring(id)] = snapshot
                local related = {}
                if snapshot.parent_index > 0 then
                    local nodes = direct_call(tree, "get_nodes")
                    local parent = array_at(nodes, snapshot.parent_index)
                    related[#related + 1] = node_id(parent)
                end
                for _, child_id in ipairs(snapshot.children) do related[#related + 1] = child_id end
                collect_related_nodes(tree, related, output, depth - 1)
            end
        end
    end
end

local function save_capture()
    capture.runtime = {
        weapon_type = runtime.weapon_type,
        bank_id = runtime.bank_id,
        motion_id = runtime.motion_id,
        behavior_node_id = runtime.behavior_node_id,
        motion_node_id = runtime.motion_node_id,
        transition_count = runtime.transition_count,
    }
    json.dump_file(CAPTURE_PATH, capture)
    log.info("[LongSwordKamuiCapture] saved " .. CAPTURE_PATH)
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
    runtime.motion_layer = safe_call(runtime.master_player, "getMotionLayer", 0)
    runtime.motion_frame = tonumber(safe_call(runtime.motion_layer, "get_Frame") or 0.0) or 0.0

    if runtime.motion_control ~= nil then
        runtime.motion_id = safe_call(runtime.motion_control, "get_OldMotionID")
            or safe_field(runtime.motion_control, "_OldMotionID") or -1
        runtime.bank_id = safe_call(runtime.motion_control, "get_OldBankID")
            or safe_field(runtime.motion_control, "_OldBankID") or -1
    end

    if runtime.game_object ~= nil then
        runtime.behavior_tree = safe_call(
            runtime.game_object,
            "getComponent(System.Type)",
            sdk.typeof("via.behaviortree.BehaviorTree")
        )
        local motion_fsm = safe_call(
            runtime.game_object,
            "getComponent(System.Type)",
            sdk.typeof("via.motion.MotionFsm2")
        )
        local layer = safe_call(motion_fsm, "getLayer", 0)
        if layer ~= nil then
            local ok, tree = pcall(function() return layer:get_tree_object() end)
            if ok then runtime.motion_tree = tree end
        end
    end

    local behavior_id = safe_call(runtime.behavior_tree, "getCurrentNodeID", 0)
    local motion_id = safe_call(runtime.motion_layer, "getCurrentNodeID", 0)
    runtime.behavior_node_id = tonumber(behavior_id) or 0
    runtime.motion_node_id = tonumber(motion_id) or 0
    return true
end

local function current_snapshot()
    return {
        clock = os.clock(),
        weapon_type = runtime.weapon_type,
        bank_id = runtime.bank_id,
        motion_id = tonumber(runtime.motion_id) or -1,
        motion_frame = runtime.motion_frame,
        behavior_node_id = runtime.behavior_node_id,
        motion_node_id = runtime.motion_node_id,
    }
end

local function collect_kamui_transition(before, after)
    if runtime.saved then return end
    runtime.transition_count = runtime.transition_count + 1
    local nodes = {}
    collect_related_nodes(runtime.motion_tree, {
        before.behavior_node_id,
        before.motion_node_id,
        after.behavior_node_id,
        after.motion_node_id,
        STATIC_ENTRY_NODE,
        STATIC_SUCCESS_NODE,
    }, nodes, 2)

    capture.transitions[#capture.transitions + 1] = {
        kind = "manual_kamui_161_to_162",
        before = before,
        after = after,
        nodes = nodes,
    }
    runtime.saved = true
    save_capture()
end

re.on_frame(function()
    if not refresh_player() then return end
    if runtime.weapon_type ~= WEAPON_LONG_SWORD or runtime.bank_id ~= 100 then return end

    local current = current_snapshot()
    if runtime.previous ~= nil then
        if runtime.previous.motion_id ~= current.motion_id
            or runtime.previous.behavior_node_id ~= current.behavior_node_id
            or runtime.previous.motion_node_id ~= current.motion_node_id then
            runtime.history[#runtime.history + 1] = current
            while #runtime.history > MAX_HISTORY do table.remove(runtime.history, 1) end
        end
        if runtime.previous.motion_id == KAMUI_READY_MOTION
            and current.motion_id == KAMUI_SUCCESS_MOTION then
            collect_kamui_transition(runtime.previous, current)
        end
    else
        runtime.history[#runtime.history + 1] = current
    end
    runtime.previous = current
end)

re.on_draw_ui(function()
    if not imgui.tree_node("神威居合动作采集") then return end
    imgui.text("用途：只记录手动成功的 Motion 161 -> 162 过渡")
    imgui.text("当前武器 / 动作：" .. tostring(runtime.weapon_type) .. " / " .. tostring(runtime.motion_id))
    imgui.text("行为节点：" .. tostring(runtime.behavior_node_id))
    imgui.text("动作层节点：" .. tostring(runtime.motion_node_id))
    imgui.text("已捕获成功过渡：" .. tostring(runtime.transition_count))
    imgui.text("输出：reframework/data/" .. CAPTURE_PATH)
    if runtime.last_error ~= "无" then imgui.text("错误：" .. runtime.last_error) end
    if imgui.button("保存当前采集") then save_capture() end
    imgui.same_line()
    if imgui.button("清空采集并重新捕获") then
        capture.transitions = {}
        runtime.transition_count = 0
        runtime.saved = false
        runtime.previous = nil
        runtime.history = {}
        save_capture()
    end
    imgui.tree_pop()
end)

runtime.transition_count = type(capture.transitions) == "table" and #capture.transitions or 0
runtime.saved = runtime.transition_count > 0
log.info("[LongSwordKamuiCapture] loaded; waiting for manual Motion 161 -> 162")
