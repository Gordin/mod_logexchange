-- Based on XXX
-- Copyright (C) 2014 Andreas Guth
--
-- This file is MIT/X11 licensed.
--

-- local serialize = require"util.json".encode, require"util.json".decode;
local tostring = tostring;
-- local time_now = os.time;
local module_host = module:get_host();

local st = require "util.stanza";
local keys = require "util.iterators".keys;
local datetime = require "util.datetime";
local jid = require "util.jid";
local uuid = require "util.uuid";
local filters = require "util.filters";
local dataforms_new = require "util.dataforms".new;
local adhoc_simple = require "util.adhoc".new_simple_form;
local adhoc_initial = require "util.adhoc".new_initial_data_form;
local timer = require "util.timer";
local status_time = 1
local queue_time = 1
local stats = module:require("mod_statistics/stats").stats;

function string.ends(String,End)
   return End=='' or string.sub(String,-string.len(End))==End
end


local eventlog_new = module:require "eventlog".new;
local log_new = module:require "eventlog".new_log;
local eventlog_from_logs = module:require "eventlog".new_from_logs;

module:depends("adhoc");
module:depends("statistics");
local adhoc_new = module:require "adhoc".new;

module:add_feature("urn:xmpp:logexchange");

local stanza_sessions = {};
local log_sessions_by_jid = {};
local status_sessions = {};
local open_sessions = {};
local log_queues = {};
local p2p_sessions = {};
local smartInOut = {};


local status_providers = {
    total_component     = { label = "Connected components",
                            get = stats.total_component.get},
    total_users         = { label = "Online users",
                            get = stats.total_users.get},
    memory_used         = { label = "Memory used by Prosody (Bytes)",
                            get = stats.memory_used.get},
    total_s2sin         = { label = "Incoming s2s connections",
                            get = stats.total_s2sin.get},
    total_s2sout        = { label = "Outgoing s2s connections",
                            get = stats.total_s2sout.get},
    memory_returnable   = { label = "Not Garbage collected memory",
                            get = stats.memory_returnable.get},
    memory_unused       = { label = "Unused memory",
                            get = stats.memory_unused.get},
    memory_lua          = { label = "Memory used by lua",
                            get = stats.memory_lua.get},
    up_since            = { label = "Uptime as timestamp",
                            get = stats.up_since.get},
    time                = { label = "Current Server time",
                            get = stats.time.tostring},
    cpu                 = { label = "CPU usage of Prosody (%)",
                            get = stats.cpu.get},
    memory_allocated    = { label = "Memory allocated for Prosody (Bytes)",
                            get = stats.memory_allocated.get},
    total_c2s           = { label = "Total c2s connections",
                            get = stats.total_c2s.get},
    total_s2s           = { label = "Total s2s connections",
                            get = stats.total_s2s.get},
};

local PrettyPrint = require "PrettyPrint"
local pp = function (x) if type(x) == "table" then return PrettyPrint(x) else return tostring(x) end end
local info = function(x)
    module:log("info", pp(x))
end

local logstop_layout = dataforms_new{
    title = "Stop a logging session";
    instructions = "Fill out this form to stop a logging session.";

    { name = "logid", type = "text-single", required=true, value = "" };
};

local logchange_layout = dataforms_new{
    title = "Stop a logging session";
    instructions = "Fill out this form to reconfigure a logging session.";

    { name = "logid", type = "text-single", required=true, value = "" };
};

