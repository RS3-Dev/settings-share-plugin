import { readFile, readdir } from "node:fs/promises";
import { createLua, root } from "./lua-runtime.mjs";

for (const file of (await readdir(new URL("tests/", root))).filter(name => name.endsWith("_test.lua")).sort()) {
  const lua = await createLua();
  try {
    await lua.doString(await readFile(new URL(`tests/${file}`, root), "utf8"));
  } catch (error) {
    console.error(`${file} failed: ${error.message}`);
    process.exitCode = 1;
  } finally { lua.global.close(); }
}
