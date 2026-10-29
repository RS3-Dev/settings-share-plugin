import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import { createLua, root } from "./lua-runtime.mjs";

const manifest = JSON.parse(await readFile(new URL("plugin.json", root), "utf8"));
assert.deepEqual(manifest.requiredPermissions, [], "loading the dependency must not require an HTTP grant");
assert.deepEqual(manifest.optionalPermissions, ["httpAccess"], "network access still requires an explicit HTTP grant");

for (const file of (await readdir(new URL("tests/", root))).filter(name => name.endsWith("_test.lua")).sort()) {
  const lua = await createLua();
  try {
    await lua.doString(await readFile(new URL(`tests/${file}`, root), "utf8"));
  } catch (error) {
    console.error(`${file} failed: ${error.message}`);
    process.exitCode = 1;
  } finally { lua.global.close(); }
}