-- creates a table that can be passed as initial values for a form
-- takes da data.fields table from a form response and the layout
local function prepare_fields(fields, layout)
    local new_fields = {}
    for _, field in ipairs(layout) do
        if field.type == "list-multi" and fields[field.name] then
            local new_field_entry = {}
            info("Field: "..pp(field))
            for _,option in ipairs(field.value) do
                -- info("Field: "..pp(field))
                -- info("Option: "..pp(option))
                local x = {}
                if type(option) == "table" then
                    x = {label = option.label, value = option.value}
                else
                    x = {label = option, value = option}
                end
                for _, default in ipairs(fields[field.name]) do
                    info("x.name: "..tostring(x.value).." name: "..tostring(default))
                    if x.value == default then
                        x.default = true
                    end
                end
                table.insert(new_field_entry, x)
            end
            new_fields[field.name] = new_field_entry
        elseif field.type == "list-single" and fields[field.name] then
            local new_field_entry = {}
            info("Field: "..pp(field))
            for _,option in ipairs(field.value) do
                -- info("Field: "..pp(field))
                -- info("Option: "..pp(option))
                local x = {}
                if type(option) == "table" then
                    x = {label = option.label, value = option.value}
                else
                    x = {label = option, value = option}
                end
                local default = fields[field.name]
                info("x.name: "..tostring(x.value).." name: "..tostring(default))
                if x.value == default then
                    x.default = true
                end
                table.insert(new_field_entry, x)
            end
            new_fields[field.name] = new_field_entry
        end
    end
    for name, value in pairs(fields) do
        if not new_fields[name] then
            new_fields[name] = value
        end
    end
    info(new_fields)
    return new_fields
end

local logstanza_layout = dataforms_new{
    title = "Start a stanza logging session";
    instructions = "Fill out this form to start a logging session.";

    { name = "logid", type = "hidden", required=true, value = "" };
    { name = "stanzatype", type = "list-multi", required=true, label = "Stanza types to log",
        value = { {label = "message",   value = "message",  default = true},
                  {label = "iq",        value = "iq",       default = true},
                  {label = "presence",  value = "presence", default = true} } };
    { name = "jid", type = "text-multi", label = "Filter Stanzas by JID (regex)" };
    { name = "conditions", type = "list-multi", label = "Filter Stanzas error conditions",
        value = { {label = "All stanzas",               value = "all",                      default = true},
                  {label = "Only errors",               value = "only"},
                  {label = "Without errors",            value = "none"},
                  {label = "bad-request",               value = "bad-request"},
                  {label = 'conflict',                  value = "conflict"},
                  {label = 'feature-not-implemented',   value = "feature-not-implemented"},
                  {label = 'forbidden',                 value = "forbidden"},
                  {label = 'gone',                      value = "gone"},
                  {label = 'internal-server-error',     value = "internal-server-error"},
                  {label = 'item-not-found',            value = "item-not-found"},
                  {label = 'jid-malformed',             value = "jid-malformed"},
                  {label = 'not-acceptable',            value = "not-acceptable"},
                  {label = 'not-allowed',               value = "not-allowed"},
                  {label = 'not-authorized',            value = "not-authorized"},
                  {label = 'policy-violation',          value = "policy-violation"},
                  {label = 'recipient-unavailable',     value = "recipient-unavailable"},
                  {label = 'redirect',                  value = "redirect"},
                  {label = 'registration-required',     value = "registration-required"},
                  {label = 'remote-server-not-found',   value = "remote-server-not-found"},
                  {label = 'remote-server-timeout',     value = "remote-server-timeout"},
                  {label = 'resource-constraint',       value = "resource-constraint"},
                  {label = 'service-unavailable',       value = "service-unavailable"},
                  {label = 'subscription-required',     value = "subscription-required"},
                  {label = 'undefined-condition',       value = "undefined-condition"},
                  {label = 'unexpected-request',        value = "unexpected-request"},
                  {label = 'undefined-condition',       value = "undefined-condition"}, }; };
    { name = "input", type = "text-multi", label = "Filter with query" };
    { name = "top", type = "boolean", label = "Only log top-tag", value = true };
    { name = "output", type = "text-single", label = "Select logged output with query (if not using top)" };
    { name = "direction", type = "list-single", required=true, label = "Only log stanzas with specified directon",
        value = { {label = "Only incoming", value = "StanzaIn"},
                  {label = "Only outgoing", value = "StanzaOut"},
                  {label = "Both",          value = "both"},
                  {label = "Smart (both, but log each stanza only once)",  value = "smart", default = true} } };
    { name = "private", type = "boolean", label = "Filter private data from stanzas", value = true };
    { name = "iqresponse", type = "boolean", label = "Log responses to matched iq stanzas", value = false };
};

