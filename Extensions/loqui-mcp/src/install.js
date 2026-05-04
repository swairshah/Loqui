import { execFile } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const SERVER_NAME = "loqui";
const PACKAGE_NAME = "@swairshah/loqui-mcp";
const LOCAL_ENTRYPOINT = fileURLToPath(new URL("./index.js", import.meta.url));

const AGENTS = [
  {
    name: "Claude Code",
    bin: "claude",
    install: (launcher, global) => [
      "claude",
      "mcp",
      "add",
      SERVER_NAME,
      "-s",
      global ? "user" : "local",
      "--",
      ...shellLauncher(launcher),
    ],
    remove: (global) => ["claude", "mcp", "remove", SERVER_NAME, "-s", global ? "user" : "local"],
  },
  {
    name: "Codex",
    bin: "codex",
    install: (launcher) => ["codex", "mcp", "add", SERVER_NAME, "--", ...shellLauncher(launcher)],
    remove: () => ["codex", "mcp", "remove", SERVER_NAME],
  },
  {
    name: "Cursor",
    bin: "cursor",
    json: (launcher, global) => ({
      path: configPath(global ? "~/.cursor/mcp.json" : ".cursor/mcp.json"),
      build: () => ({ mcpServers: { [SERVER_NAME]: launcherConfig(launcher) } }),
    }),
  },
  {
    name: "Windsurf",
    bin: "windsurf",
    json: (launcher, global) => ({
      path: configPath(global ? "~/.windsurf/mcp.json" : ".windsurf/mcp.json"),
      build: () => ({ mcpServers: { [SERVER_NAME]: launcherConfig(launcher) } }),
    }),
  },
  {
    name: "OpenCode",
    bin: "opencode",
    json: (launcher, global) => {
      const command = shellLauncher(launcher);
      return {
        path: configPath(global ? "~/.config/opencode/opencode.json" : "opencode.json"),
        build: () => ({ mcp: { [SERVER_NAME]: { type: "local", command, enabled: true } } }),
      };
    },
  },
  {
    name: "Pi",
    bin: "pi",
    install: () => ["pi", "install", "npm:pi-mcp-adapter"],
    installCheck: () => hasPiPackage("npm:pi-mcp-adapter"),
    json: (launcher, global) => ({
      path: configPath(global ? "~/.pi/agent/mcp.json" : ".pi/mcp.json"),
      build: () => ({ mcpServers: { [SERVER_NAME]: launcherConfig(launcher) } }),
    }),
  },
];

export async function installMcp({ global = true, dryRun = false, local = false } = {}) {
  const launcher = local ? resolveLocalLauncher() : resolveLauncher(await resolveNpx());
  const results = await Promise.all(
    AGENTS.map((agent) => installAgent(agent, launcher, global, dryRun)),
  );

  let installed = 0;
  for (const result of results) {
    if (result.ok === undefined) continue;
    if (result.ok) {
      installed += 1;
      console.log(`ok ${result.agent.name} (${result.detail})`);
    } else {
      console.log(`fail ${result.agent.name}${result.detail ? ` (${result.detail})` : ""}`);
    }
  }

  if (installed === 0) {
    console.log("No supported agents detected. Install manually with this MCP command:");
    console.log(`${launcher.command} ${launcher.args.join(" ")}`);
  } else {
    console.log(`${dryRun ? "Would install" : "Installed"} Loqui MCP for ${installed} agent(s).`);
  }
}

async function installAgent(agent, launcher, global, dryRun) {
  if (!(await which(agent.bin))) return { agent };

  if (agent.install && !(await agent.installCheck?.())) {
    const args = agent.install(launcher, global);
    if (dryRun) return { agent, ok: true, detail: args.join(" ") };

    try {
      await exec(args[0], args.slice(1));
    } catch {
      if (!agent.remove) {
        if (!agent.json) return { agent, ok: false, detail: "CLI install failed" };
      } else {
        try {
          const remove = agent.remove(global);
          await exec(remove[0], remove.slice(1)).catch(() => {});
          await exec(args[0], args.slice(1));
        } catch {
          if (!agent.json) return { agent, ok: false, detail: "CLI install failed" };
        }
      }
    }
    if (!agent.json) return { agent, ok: true, detail: agent.bin };
  }

  if (agent.json) {
    const cfg = agent.json(launcher, global);
    if (dryRun) return { agent, ok: true, detail: cfg.path };

    try {
      const existing = await readJson(cfg.path);
      const merged = deepMerge(existing, cfg.build());
      await fs.mkdir(path.dirname(cfg.path), { recursive: true });
      await fs.writeFile(cfg.path, `${JSON.stringify(merged, null, 2)}\n`);
      return { agent, ok: true, detail: displayPath(cfg.path) };
    } catch (error) {
      return { agent, ok: false, detail: error.message };
    }
  }

  return { agent };
}

function launcherConfig(launcher) {
  const [command, ...args] = shellLauncher(launcher);
  return { command, args };
}

function shellLauncher(launcher) {
  return [
    process.env.SHELL || "/bin/sh",
    "-lc",
    [launcher.command, ...launcher.args].map(shellQuote).join(" "),
  ];
}

function resolveLauncher(command) {
  const args = command === "npx"
    ? ["-y", `${PACKAGE_NAME}@latest`, "mcp"]
    : [`${PACKAGE_NAME}@latest`, "mcp"];
  return { command, args };
}

function resolveLocalLauncher() {
  return { command: process.execPath, args: [LOCAL_ENTRYPOINT, "mcp"] };
}

function shellQuote(value) {
  const text = String(value);
  if (/^[A-Za-z0-9_./:@%+=,-]+$/.test(text)) return text;
  return `'${text.replace(/'/g, "'\\''")}'`;
}

async function resolveNpx() {
  if (await which("pnpx")) return "pnpx";
  if (await which("npx")) return "npx";
  if (await which("bunx")) return "bunx";
  return "npx";
}

async function which(bin) {
  const paths = String(process.env.PATH || "").split(path.delimiter);
  for (const dir of paths) {
    const candidate = path.join(dir, bin);
    try {
      await fs.access(candidate);
      return candidate;
    } catch {
      // Continue.
    }
  }
  return "";
}

function exec(command, args) {
  return new Promise((resolve, reject) => {
    execFile(command, args, { stdio: "ignore" }, (error) => {
      if (error) reject(error);
      else resolve();
    });
  });
}

async function readJson(filePath) {
  try {
    return JSON.parse(await fs.readFile(filePath, "utf8"));
  } catch {
    return {};
  }
}

async function hasPiPackage(pkg) {
  try {
    const settings = JSON.parse(await fs.readFile(configPath("~/.pi/agent/settings.json"), "utf8"));
    return Array.isArray(settings.packages) && settings.packages.includes(pkg);
  } catch {
    return false;
  }
}

function configPath(value) {
  if (value.startsWith("~/")) return path.join(os.homedir(), value.slice(2));
  return path.resolve(value);
}

function displayPath(value) {
  const home = os.homedir();
  return value.startsWith(`${home}/`) ? `~/${value.slice(home.length + 1)}` : value;
}

function deepMerge(target, source) {
  const result = { ...target };
  for (const key of Object.keys(source)) {
    const sv = source[key];
    const tv = target[key];
    if (isPlainObject(sv) && isPlainObject(tv)) result[key] = deepMerge(tv, sv);
    else result[key] = sv;
  }
  return result;
}

function isPlainObject(value) {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}
