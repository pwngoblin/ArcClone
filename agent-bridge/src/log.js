// stderr-only logger: stdout is reserved for the JSON-RPC channel.
const LEVELS = { debug: 10, info: 20, warn: 30, error: 40 };

export function createLogger(level = "info", stream = process.stderr) {
  const threshold = LEVELS[level] ?? LEVELS.info;
  const write = (lvl, args) => {
    if (LEVELS[lvl] < threshold) return;
    const parts = args.map((a) => (a instanceof Error ? a.stack || a.message : typeof a === "string" ? a : JSON.stringify(a)));
    stream.write(`[agent-bridge] ${new Date().toISOString()} ${lvl.toUpperCase()} ${parts.join(" ")}\n`);
  };
  return {
    debug: (...a) => write("debug", a),
    info: (...a) => write("info", a),
    warn: (...a) => write("warn", a),
    error: (...a) => write("error", a),
  };
}