local logstatus_layout_template = {
    title = "Start a status logging session";
    instructions = "Fill out this form to start a logging session.";

    { name = "logid", type = "hidden", required=true, value = "" };
    { name = "statustype", type = "list-multi", label = "States you want to receive" };
        -- value = states_layout };
    { name = "interval", type = "text-single", label = "Minimum interval between updates" };
    { name = "onupdate", type = "boolean", label = "Only update changed values" };
};

local fill_statusform_layout = function()
    local statustypes = {};
    for name, stat in pairs(status_providers) do
        table.insert(statustypes, {label = stat.label, value = name})
    end
    for i,field in ipairs(logstatus_layout_template) do
        if field.name == "statustype" then
            field.value = statustypes
            break
        end
    end
    return logstatus_layout_template
end

local logstatus_layout = dataforms_new(fill_statusform_layout())

-- gets a logging session by id
local function get_session(id)
    if stanza_sessions[id] then
        return stanza_sessions[id]
    elseif status_sessions[id] then
        return status_sessions[id]
    end
    return nil
end

-- generates a new ID or loging sessions that is not used
local function get_new_logid()
    local logid = string.gsub(uuid.generate(), "-.+", "")
    while get_session(logid) do
        logid = string.gsub(uuid.generate(), "-.+", "")
    end
    return logid
end

-- default values for stanzaforms + random id
local function fill_stanzaform(form)
    local logid = get_new_logid()
    open_sessions[logid] = "open"
    return { logid = logid }
end

-- default values for statusforms + random id
local function fill_statusform(form)
    local logid = get_new_logid()
    open_sessions[logid] = "open"

    return { logid = logid,
             interval = "10",
             onupdate = true}
end

-- figure out where a stanza is from (stanzas can miss the "from" attribute)
local function get_from(event, inout)
    if not event.stanza.attr.from then
        local to = event.stanza.attr.to
        if not to then
            if inout == "StanzaIn" then
                return event.origin.full_jid
            elseif inout == "StanzaOut" then
                return event.origin.host
            end
        end
        local session = event.origin
        local s_type = session["type"]
        if s_type == "c2s" or s_type == "c2s_unauthed" then
            -- module:log("info", "Host: "..session.host..", jid: "..session.full_jid..", to: "..tostring(to))
            if session.host == to then
                return session.full_jid
            elseif session.full_jid == to then
                return session.host
            else
                return session.full_jid
            end
        elseif s_type == "s2s" then
            if session.to_host == to then
                return session.from_host
            else
                return session.to_host
            end
        end
    end
    return event.stanza.attr.from
end

-- figure out where a stanza is from (stanzas can miss the "from" attribute)
local function get_to(event, inout)
    if not event.stanza.attr.to then
        local from = event.stanza.attr.from
        if not from then
            if inout == "StanzaIn" then
                return event.origin.host
            elseif inout == "StanzaOut" then
                return event.origin.full_jid
            end
        end
        local session = event.origin
        local s_type = session["type"]
        if s_type == "c2s" or s_type == "c2s_unauthed" then
            -- module:log("info", "Host: "..session.host..", jid: "..session.full_jid..", to: "..tostring(to))
            if session.host == from then
                return session.full_jid
            elseif session.full_jid == from then
                return session.host
            else
                return session.full_jid
            end
        elseif s_type == "s2s" then
            if session.to_host == from then
                return session.from_host
            else
                return session.to_host
            end
        end
    end
    return event.stanza.attr.to
end

-- wrapper for event_handler to make it compatible with filters
local function stanza_handler(stanza, session, inout)
    event_handler({stanza = stanza, origin = session}, inout)
    return stanza
end

