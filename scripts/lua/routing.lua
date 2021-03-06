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

--- @module Routing
-- Used to dynamically handle nginx routing based on an object containing implementation details

local cjson = require "cjson"
local url = require "url"
local utils = require "lib/utils"
local request = require "lib/request"
-- load policies
local security = require "policies/security"
local mapping = require "policies/mapping"
local rateLimit = require "policies/rateLimit"
local backendRouting = require "policies/backendRouting"
local cors = require "cors"


local _M = {}

--- Main function that handles parsing of invocation details and carries out implementation
function _M.processCall(dataStore)
  -- Get resource object from redis
  local tenantId = ngx.var.tenant
  local gatewayPath = ngx.var.gatewayPath
  local i, j = ngx.var.request_uri:find("/api/([^/]+)")
  ngx.var.analyticsUri = ngx.var.request_uri:sub(j+1)
  if ngx.req.get_headers()["x-debug-mode"] == "true" then
    setRequestLogs()
  end
  local resourceKeys = dataStore:getAllResources(tenantId)
  local redisKey = _M.findResource(resourceKeys, tenantId, gatewayPath)
  if redisKey == nil then
    request.err(404, 'Not found.')
  end
  local obj = cjson.decode(dataStore:getResource(redisKey, "resources"))
  cors.processCall(obj)
  ngx.var.tenantNamespace = obj.tenantNamespace
  ngx.var.tenantInstance = obj.tenantInstance
  ngx.var.apiId = obj.apiId
  for verb, opFields in pairs(obj.operations) do
    if string.upper(verb) == ngx.req.get_method() then
      -- Check if auth is required
      local key
      if (opFields.security) then
        for _, sec in ipairs(opFields.security) do
          local result = security.process(dataStore, sec)
          if key == nil and sec.type ~= "oauth2" then
            key = result -- use key from either apiKey or clientSecret security policy
          end
        end
      end
      -- Set backend method
      if opFields.backendMethod ~= nil then
        setVerb(opFields.backendMethod)
      end
      -- Set backend upstream and uri
      backendRouting.setRoute(opFields.backendUrl)
      -- Parse policies
      if opFields.policies ~= nil then
        parsePolicies(dataStore, opFields.policies, key)
      end
      -- Log updated request headers/body info to access logs
      if ngx.req.get_headers()["x-debug-mode"] == "true" then
        setRequestLogs()
      end
      dataStore:close()
      return
    end
  end
  request.err(404, 'Whoops. Verb not supported.')
end

--- Find the correct redis key based on the path that's passed in
-- @param resourceKeys list of resourceKeys to search through
-- @param tenant tenantId
-- @param path path to look for
function _M.findResource(resourceKeys, tenant, path)
  -- Check for exact match
  local redisKey = utils.concatStrings({"resources:", tenant, ":", path})
  local cfRedisKey
  local cfUrl = ngx.req.get_headers()["x-cf-forwarded-url"]
  if cfUrl ~= nil and cfUrl ~= "" then
    local u = url.parse(cfUrl)
    cfRedisKey = utils.concatStrings({"resources:", tenant, ":", path, u.path})
    ngx.var.analyticsUri = (u.path == "") and "/" or u.path
    if next(u.query) ~= nil then
      ngx.var.analyticsUri = utils.concatStrings({ngx.var.analyticsUri, '?', u.query})
    end
  end
  for _, key in pairs(resourceKeys) do
    if key == redisKey or key == cfRedisKey then
      local res = {string.match(key, "([^:]+):([^:]+):([^:]+)")}
      ngx.var.gatewayPath = res[3]
      return key
    end
  end
  if cfUrl ~= nil and cfUrl ~= "" then
    return nil
  end
  -- Construct a table of redisKeys based on number of slashes in the path
  local keyTable = {}
  for i, key in pairs(resourceKeys) do
    local _, count = string.gsub(key, "/", "")
    -- handle cases where resource path is "/"
    if count == 1 and string.sub(key, -1) == "/" then
      count = count - 1
    end
    count = tostring(count)
    if keyTable[count] == nil then
      keyTable[count] = {}
    end
    table.insert(keyTable[count], key)
  end
  -- Check for proxy or path parameter matching
  local _, count = string.gsub(redisKey, "/", "")
  for i = count, 0, -1 do
    local countString = tostring(i)
    if keyTable[countString] ~= nil then
      for _, key in pairs(keyTable[countString]) do
        -- Check for exact match or path parameter match
        if key == redisKey or key == utils.concatStrings({redisKey, "/"}) or _M.pathParamMatch(key, redisKey) == true then
          local res = {string.match(key, "([^:]+):([^:]+):([^:]+)")}
          ngx.var.gatewayPath = res[3]
          return key
        end
      end
    end
    -- substring redisKey upto last "/"
    local index = redisKey:match("^.*()/")
    if index == nil then
      return nil
    end
    redisKey = string.sub(redisKey, 1, index - 1)
  end
  return nil
end

--- Check redis if resourceKey matches path parameters
-- @param key key that may have path parameter variables
-- @param resourceKey redis resourceKey to check if it matches path parameter
function _M.pathParamMatch(key, resourceKey)
  local pathParamVars = {}
  for w in string.gfind(key, "({%w+})") do
    w = string.sub(w, 2, string.len(w) - 1)
    pathParamVars[#pathParamVars + 1] = w
  end
  if next(pathParamVars) ~= nil then
    local pathPattern, count = string.gsub(key, "%{(%w*)%}", "([^:]+)")
    pathPattern = string.gsub(pathPattern, "%-", "%%-")
    local obj = {string.match(resourceKey, pathPattern)}
    if (#obj == count) then
      for i, v in pairs(obj) do
        ngx.ctx[pathParamVars[i]] = v
      end
      return true
    end
  end
  return false
end

--- Function to read the list of policies and send implementation to the correct backend
-- @param red redis client instance
-- @param obj List of policies containing a type and value field. This function reads the type field and routes it appropriately.
-- @param apiKey optional subscription api key
function parsePolicies(dataStore, obj, apiKey)
  for k, v in pairs (obj) do
    if v.type == 'reqMapping' then
      mapping.processMap(v.value)
    elseif v.type == 'rateLimit' then
      rateLimit.limit(dataStore, v.value, apiKey)
    elseif v.type == 'backendRouting' then
      backendRouting.setDynamicRoute(v.value)
    end
  end
end

--- Given a verb, transforms the backend request to use that method
-- @param v Verb to set on the backend request
function setVerb(v)
  local allowedVerbs = {'GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'HEAD', 'OPTIONS'}
  local verb = string.upper(v)
  if utils.tableContains(allowedVerbs, verb) then
    ngx.req.set_method(ngx[utils.concatStrings({"HTTP_", verb})])
  else
    ngx.req.set_method(ngx.HTTP_GET)
  end
end

function setRequestLogs()
  local requestHeaders = ngx.req.get_headers()
  for k, v in pairs(requestHeaders) do
    if k == 'authorization' or k == _G.clientSecretName then
      requestHeaders[k] = '[redacted]'
    end
  end
  ngx.var.requestHeaders = cjson.encode(requestHeaders)
  ngx.req.read_body()
  ngx.var.requestBody = ngx.req.get_body_data()
end

function _M.setResponseLogs()
  ngx.var.responseHeaders = cjson.encode(ngx.resp.get_headers())
  local resp_body = ngx.arg[1]
  ngx.ctx.buffered = (ngx.ctx.buffered or '') .. resp_body
  if ngx.arg[2] then
    ngx.var.responseBody = ngx.ctx.buffered
  end
end

return _M
