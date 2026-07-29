import { spawn } from "node:child_process"
import { realpathSync } from "node:fs"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const adapterPath = realpathSync(fileURLToPath(import.meta.url))
const bundledBin = resolve(dirname(adapterPath), "..", "..", "bin", "tmux-agent")
const bin = process.env.TMUX_AGENT_BIN || bundledBin

function report(state, name, event) {
  const nativeID = event.properties?.sessionID || event.properties?.info?.id || ""
  const message = event.properties?.error?.message || ""
  const child = spawn(bin, ["event", state, name], {
    env: {
      ...process.env,
      TMUX_AGENT_HARNESS: "opencode",
      TMUX_AGENT_NATIVE_ID: nativeID,
      TMUX_AGENT_MESSAGE: message,
    },
    detached: true,
    stdio: "ignore",
  })
  child.on("error", () => {})
  child.unref()
}

export const TmuxAgentManager = async () => ({
  event: async ({ event }) => {
    switch (event.type) {
      case "session.created":
        report("idle", event.type, event)
        break
      case "session.status":
        if (event.properties?.status?.type === "busy") report("working", event.type, event)
        if (event.properties?.status?.type === "idle") report("ready", event.type, event)
        break
      case "session.idle":
        report("ready", event.type, event)
        break
      case "permission.asked":
        report("attention", event.type, event)
        break
      case "session.error":
        report("turn-failed", event.type, event)
        break
      case "session.deleted":
        report("exited", event.type, event)
        break
    }
  },
})