-- is callod by stanza_hander which gets data from filters.
-- This function also works as a callback for module:hook
function event_handler(event, inout)
    -- info("Called with module_host: "..module_host)
    if not inout then
        inout = "Current stanza"
    end
    -- module:log("info", "Handling a stanza now")
    local stanza = event.stanza
    if stanza:find("{urn:xmpp:eventlog}log") then
        -- module:log("info", "Not handling eventlogs")
        return
    end

    local session = event.origin

    if not stanza.attr then
        -- info("Stanza without attr: '"..pp(event).."'")
        return
    end
    local from = get_from(event, inout) or "-"
    local to = get_to(event, inout) or "-"
    if to == "-" or from == "-" then
        -- info("No nothing: "..pp(session).."\n"..tostring(stanza))
        return
    end
    handle_stanza(stanza, from, to, inout)
end

function handle_stanza(stanza, from, to, inout, p2p)
    local wrong_host = true
    local _, fhost = jid.split(from)
    local _, thost = jid.split(from)
    if (fhost == module_host) or (thost == module_host) then
        wrong_host = false
    end
    if wrong_host then
        -- info("Wrong hostbla:\n"..pp(fhost).."\n"..pp(thost))
        return
    end

    local s_id = stanza.attr.id
    -- module:log("info", inout..": "..stanza.name..":"..tostring(s_id)..", from: "..tostring(from)..", to: "..to)
    -- module:log("info", "Looping stanza_sessions now")
    for id, log_session in pairs(stanza_sessions) do
        for iqid, _ in pairs(log_session.match_ids) do
            -- module:log("info", "Waiting for ".. tostring(iqid))
        end
        -- module:log("info", "Current log_session: "..pp(log_session))
        -- module:log("info", "Current log_session by "..log_session.jid)
        local matched = false
        if log_session.match_ids[s_id] then
            -- module:log("info", "Matched iqresponse ".. tostring(s_id) .. " for log "..id)
            matched = true
            log_session.match_ids[s_id] = nil
        else
            local direction = log_session.direction
            if direction == "smart" or direction == "both" or direction == inout then
                if direction == "StanzaOut" and smartInOut[s_id] then
                    smartInOut[s_id] = nil
                    matched = false
                elseif log_session.test(stanza, from, to) then
                    -- module:log("info", "Matched "..stanza.name.." ".. tostring(s_id) .. " for log "..id)
                    matched = true
                    -- make sure to match the response to an iq
                    if log_session.iqresponse and stanza.name == "iq" then
                        local t = stanza.attr["type"]
                        -- module:log("info", "IQ type is ".. tostring(t))
                        if t == "set" or t == "get" then
                            -- module:log("info", "Also matching response to ".. tostring(s_id))
                            log_session.match_ids[s_id] = true
                        end
                        -- elseif direction == "smart" and inout == "StanzaIn" then
                        --     if not string.ends(to, module_host) then
                        --         matched = false
                        --     end
                        -- end
                    end
                    if direction == "smart" and not string.ends(to, module_host) and s_id then
                        if inout == "StanzaIn" then
                            smartInOut[s_id] = true
                            inout = "StanzaInOut"
                        end
                    end
                end
            end
        end
        if matched then
            local log_content
            if log_session.top then
                log_content = stanza:top_tag()
            else
                local output = log_session.output
                -- info("Before: "..pp(stanza))
                log_content = output and stanza:find(output) or stanza
                -- info("Found: "..pp(log_content))
                if type(log_content) == "table" then
                    log_content = st.clone(log_content)
                    if log_session.private then
                        log_content = conceal_text(log_content)
                    end
                end
            end
            -- info("After: "..pp(log_content))
            local p2ptag = nil
            if p2p then
                p2ptag = {{name = "p2p", value = "true"}}
            end
            local logtag = log_new(log_content,
                                   {id = id,
                                    timestamp = datetime.datetime(),
                                    object = to,
                                    subject = from,
                                    module = inout},
                                    p2ptag)
            local lsjid = log_session.jid
            if not log_queues[lsjid] then
                log_queues[lsjid] = {}
            end
            local queue = log_queues[lsjid]
            table.insert(queue, logtag)
            if #queue > 200 then
                local logstanza = eventlog_from_logs(lsjid, module_host, queue)
                module:send(logstanza)
                log_queues[lsjid] = nil
            end
        end
    end
end

