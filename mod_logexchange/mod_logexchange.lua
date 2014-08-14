-- Based on XXX
-- Copyright (C) 2014 Andreas Guth
--
-- This file is MIT/X11 licensed.
--
-- local st = require "util.stanza";

-- local serialize = require"util.json".encode, require"util.json".decode;
local tostring = tostring;
-- local time_now = os.time;
local module_host = module:get_host();

local datetime = require "util.datetime";
local jid = require "util.jid";
local uuid = require "util.uuid";
local filters = require "util.filters";
local dataforms_new = require "util.dataforms".new;
local adhoc_simple = require "util.adhoc".new_simple_form;
local adhoc_initial = require "util.adhoc".new_initial_data_form;


local find = require "rex_posix".find
local lom = require "lxp.lom"
local xpath = require "xpath"

local eventlog_new = module:require "eventlog".new;

module:depends("adhoc");
local adhoc_new = module:require "adhoc".new;

local log_sessions = {};
local status_sessions = {};
local open_sessions = {};

local PrettyPrint = require "PrettyPrint"
local pp = function (x) if type(x) == "table" then return PrettyPrint(x) else return tostring(x) end end

local logstop_layout = dataforms_new{
    title = "Stop a logging session";
    instructions = "Fill out this form to stop a logging session.";

    { name = "logid", type = "text-single", required=true, value = "" };
};

local logstanza_layout = dataforms_new{
    title = "Start a stanza logging session";
    instructions = "Fill out this form to start a logging session.";

    { name = "logid", type = "hidden", required=true, value = "" };
    { name = "stanzatype", type = "list-multi", required=true, label = "Stanza types to log",
        value = { "message", "iq", "presence" } };
    { name = "jid", type = "text-multi", label = "Filter Stanzas by JID (regex)" };
    { name = "conditions", type = "list-multi", label = "Filter Stanzas error conditions",
        value = { {label = "All stanzas", value = "all"},
                  {label = "Only errors", value = "onl"},
                  {label = "Without errors", value = "none"},
                  {label = "bad-request", value = "bad-request"},
                  {label = 'conflict', value = "conflict"},
                  {label = 'feature-not-implemented', value = "feature-not-implemented"},
                  {label = 'forbidden', value = "forbidden"},
                  {label = 'gone', value = "gone"},
                  {label = 'internal-server-error', value = "internal-server-error"},
                  {label = 'item-not-found', value = "item-not-found"},
                  {label = 'jid-malformed', value = "jid-malformed"},
                  {label = 'not-acceptable', value = "not-acceptable"},
                  {label = 'not-allowed', value = "not-allowed"},
                  {label = 'not-authorized', value = "not-authorized"},
                  {label = 'policy-violation', value = "policy-violation"},
                  {label = 'recipient-unavailable', value = "recipient-unavailable"},
                  {label = 'redirect', value = "redirect"},
                  {label = 'registration-required', value = "registration-required"},
                  {label = 'remote-server-not-found', value = "remote-server-not-found"},
                  {label = 'remote-server-timeout', value = "remote-server-timeout"},
                  {label = 'resource-constraint', value = "resource-constraint"},
                  {label = 'service-unavailable', value = "service-unavailable"},
                  {label = 'subscription-required', value = "subscription-required"},
                  {label = 'undefined-condition', value = "undefined-condition"},
                  {label = 'unexpected-request', value = "unexpected-request"},
                  {label = 'undefined-condition', value = "undefined-condition"}, }; };
    { name = "input", type = "text-multi", label = "Filter with XPath query" };
    { name = "output", type = "text-single", label = "Select logged output with XPath query" };
    { name = "iqresponse", type = "boolean", label = "Log responses to matched iq stanzas" };
    { name = "private", type = "boolean", label = "Filter private data from stanzas" };
};

local function fill_logid(form)
    local logid = uuid.generate()
    while log_sessions[logid] do
        logid = uuid.generate()
    end
    open_sessions[logid] = "open"
    return { logid = logid }
end

local function get_from(event)
    if not event.stanza.attr.from then
        local to = event.stanza.attr.to
        if not to then
            return nil
        end
        local session = event.origin
        local s_type = session["type"]
        if s_type == "c2s" then
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

local function stanza_handler(stanza, session, inout)
    event_handler({stanza = stanza, origin = session}, inout)
    return stanza
end

-- is callod by stanza_hander which gets data from filters.
-- This function also works for as a callback for module:hook
function event_handler(event, inout)
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

    local s_id = stanza.attr.id
    local from = get_from(event) or "-"
    local to = stanza.attr.to or "-"
    module:log("info", inout..": "..stanza.name..":"..tostring(s_id)..", from: "..tostring(from)..", to: "..to)
    -- module:log("info", "Looping log_sessions now")
    for id, log_session in pairs(log_sessions) do
        for iqid, _ in pairs(log_session.match_ids) do
            module:log("info", "Waiting for ".. tostring(iqid))
        end
        -- module:log("info", "Current log_session: "..pp(log_session))
        -- module:log("info", "Current log_session by "..log_session.jid)
        local matched = false
        if log_session.match_ids[s_id] then
            module:log("info", "Matched iqresponse ".. tostring(s_id) .. " for log "..id)
            matched = true
            log_session.match_ids[s_id] = nil
        elseif log_session.test(stanza, from) then
            module:log("info", "Matched "..stanza.name.." ".. tostring(s_id) .. " for log "..id)
            matched = true
            -- make sure to match the response to an iq
            if log_session.iqresponse and stanza.name == "iq" then
                local t = stanza.attr["type"]
                -- module:log("info", "IQ type is ".. tostring(t))
                if t == "set" or t == "get" then
                    -- module:log("info", "Also matching response to ".. tostring(s_id))
                    log_session.match_ids[s_id] = true
                end
            end
        else
            -- module:log("info", "Did not match")
        end
        if matched then
            local logstanza = eventlog_new(log_session.jid,
                                           module_host,
                                           log_session.output(stanza),
                                           id,
                                           datetime.datetime())
            module:send(logstanza)
        end
    end
