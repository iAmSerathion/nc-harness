# OpenCode configuration

`opencode.json` and `service.json` are linked into `~/.config/opencode/` (direct: `install.sh`, isolated: the start script of `nc-work`). Only what is needed:

| Key | Why |
|---|---|
| `update: "disable"` | The version is pinned in `pins.txt`. OpenCode must not replace itself. |
| `share: "disabled"` | Sessions are not shared through opencode.ai. |
| `policies` | All providers denied, only `openrouter` allowed. Without it OpenCode offers free Zen models without a key; some of them may use input for training. |
| `service.json`: `disabled: true` | Otherwise OpenCode 2 starts a shared background service on every call without `--standalone`; it keeps running and keeps the environment of the first call, the key included. Switched off, every run gets a server of its own that ends with it; that also holds for `opencode` calls an agent makes in its session. Not for `opencode service start`/`restart`: they do not look at `service.json` and start the service detached with the whole environment. `nc opencode service` is therefore blocked; an agent in a running session on the host has the key, though, and can call `opencode service start` itself (in the container only the placeholder). (Location according to the 2.2.7 source: `~/.config/opencode/service.json`.) |

No default model: the model comes with the call (`--model openrouter/<provider>/<model>`) or later from `models.yaml`.

The subagents in `<config dir>/agents/` (implementer, tester, researcher) are not linked but generated: `nc generate` from `roles/` and `models.yaml`.

The key is not here. `nc opencode` (host) gives `OPENROUTER_API_KEY` to the started process only. `nc-work opencode` (container) gives OpenCode only the placeholder `nc-keyproxy` and, in `OPENCODE_CONFIG_CONTENT`, the address of a key proxy per run as `provider.openrouter.options.baseURL`; the real key is only in that proxy. OpenCode picks up the variable itself (catalog entry `env: ["OPENROUTER_API_KEY"]`).

Checked with OpenCode 2.2.7. `opencode.json` stays a fixed, linked file (`nc-infra` needs it in the snapshot). `nc generate` writes MCP servers from `mcp/servers.yaml` into a file of their own next to it, `<config dir>/opencode.jsonc` (line 1 `// GENERATED …`), which OpenCode 2.2.7 loads after `opencode.json`. Never `opencode mcp add --global`: it writes into the first existing file, that is through the link into this one.