-- is called every second and sends oll logs stored in the queues
local function handle_queue()
    for jid, queue in pairs(log_queues) do
        local logstanza = eventlog_from_logs(jid, module_host, queue)
        module:send(logstanza)
        log_queues[jid] = nil
    end
    return queue_time
end

-- tests if a given pattern matches the from or to attributes of a stanza
-- also receives a from parameter, as it can be missing from stanzas
local function jid_test(pattern, stanza, from, to)
    local jid = "";
    local where = "both";

    if string.find(pattern, ":") then
        for fromto, pattern_jid in string.gmatch(pattern, "(%S*):(%S+)") do
            where = fromto
            jid = pattern_jid
        end
    else
        jid = pattern
    end
    -- module:log("info", "JID pattern:"..where..":"..jid.. ", stanza comes from "..from)
    if where == "from" then
        return string.find(jid, from)
    elseif where == "to" then
        return string.find(jid, to)
    elseif where == "both" then
        info("stanza.attr.to: "..tostring(stanza))
        return string.find(jid, to) or string.find(jid, from)
    end
end

local function condition_test_any(stanza)
    local error_type, condition, text = stanza:get_error()
    return condition
end

local function condition_test_none(stanza)
    local error_type, condition, text = stanza:get_error()
    return not condition
end

local function condition_test(stanza, conditions)
    info("Conditions: "..pp(conditions))
    local error_type, condition, text = stanza:get_error()
    return conditions[condition] or false
end

function Set_with_length (list)
    if not list then
        return {}, 0
    end
    local set, count = {}, 0
    for i, l in ipairs(list) do
        set[l] = true
        count = i
    end
    return set, count
end

local logstop_handler = adhoc_simple( logstop_layout, function (fields, err, data)
    local id, from = fields.logid, data.from
    module:log("info", "stop logid: "..id.." jid from: "..from)
    local session = get_session(id)

    if session and session.jid == from then
        session.remove()
        return { status = "completed", info = "Stanza logging session stopped." }
    end
    return { status = "canceled", info = "No session by that ID or not authorized." }
end)

local function create_stanza_closure(fields)
    local stanzatypes = Set_with_length(fields.stanzatype)

    local jidtests = {}
    if fields.jid then
        for jid in string.gmatch(fields.jid, "([^\n]+)") do
            table.insert(jidtests, function(stanza, from, to)
                return jid_test(jid, stanza, from, to)
            end)
        end
    end

    local conditions, cond_count = Set_with_length(fields.conditions)

    local wrapped_condition_test = condition_test
    if cond_count > 0 then
        -- all means all stanzas match, so don't test for anything
        if conditions["all"] then
            cond_count = 0
        -- only means only stanzas with error conditions
        elseif conditions["only"] then
            if cond_count == 1 then
                -- if "only" is the only conditions, accept all conditions
                wrapped_condition_test = condition_test_any
            end
            -- If other conditions are given, "only" is superfluous
        end
        -- none means only match stanzas without error conditions
        if conditions["none"] then
            wrapped_condition_test = condition_test_none
        end
    end

    local input_tests = {}
    if fields.input then
        for input_path in string.gmatch(fields.input, "([^\n]+)") do
            table.insert(input_tests, function(stanza)
                return stanza:find(input_path)
            end)
        end
    end

    return function (stanza, from, to)
        local matched = false

        if not stanzatypes[stanza.name] then
            info("stanza.name: "..pp(stanza.name).." stanzatypes: "..pp(stanzatypes))
            return false
        end

        -- first go through all prepared tests and return if any fail
        if #jidtests > 0 then
            matched = false
            for _, jidtest in ipairs(jidtests) do
                if jidtest(stanza, from, to) then
                    matched = true
                    break
                end
            end
            if matched == false then
                return false
            end
        end

        if cond_count > 0 then
            if not wrapped_condition_test(stanza, conditions) then
                return false
            end
        end

        if #input_tests > 0 then
            matched = false
            for _, input_test in ipairs(input_tests) do
                if input_test(stanza) then
                    matched = true
                    break
                end
            end
            if matched == false then
                return false
            end
        end

        -- the current stanza has been matched
        return true
    end
