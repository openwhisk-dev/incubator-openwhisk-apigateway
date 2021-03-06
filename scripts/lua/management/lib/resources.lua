-- Copyright (c) 2016 IBM. All rights reserved.
--
--   Permission is hereby granted, free of charge, to any person obtaining a
--   copy of this software and associated documentation files (the "Software"),
--   to deal in the Software without restriction, including without limitation
--   the rights to use, copy, modify, merge, publish, distribute, sublicense,
--   and/or sell copies of the Software, and to permit persons to whom the
--   Software is furnished to do so, subject to the following conditions:
--
--   The above copyright notice and this permission notice shall be included in
--   all copies or substantial portions of the Software.
--
--   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
--   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
--   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
--   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
--   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
--   FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
--   DEALINGS IN THE SOFTWARE.

--- @module resources
-- Management interface for resources for the gateway

local utils = require "lib/utils"
local cjson = require "cjson"
local REDIS_FIELD = "resources"
local _M = {}

--- Helper function for adding a resource to redis and creating an nginx conf file
-- @param red
-- @param resource
-- @param gatewayPath
-- @param tenantObj
function _M.addResource(dataStore, resource, gatewayPath, tenantObj)
  -- Create resource object and add to redis
  local redisKey = utils.concatStrings({"resources:", tenantObj.id, ":", gatewayPath})
  local operations = resource.operations
  local apiId = resource.apiId
  local cors = resource.cors
  local resourceObj = dataStore:generateResourceObj(operations, apiId, tenantObj, cors)
  dataStore:createResource(redisKey, REDIS_FIELD, resourceObj)
  local indexKey = utils.concatStrings({"resources:", tenantObj.id, ":__index__"})
  dataStore:addResourceToIndex(indexKey, redisKey)
end

--- Helper function for deleting resource in redis and appropriate conf files
-- @param ds redis instance
-- @param gatewayPath path in gateway
-- @param tenantId tenant id
function _M.deleteResource(dataStore, gatewayPath, tenantId)
  local redisKey = utils.concatStrings({"resources:", tenantId, ":", gatewayPath})
  dataStore:deleteResource(redisKey, REDIS_FIELD)
  local indexKey = utils.concatStrings({"resources:", tenantId, ":__index__"})
  dataStore:deleteResourceFromIndex(indexKey, redisKey)
end

return _M
