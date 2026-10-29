import { readFile } from "node:fs/promises";
import { LuaFactory } from "wasmoon";

export const root = new URL("../", import.meta.url);

export async function createLua() {
  const factory = new LuaFactory();
  for (const file of ["main.lua", "lib/json.lua", "lib/uuid.lua",
    "examples/settingssharedebug/main.lua", "examples/settingssharedebug/plugin.json"]) {
    await factory.mountFile(`/${file}`, await readFile(new URL(file, root), "utf8"));
  }
  return factory.createEngine();
}