end

function conceal_text(stanza)
    if type(stanza) == "string" then
        return stanza
    end
    local replace_deep
    replace_deep = function(x)
        if not x then
            return x
        end

        for i,tag in ipairs(x) do
            if type(tag) == "string" then
                if x.name == "body" or #tag:match'^%s*(.*)' > 0 then
                    x[i] = string.gsub(tag, ".", "_")
                end
            elseif type(tag == "table") then
                replace_deep(tag)
            end
        end
    end
    replace_deep(stanza)
    return stanza
end

local logstanza_handler = adhoc_initial( logstanza_layout, fill_stanzaform, function (fields, err, data)
    module:log("info", "Fields: "..pp(fields))
    -- module:log("info", "Data: "..pp(data))
    if err then
        module:log("info", tostring(err))
        return { status = "canceled", info = "Error: "..tostring(err) }
    end

    local logid = fields.logid

    if not logid or not open_sessions[logid] == "open" then
        return { status = "canceled", info = "Wrong logid"}
    end

    local session_stanza_test = create_stanza_closure(fields)

    local stanza_session = {
        jid = data.from,
        test = session_stanza_test,
        iqresponse = fields.iqresponse,
        private = fields.private,
        fields = fields,
        match_ids = {},
        output = fields.output or nil ,
        top = fields.top,
        direction = fields.direction,
        log_type = "stanza",
        remove = function()
            stanza_sessions[logid] = nil
            log_sessions_by_jid[data.from][logid] = nil
        end,
    }

    module:log("info", "Added stanza_session "..logid)
    stanza_sessions[logid] = stanza_session
    open_sessions[logid] = nil
    if not log_sessions_by_jid[data.from] then
        log_sessions_by_jid[data.from] = {}
    end
    log_sessions_by_jid[data.from][logid] = stanza_session

    -- return { status = "completed", error = { message = "Account already exists" } };
    -- return { status = "completed", info = "Account successfully created" };
    -- return { status = "completed", error = { message = "Failed to write data to disk" } };
    -- return { status = "completed", error = { message = "Invalid data.\nPassword mismatch, or empty username" } };
    -- return { status = "completed", info = "Logging session started.", result = dataforms_new{title="Stanza Logging", instructions = "Stanza Logging session started."; } }
    return { status = "completed", info = "Logging session started." }
end)

local function create_status_table(fields)
    local statustypes = {}

    for _, s in pairs(fields.statustype) do
        if status_providers[s] then
            statustypes[s] = {get = status_providers[s].get}
        end
    end

    return statustypes
end

local logstatus_handler = adhoc_initial( logstatus_layout, fill_statusform, function (fields, err, data)
    module:log("info", "Fields: "..pp(fields))
    if err then
        module:log("info", tostring(err))
        return { status = "canceled", info = "Error: "..tostring(err) }
    end

    local logid = fields.logid

    if not logid or not open_sessions[logid] == "open" then
        return { status = "canceled", info = "Wrong logid"}
    end

    local statustypes = create_status_table(fields)

    if not tonumber(fields.interval) then
        fields.interval = 10
    end

    local status_session = {
        jid = data.from,
        statustypes = statustypes,
        interval = fields.interval,
        timer = fields.interval,
        onupdate = fields.onupdate,
        fields = fields,
        log_type = "status",
        remove = function()
            status_sessions[logid] = nil
            log_sessions_by_jid[data.from][logid] = nil
        end,
    }

    module:log("info", "Added status_session "..logid)
    status_sessions[logid] = status_session
    open_sessions[logid] = nil
    if not log_sessions_by_jid[data.from] then
        log_sessions_by_jid[data.from] = {}
    end
    log_sessions_by_jid[data.from][logid] = status_session
    return { status = "completed", info = "Logging session started." }
end)

-- Getting a list of log sessions
local loglist_layout = dataforms_new {
    title = "List of logging sessions";

    { name = "sessions", type = "text-multi", label = "The following log sessions are active for your account:" };
    { name = "types", type = "text-multi", label = "The log sessions have the following types:" };
};