end

-- tests if a given pattern matches the from or to attributes of a stanza
-- also receives a from parameter, as it can be missing from stanzas
local function jid_test(pattern, stanza, from)
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
    module:log("info", "JID pattern:"..where..":"..jid.. ", stanza comes from "..from)
    if where == "from" then
        return find(from, jid)
    elseif where == "to" then
        return find(stanza.attr.to, jid)
    elseif where == "both" then
        return find(stanza.attr.to, jid) or find(from, jid)
    end
end

local function condition_test_any(stanza)
    return stanza:get_child("error"):children()
end

local function condition_test_none(stanza)
    return not stanza:get_child("error"):children()
end

local function condition_test(stanza, conditions)
    local error_tags = stanza:get_child("error"):children()
    for tag in error_tags do
        if conditions[tag.name] then
            module:log("info", "Matched condition: "..tag.name)
            return true
        end
    end
    return false
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
    if log_sessions[id] and log_sessions[id].jid == from then
        log_sessions[id] = nil
        return { status = "completed", info = "Logging session stopped." }
    end
    return { status = "canceled", info = "No session by that ID or not authorized." }
end)

local logstanza_handler = adhoc_initial( logstanza_layout, fill_logid, function (fields, err, data)
    module:log("info", "Fields: "..pp(fields))
    -- module:log("info", "Data: "..pp(data))
    if err then
        module:log("info", tostring(err))
        return { status = "canceled", info = "Error: "..tostring(err) }
    end

    local logid = fields.logid

    if not open_sessions[logid] == "open" then
        return { status = "canceled", info = "Wrong logid"}
    end

    local stanzatypes = Set_with_length(fields.stanzatype)

    local jidtests = {}
    for jid in string.gmatch(fields.jid, "([^\n]+)") do
        table.insert(jidtests, function(stanza, from)
            return jid_test(jid, stanza, from)
        end)
    end

    local conditions, cond_count = Set_with_length(fields.conditions)

    if cond_count > 0 then
        local wrapped_condition_test = condition_test
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
    for input_path in string.gmatch(fields.input, "([^\n]+)") do
        table.insert(input_tests, function(stanza)
            return stanza:find(input_path)
        end)
    end

    local session_stanza_test = function (stanza, from)
        local matched = false

        if not stanzatypes[stanza.name] then
            return false
        end

        -- first go through all prepared tests and return if any fail
        if #jidtests > 0 then
            matched = false
            for _, jidtest in ipairs(jidtests) do
                if jidtest(stanza, from) then
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

    local log_session = {
        jid = data.from,
        test = session_stanza_test,
        iqresponse = fields.iqresponse,
        private = fields.private,
        form = data.form,
        match_ids = {},
        output = function(x) return x end
    }

    module:log("info", "Added log_session "..logid)
    log_sessions[logid] = log_session
    open_sessions[logid] = nil

    --         return { status = "completed", error = { message = "Account already exists" } };
    --             return { status = "completed", info = "Account successfully created" };
    --             return { status = "completed", error = { message = "Failed to write data to disk" } };
    --     return { status = "completed", error = { message = "Invalid data.\nPassword mismatch, or empty username" } };
    -- return { status = "completed", info = "Logging session started.", result = dataforms_new{title="Stanza Logging", instructions = "Stanza Logging session started."; } }
    return { status = "completed", info = "Logging session started." }
end)

local logstanza = adhoc_new("Log Stanzas", "logexchange/stanza", logstanza_handler, "admin");
-- local logstatus = adhoc_new("Log States", "logexchange/stanza", logstatus_handler, "admin");
-- local logchange = adhoc_new("Reconfigure Logging", "logexchange/change", logchange_handler, "admin");
local logstop = adhoc_new("Stop Logging", "logexchange/stop", logstop_handler, "admin");
-- local loglist = adhoc_new("List Logging Sessions", "logexchange/list", loglist_handler, "admin");

module:provides("adhoc", logstanza);
-- module:provides("adhoc", logstatus);
-- module:provides("adhoc", logchange);
module:provides("adhoc", logstop);
-- module:provides("adhoc", loglist);

filters.add_filter_hook(function (session)
    filters.add_filter(session, "stanzas/in",  function (stanza, session)
        return stanza_handler(stanza, session, "in" )
    end);
    filters.add_filter(session, "stanzas/out", function (stanza, session)
        return stanza_handler(stanza, session, "out")
    end);
end);
