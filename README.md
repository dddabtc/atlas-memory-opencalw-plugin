# appleseed-memory-opencalw-plugin

Appleseed-backed replacement for OpenClaw `memory_search`, `memory_get`, and `memory_save`.

## Purpose

Provide a stable, rollback-friendly way to route memory recall directly to Appleseed Memory,
without hot-editing OpenClaw stock plugin files.

Updated for the OpenClaw 2026.4.x plugin SDK:
- uses `definePluginEntry(...)`
- uses typed `before_prompt_build(event, ctx)` hooks
- uses SDK `jsonResult(...)`
- registers typed tools without `as any`

## Plugin ID

`appleseed-memory-opencalw-plugin`

## Features

- `memory_search`
- `memory_get`
- `memory_save`
- `memory_write` alias for save/update flows
- automatic appleseed memory recall injection before prompt build

## Install / Enable

```bash
openclaw plugins install /home/ubuntu/.openclaw/plugins/appleseed-memory-opencalw-plugin --link
openclaw gateway restart
```

Then verify:

```bash
openclaw status
openclaw plugins list | grep -E "appleseed-memory-opencalw-plugin|memory-core|memory-lancedb"
```

## Config

This plugin reads config from the existing OpenClaw plugin entry:

```json
{
  "plugins": {
    "entries": {
      "appleseed-memory-opencalw-plugin": {
        "enabled": true,
        "config": {
          "baseUrl": "http://100.119.6.34:6420",
          "timeoutMs": 5000,
          "autoInject": true,
          "autoInjectLimit": 5,
          "autoInjectMinScore": 0.04
        }
      }
    }
  }
}
```

It also respects these fallbacks, in order:
1. `agents.defaults.memorySearch.remote.baseUrl`
2. plugin `config.baseUrls`
3. plugin `config.baseUrl`
4. `APPLESEED_MEMORY_BASE_URL`
5. `APPLESEED_BASE_URL`

## Multi-Agent Identity

All API requests automatically include `agent_id`, `agent_role`, and `user_id` for multi-agent isolation. Configure via plugin config or environment variables:

```json
{
  "config": {
    "baseUrl": "http://100.119.6.34:6420",
    "agentId": "openclaw",
    "agentRole": "OpenClaw助手",
    "userId": "zdl"
  }
}
```

Or via environment variables: `APPLESEED_AGENT_ID`, `APPLESEED_AGENT_ROLE`, `APPLESEED_USER_ID`.

If not configured, the Appleseed server auto-fills `agent_id` from the client IP.

## Hermes Agent Installation

[Hermes Agent](https://github.com/NousResearch/hermes-agent) natively supports MCP servers. You can connect Appleseed Memory as an MCP tool server without this OpenClaw plugin.

### 1. Install the MCP proxy

```bash
cd /path/to/appleseed-memory
pip install -e .
```

### 2. Add to Hermes config

Edit `~/.hermes/config.yaml`:

```yaml
mcp_servers:
  appleseed-memory:
    command: "python3"
    args: ["-m", "appleseed_memory.mcp.remote_proxy"]
    env:
      APPLESEED_REMOTE_URL: "http://100.119.6.34:6420"
      APPLESEED_AGENT_ID: "hermes"
      APPLESEED_AGENT_ROLE: "Hermes助手"
      APPLESEED_USER_ID: "zdl"
```

This gives Hermes three tools: `mcp_appleseed-memory_memory_search`, `mcp_appleseed-memory_memory_store`, `mcp_appleseed-memory_memory_list`.

### 3. Verify

```bash
hermes chat
> /tools            # should list appleseed-memory tools
> search my preferences   # triggers memory_search
```

### Alternative: Direct HTTP (no MCP proxy needed)

If your Appleseed Memory server is reachable over HTTP, you can skip the MCP proxy and call the REST API directly from a Hermes skill or custom tool. The endpoints are:

| Method | Endpoint | Body |
|--------|----------|------|
| `POST` | `/memories/search` | `{"query": "...", "limit": 8, "agent_id": "hermes", "user_id": "zdl"}` |
| `POST` | `/memories` | `{"content": "...", "title": "...", "agent_id": "hermes", "user_id": "zdl"}` |
| `GET` | `/memories?user_id=zdl` | — |

## API Contract (Appleseed)

- Search: `POST /memories/search` with `{ query, limit }`
- Get: `GET /memories/{id}`
- Create: `POST /memories`
- Update: `PATCH /memories/{id}`

## Notes

- Keeps compatibility with Appleseed API endpoints already in use.
- Keeps existing OpenClaw config shape; no `openclaw.json` migration required.
- `memory_get` accepts either:
  - `appleseed:<uuid>`
  - any path containing an Appleseed UUID

## Rollback

```bash
openclaw plugins disable appleseed-memory-opencalw-plugin
openclaw plugins enable memory-core
openclaw gateway restart
```