-- handler for listing logging sessions
local function loglist_handler(self, data, state)
    local sessions = ""
    local types = ""
    if log_sessions_by_jid[data.from] then
        module:log("info", "Collecting log_sessions for jid"..data.from)
        local ids = {}
        local log_types = {}
        for id, log_session in pairs(log_sessions_by_jid[data.from]) do
            table.insert(ids, id)
            table.insert(log_types, log_session.log_type)
        end
        sessions = table.concat(ids, "\n");
        types = table.concat(log_types, "\n");
        module:log("info", "Collected log_sessions: "..pp(sessions))
    end
	return { status = "completed", result = { layout = loglist_layout; values = { sessions = sessions, types = types } } };
end

-- handler for reconfiguration of logging sessions
local logchange_handler = function (self, data, state)
    -- info(logstanza_layout)
    if state then
        if data.action == "cancel" then
            return { status = "canceled" };
        end

        local fields, err = logchange_layout:data(data.form);
        module:log("info", "Fields: "..pp(fields))

        -- module:log("info", "Data: "..pp(data))
        if err then
            module:log("info", tostring(err))
            return { status = "canceled", info = "Error: "..tostring(err) }
        end

        local logid = fields.logid
        local session = get_session(logid)
        if not session or session.jid ~= data.from then
            info("Session "..logid.." not found")
            return { status = "canceled", info = "Error: No Session by that ID for your JID" }
        end

        if session.log_type == "stanza" then
            -- test if the new configuration form has been sent
            local new_fields = logstanza_layout:data(data.form);
            if new_fields.input and new_fields.jid then
                -- info("New Stanza configuration: "..pp(new_fields))
                session.test = create_stanza_closure(new_fields)
                session.fields = new_fields
                session.output = new_fields.output or nil
                session.top = new_fields.top
                session.iqresponse = new_fields.iqresponse
                session.private = new_fields.private
                session.direction = new_fields.direction
                return { status = "completed", info = "Logging session reconfigured." }
            end

            -- no new form found, send form with old configuration
            info("sending stanzaform")
            local filled_in_form = {layout = logstanza_layout, values = prepare_fields(session.fields, logstanza_layout)}
            return { status = "executing", actions = {"complete", default = "complete"}, form = filled_in_form}, "executing";
        elseif session.log_type == "status" then
            -- test if the new configuration form has been sent
            local new_fields = logstatus_layout:data(data.form);
            if new_fields.statustype and new_fields.interval then
                -- info("New Stanza configuration: "..pp(new_fields))
                session.statustypes = create_status_table(new_fields)
                session.interval = new_fields.interval
                session.timer = session.interval
                session.onupdate = new_fields.onupdate
                session.fields = new_fields
                return { status = "completed", info = "Logging session reconfigured." }
            end

            info("sending statusform")
            local filled_in_form = {layout = logstatus_layout, values = prepare_fields(session.fields, logstatus_layout)}
            return { status = "executing", actions = {"complete", default = "complete"}, form = filled_in_form }, "executing";
        end

        info("not sure what we are sending: "..pp(session.form))
        return { status = "executing", actions = {"complete", default = "complete"}, form = session.form }, "executing";
        -- local layout = {}
        -- if session.log_type == "stanza" then
        --     layout = stanz
        -- elseif session.log_type == "status" then
        -- end
    else
        return { status = "executing", actions = {"next", "complete", default = "complete"}, form = logchange_layout }, "executing";
    end
end


-- handler for receiving p2p data
local function logp2p_handler(self, data, state)
    local session = p2p_sessions[data.from]
    if not session then
        session = {
            jid = data.from,
            count = 0
        }
        p2p_sessions[data.from] = session
    end

	-- return { status = "completed", result = { layout = loglist_layout; values = { sessions = sessions } } };
	return { status = "completed", info = "Now accepting p2p logs from this JID." };
end

