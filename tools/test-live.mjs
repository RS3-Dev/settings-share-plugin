// Opt-in integration check: actual Lua helper + a Node HTTP adapter, not native client bindings.
// Writes only synthetic records; never run automatically in CI or retry writes.
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { createLua, root } from "./lua-runtime.mjs";

const manifest = JSON.parse(await readFile(new URL("plugin.json", root), "utf8"));
const base = new URL(manifest.urls.service);
assert.equal(base.protocol, "https:");
assert.equal(base.pathname, "/");
const jobs = [];
const lua = await createLua();
const payload = 'settingsshare integration test\nquotes: " \\ tab:\t controls:\u0000\u0001 Unicode: café 雪 🎮';

async function http(path, options = {}) {
  const response = await fetch(new URL(path, base), {
    ...options, signal: AbortSignal.timeout(20_000), redirect: "error",
  });
  assert.equal(response.headers.get("cache-control"), "no-store");
  return response;
}

async function call(method, args, pluginName = "SettingsShareIntegrationTest") {
  lua.global.set("__input", JSON.stringify({ method, pluginName, args: Object.fromEntries(args.map((value, i) => [String(i + 1), value])) }));
  await lua.doString(`
    local input = Json.decode(__input)
    __result, __calls = nil, 0
    local function callback(value, problem, metadata)
      __calls = __calls + 1
      __result = Json.encode({ value = value, problem = problem, metadata = metadata })
    end
    local a = input.args
    local started, problem
    if input.method == "write" then started, problem = api.write(input.pluginName, a["1"], callback)
    elseif input.method == "read" then started, problem = api.read(input.pluginName, a["1"], callback)
    elseif input.method == "dump" then started, problem = api.dump.create(input.pluginName, a["1"], callback)
    else error("Unknown method") end
    assert(started ~= nil, problem)
    __started = started
    assert(__calls == 0)
    for _ = 1, 5 do tick() end
    assert(__calls == 0)
  `);
  assert.equal(jobs.length, 1, "one helper call must start exactly one request");
  const { id, path, body, contentType, userAgent } = jobs.shift();
  assert.equal(contentType, "application/json");
  assert.equal(userAgent, pluginName);
  const started = lua.global.get("__started");
  const response = await http(path, { method: "POST", headers: { "Content-Type": contentType, "User-Agent": userAgent }, body });
  const data = await response.text();
  lua.global.set("__response", JSON.stringify({ id, data, successful: response.ok, responseCode: response.status }));
  await lua.doString(`
    local result = Json.decode(__response)
    local request = active[result.id]
    request.data, request.successful, request.responseCode = result.data, result.successful, result.responseCode
    request.progressCallback(request)
    request.finished = true
    request.completionCallback(request)
    assert(__calls == 0, "network completion must not invoke a native callback")
    for _ = 1, 3 do tick() end
    assert(__calls == 1, "callback must run exactly once on Logic")
    tick()
    assert(__calls == 1)
    active[result.id] = nil
  `);
  return { ...JSON.parse(lua.global.get("__result")), status: response.status, started, sent: JSON.parse(body) };
}

function success(result, value, ttl) {
  assert.equal(result.status, 200, `${result.problem ?? "Request failed"}; retry after ${result.metadata?.retryAfterSeconds ?? "n/a"}s`);
  assert.equal(result.problem, undefined);
  assert.equal(result.value, value);
  assert.equal(result.metadata.expiresInSeconds, ttl);
}

function failure(result, status, code) {
  assert.equal(result.status, status);
  assert.equal(result.value, undefined);
  assert.equal(typeof result.problem, "string");
  assert.equal(result.metadata.code, code);
}

try {
  const health = await http("/healthz");
  assert.equal(health.status, 200);
  const info = await health.json();
  assert.equal(info.backend, "selfhosted-sqlite");
  assert.equal(info.services.share, "ok");
  assert.equal(info.services.dump, "ok");
  console.log("PASS live backend health (share, dump)");

  lua.global.set("__base", base.origin);
  lua.global.set("__send", (id, path, body, contentType, userAgent) => { jobs.push({ id, path, body, contentType, userAgent }); });
  await lua.doString(`
    Json = require("lib/json")
    active = {}
    local nextId, onLogic, inLogic = 0, nil, false
    Event = { Logic = { Subscribe = function(_, callback) onLogic = callback end } }
    PluginPermissions = { httpAccess = {} }
    Plugin = { urls = { service = __base }, HasPermission = function() return true end }
    function tick()
      inLogic = true
      onLogic()
      inLogic = false
    end
    HTTPRequest = { new = function(service, path)
      assert(inLogic and service == __base)
      nextId = nextId + 1
      local request = { id = nextId, finished = false, headers = {} }
      function request:AddHeader(name, value)
        self.headers[name] = value
      end
      function request:Post(body, completion, progress, ...)
        assert(inLogic and type(completion) == "function" and type(progress) == "function" and select("#", ...) == 0)
        self.completionCallback, self.progressCallback = completion, progress
        __send(self.id, path, body, self.headers["Content-Type"], self.headers["User-Agent"])
      end
      active[request.id] = request
      return request
    end }
    api = dofile("main.lua")
  `);

  const share = await call("write", [payload]);
  success(share, share.started, 604800);
  assert.equal(share.sent.code, share.started);
  console.log("PASS client-generated share UUID confirmed by live backend");
  for (const code of [share.value, `  ${share.value.toUpperCase()}\n`]) {
    success(await call("read", [code]), payload, 604800);
  }
  console.log("PASS share round trip, caller User-Agent headers, code normalization, seven-day TTL response");
  const limited = await call("write", ["synthetic rate-limit probe"]);
  failure(limited, 429, "rate_limited");
  assert.equal(limited.metadata.retryable, true);
  assert(limited.metadata.retryAfterSeconds > 0);
  failure(await call("read", [randomUUID()]), 404, "not_found_or_expired");
  failure(await call("read", ["invalid"]), 400, "invalid_code");
  failure(await call("read", ["000000000000000000000000"]), 404, "not_found_or_expired");
  console.log("PASS share rate-limit metadata, invalid/missing/legacy-code errors");

  const dump = await call("dump", [payload]);
  success(dump, dump.value, 86400);
  assert.match(dump.value, /^[0-9a-f-]{36}$/);
  assert.equal(dump.metadata.downloadUrl, new URL("/dump", base).href);
  const download = () => http("/api/v1/settings-dump/download", {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ code: dump.value }),
  });
  const first = await download();
  assert.equal(first.status, 200);
  assert.equal(first.headers.get("content-disposition"), 'attachment; filename="settings-dump.txt"');
  assert.equal(await first.text(), payload);
  const second = await download();
  assert.equal(second.status, 404);
  assert.equal((await second.json()).error.code, "not_found_or_expired");
  console.log("PASS dump creation, 24-hour TTL, correct public URL, exact download, one redemption");

  const page = await http("/dump");
  assert.equal(page.status, 200);
  assert.match(page.headers.get("content-type"), /text\/html/);
  const privacy = await http("/privacy");
  assert.equal(privacy.status, 200);
  assert.match(await privacy.text(), /self-hosted infrastructure using SQLite/);
  console.log("PASS public download page and current self-hosted privacy notice");
  console.log("Live Lua/backend compatibility passed. Native RuneScape HTTP/UI bindings are not exercised.");
} finally { lua.global.close(); }
