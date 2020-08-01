--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
local core = require("apisix.core")
local schema_plugin = require("apisix.admin.plugins").check_schema
local type = type
local tostring = tostring
local local_conf = require("apisix.core.config_local").local_conf()
local etcd_version = local_conf.etcd.version or "v2"


local _M = {
    version = 0.1,
}


local function check_conf(id, conf, need_id)
    if not conf then
        return nil, {error_msg = "missing configurations"}
    end

    id = id or conf.id
    if need_id and not id then
        return nil, {error_msg = "missing route id"}
    end

    if not need_id and id then
        return nil, {error_msg = "wrong route id, do not need it"}
    end

    if need_id and conf.id and tostring(conf.id) ~= tostring(id) then
        return nil, {error_msg = "wrong route id"}
    end

    conf.id = id

    core.log.info("schema: ", core.json.delay_encode(core.schema.global_rule))
    core.log.info("conf  : ", core.json.delay_encode(conf))
    local ok, err = core.schema.check(core.schema.global_rule, conf)
    if not ok then
        return nil, {error_msg = "invalid configuration: " .. err}
    end

    local ok, err = schema_plugin(conf.plugins)
    if not ok then
        return nil, {error_msg = err}
    end

    return true
end


function _M.put(id, conf)
    local ok, err = check_conf(id, conf, true)
    if not ok then
        return 400, err
    end

    local key = "/global_rules/" .. id
    local res, err = core.etcd.set(key, conf)
    if not res then
        core.log.error("failed to put global rule[", key, "]: ", err)
        return 500, {error_msg = err}
    end

    return res.status, res.body
end


function _M.get(id)
    local key = "/global_rules"
    if id then
        key = key .. "/" .. id
    end
    local res, err = core.etcd.readdir(key)
    if not res then
        core.log.error("failed to get global rule[", key, "]: ", err)
        return 500, {error_msg = err}
    end

    return res.status, res.body
end


function _M.delete(id)
    local key = "/global_rules/" .. id
    -- core.log.info("key: ", key)
    local res, err = core.etcd.delete(key)
    if not res then
        core.log.error("failed to delete global rule[", key, "]: ", err)
        return 500, {error_msg = err}
    end

    return res.status, res.body
end


function _M.patch(id, conf, sub_path)
    if not id then
        return 400, {error_msg = "missing global rule id"}
    end

    if not conf then
        return 400, {error_msg = "missing new configuration"}
    end

    if not sub_path or sub_path == "" then
        if type(conf) ~= "table"  then
            return 400, {error_msg = "invalid configuration"}
        end
    end

    local key = "/global_rules/" .. id
    local res_old, err = core.etcd.get(key)
    if not res_old then
        core.log.error("failed to get global rule [", key, "]: ", err)
        return 500, {error_msg = err}
    end

    if res_old.status ~= 200 then
        return res_old.status, res_old.body
    end
    core.log.info("key: ", key, " old value: ",
                  core.json.delay_encode(res_old, true))

    local node_value = etcd_version == "v3" and res_old.body.kvs[1].value or res_old.body.node.value

    if sub_path and sub_path ~= "" then
        local code, err, node_val = core.table.patch(node_value, sub_path, conf)
        node_value = node_val
        if code then
            return code, err
        end
    else
        node_value = core.table.merge(node_value, conf);
    end

    core.log.info("new conf: ", core.json.delay_encode(node_value, true))

    local ok, err = check_conf(id, node_value, true)
    if not ok then
        return 400, err
    end

    -- TODO: this is not safe, we need to use compare-set
    local res, err = core.etcd.set(key, node_value)
    if not res then
        core.log.error("failed to set new global rule[", key, "]: ", err)
        return 500, {error_msg = err}
    end

    return res.status, res.body
end


return _M