local logstanza = adhoc_new("Log Stanzas",           "logexchange/stanza", logstanza_handler, "admin");
local logstatus = adhoc_new("Log States",            "logexchange/status", logstatus_handler, "admin");
local logchange = adhoc_new("Reconfigure Logging",   "logexchange/change", logchange_handler, "admin");
local logstop   = adhoc_new("Stop Logging",          "logexchange/stop",   logstop_handler,   "admin");
local loglist   = adhoc_new("List Logging Sessions", "logexchange/list",   loglist_handler,   "admin");
local logp2p    = adhoc_new("Send P2P Data",         "logexchange/p2p",    logp2p_handler);

module:provides("adhoc", logstanza);
module:provides("adhoc", logstatus);
module:provides("adhoc", logchange);
module:provides("adhoc", logstop);
module:provides("adhoc", loglist);
module:provides("adhoc", logp2p);

-- hook all incoming and outgoing stanzas

local function status_handler()
    for id, session in pairs(status_sessions) do
        local countdown = session.timer
        countdown = countdown - status_time
        if countdown <= 0 then
            local new_states = {}
            session.timer = session.interval
            for name, state in pairs(session.statustypes) do
                -- module:log("info", "state: "..pp(state))
                local value = state.get()
                if not session.onupdate or state.last_value ~= value then
                    -- module:log("info", "Last value: "..tostring(state.last_value).." New Value: "..tostring(value))
                    table.insert(new_states, {name = name, value = value})
                    state.last_value = value
                    -- module:log("info", "New last value: "..tostring(state.last_value))
                end
            end
            if #new_states > 0 then
                local logtag = log_new("",
                                       {id = id,
                                        timestamp = datetime.datetime(),
                                        subject = module_host,
                                        module = "status"},
                                       new_states)
                if not log_queues[session.jid] then
                    log_queues[session.jid] = {}
                end
                table.insert(log_queues[session.jid], logtag)
            end
        else
            session.timer = countdown
        end
    end
    return status_time
end


function stanza_filter(session)
    filters.add_filter(session, "stanzas/in",  function (stanza, session)
        return stanza_handler(stanza, session, "StanzaIn" )
    end);
    filters.add_filter(session, "stanzas/out", function (stanza, session)
        return stanza_handler(stanza, session, "StanzaOut")
    end);
end

function clean_up(session)
    if session and session["type"] == "c2s" then
        info("Client disconnected")
        local j1 = session["full_jid"]
        local j2 = jid.bare(session["full_jid"]).."/"..session["presence"]
        for _, j in ipairs({j1, j2}) do
            if type(log_sessions_by_jid[j]) == "table" then
                info("Removing log session for Client")
                for id, s in pairs(log_sessions_by_jid[j]) do
                    s.remove()
                end
            end
        end
    end
end

function get_p2p(session)
    if session and session["type"] == "c2s" then
        local jid = session["full_jid"]
    end
end

function handle_p2p(event)
    local stanza = event.stanza
    local to = stanza.attr.to
    if stanza:find("{urn:xmpp:eventlog}log") and to == module_host then
        -- info("Found p2plog stanza: "..pp(stanza))
        local from = stanza.attr.from
        if p2p_sessions[from] then
            stanza:maptags(function (log)
                local stanza = log[1][1]
                local p2pfrom = stanza.attr.from
                local p2pto = stanza.attr.to
                -- info("Log stanzas: "..pp(stanza))
                local inout = jid.bare(p2pfrom) == jid.bare(event["full_jid"]) and "StanzaIn" or "StanzaOut"
                handle_stanza(stanza, p2pfrom, p2pto, inout, true)
                return log
            end)
            return true
        end
    end
end


function module.load()
	if not(prosody and prosody.arg) then
		return;
	end
    status_time = 1
    queue_time = 1

    filters.add_filter_hook(stanza_filter);
    module:hook("resource-unbind", clean_up);
    module:hook("pre-message/host", handle_p2p, 9999);

    timer.add_task(status_time, status_handler);
    timer.add_task(queue_time, handle_queue);
end

function module.unload()
	filters.remove_filter_hook(stanza_filter);
    status_time = nil
    queue_time = nil
end
