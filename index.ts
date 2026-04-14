import {
  definePluginEntry,
  type AnyAgentTool,
  type OpenClawPluginApi,
  type OpenClawPluginConfigSchema,
  type PluginHookBeforePromptBuildEvent,
  type PluginHookAgentContext,
} from "openclaw/plugin-sdk/plugin-entry";

// jsonResult was removed from openclaw/plugin-sdk in 2026.3.22+
// Inlined here to avoid import errors
function jsonResult(payload: unknown) {
  return {
    content: [{ type: "text" as const, text: JSON.stringify(payload, null, 2) }],
    _jsonPayload: payload,
  };
}

const DEFAULT_BASE_URLS: string[] = [];
const PLUGIN_ID = "appleseed-memory-opencalw-plugin";
const DEFAULT_TIMEOUT_MS = 5000;

type AppleseedPluginConfig = {
  baseUrl?: string;
  baseUrls?: string[];
  timeoutMs?: number;
  autoInject?: boolean;
  autoInjectLimit?: number;
  autoInjectMinScore?: number;
  agentId?: string;
  agentRole?: string;
  userId?: string;
};

type AppleseedSearchItem = {
  id: string;
  title?: string;
  content?: string;
  score?: number;
  updated_at?: string;
};

type AppleseedMemoryRecord = {
  id: string;
  title?: string;
  content?: string;
  created_at?: string;
  updated_at?: string;
};

type ToolParams = Record<string, unknown>;

const configJsonSchema = {
  type: "object",
  additionalProperties: false,
  properties: {
    baseUrl: { type: "string" },
    baseUrls: { type: "array", items: { type: "string" } },
    timeoutMs: { type: "number", minimum: 500 },
    autoInject: { type: "boolean", default: true },
    autoInjectLimit: { type: "number", minimum: 1, maximum: 20, default: 5 },
    autoInjectMinScore: { type: "number", minimum: 0, maximum: 1, default: 0.04 },
    agentId: { type: "string" },
    agentRole: { type: "string" },
    userId: { type: "string" },
  },
} as const;

const configSchema: OpenClawPluginConfigSchema = {
  jsonSchema: configJsonSchema,
  validate(value) {
    const cfg = (value ?? {}) as Record<string, unknown>;
    const errors: string[] = [];

    if (value != null && (typeof value !== "object" || Array.isArray(value))) {
      return { ok: false, errors: ["Plugin config must be an object."] };
    }

    for (const key of Object.keys(cfg)) {
      if (!(key in configJsonSchema.properties)) {
        errors.push(`Unknown config key: ${key}`);
      }
    }

    if (cfg.baseUrl != null && typeof cfg.baseUrl !== "string") {
      errors.push("baseUrl must be a string.");
    }

    if (cfg.baseUrls != null) {
      if (!Array.isArray(cfg.baseUrls) || cfg.baseUrls.some((v) => typeof v !== "string")) {
        errors.push("baseUrls must be an array of strings.");
      }
    }

    if (cfg.timeoutMs != null && (!Number.isFinite(cfg.timeoutMs) || Number(cfg.timeoutMs) < 500)) {
      errors.push("timeoutMs must be a number >= 500.");
    }

    if (cfg.autoInject != null && typeof cfg.autoInject !== "boolean") {
      errors.push("autoInject must be a boolean.");
    }

    if (
      cfg.autoInjectLimit != null &&
      (!Number.isFinite(cfg.autoInjectLimit) || Number(cfg.autoInjectLimit) < 1 || Number(cfg.autoInjectLimit) > 20)
    ) {
      errors.push("autoInjectLimit must be a number between 1 and 20.");
    }

    if (
      cfg.autoInjectMinScore != null &&
      (!Number.isFinite(cfg.autoInjectMinScore) || Number(cfg.autoInjectMinScore) < 0 || Number(cfg.autoInjectMinScore) > 1)
    ) {
      errors.push("autoInjectMinScore must be a number between 0 and 1.");
    }

    return errors.length > 0 ? { ok: false, errors } : { ok: true, value };
  },
  uiHints: {
    baseUrl: { label: "Appleseed base URL", placeholder: "http://100.119.6.34:6420" },
    baseUrls: { label: "Appleseed base URLs", help: "Tried in order until one responds.", advanced: true },
    timeoutMs: { label: "Request timeout (ms)", advanced: true },
    autoInject: { label: "Enable auto-recall" },
    autoInjectLimit: { label: "Auto-recall result limit", advanced: true },
    autoInjectMinScore: { label: "Auto-recall minimum score", advanced: true },
    agentId: { label: "Agent ID", placeholder: "openclaw" },
    agentRole: { label: "Agent role (human-readable)", placeholder: "OpenClaw助手" },
    userId: { label: "User ID for tenant isolation", placeholder: "default" },
  },
};

function normalizeBase(raw: string): string {
  return raw.replace(/\/+$/, "");
}

function getPluginConfig(api: OpenClawPluginApi): AppleseedPluginConfig {
  const entry = api.config?.plugins?.entries?.[PLUGIN_ID] as
    | { config?: AppleseedPluginConfig }
    | AppleseedPluginConfig
    | undefined;

  if (entry && "config" in entry && entry.config && typeof entry.config === "object") {
    return entry.config;
  }
  return (entry ?? {}) as AppleseedPluginConfig;
}

function resolveConfigBaseUrls(api: OpenClawPluginApi): string[] {
  const dedupe = (values: string[]): string[] => {
    const out: string[] = [];
    const seen = new Set<string>();
    for (const value of values) {
      if (!seen.has(value)) {
        seen.add(value);
        out.push(value);
      }
    }
    return out;
  };

  const cfg = getPluginConfig(api);
  const remoteBase = api.config?.agents?.defaults?.memorySearch?.remote?.baseUrl;

  if (typeof remoteBase === "string" && remoteBase.trim()) {
    return dedupe([normalizeBase(remoteBase.trim()), ...DEFAULT_BASE_URLS]);
  }

  const fromConfig = Array.isArray(cfg.baseUrls)
    ? cfg.baseUrls.filter((v) => typeof v === "string" && v.trim().length > 0).map((v) => normalizeBase(v.trim()))
    : [];
  if (fromConfig.length > 0) return dedupe([...fromConfig, ...DEFAULT_BASE_URLS]);

  if (typeof cfg.baseUrl === "string" && cfg.baseUrl.trim()) {
    return dedupe([normalizeBase(cfg.baseUrl.trim()), ...DEFAULT_BASE_URLS]);
  }
  if (process.env.APPLESEED_MEMORY_BASE_URL?.trim()) {
    return dedupe([normalizeBase(process.env.APPLESEED_MEMORY_BASE_URL.trim()), ...DEFAULT_BASE_URLS]);
  }
  if (process.env.APPLESEED_BASE_URL?.trim()) {
    return dedupe([normalizeBase(process.env.APPLESEED_BASE_URL.trim()), ...DEFAULT_BASE_URLS]);
  }
  return DEFAULT_BASE_URLS;
}

function resolveIdentity(api: OpenClawPluginApi): Record<string, string> {
  const cfg = getPluginConfig(api);
  const identity: Record<string, string> = {};
  const agentId = cfg.agentId || process.env.APPLESEED_AGENT_ID;
  const agentRole = cfg.agentRole || process.env.APPLESEED_AGENT_ROLE;
  const userId = cfg.userId || process.env.APPLESEED_USER_ID;
  if (agentId) identity.agent_id = agentId;
  if (agentRole) identity.agent_role = agentRole;
  if (userId) identity.user_id = userId;
  return identity;
}

function resolveTimeoutMs(api: OpenClawPluginApi): number {
  const cfg = getPluginConfig(api);
  const n = Number(cfg.timeoutMs);
  return Number.isFinite(n) && n >= 500 ? Math.floor(n) : DEFAULT_TIMEOUT_MS;
}

async function fetchJsonFromAppleseed(api: OpenClawPluginApi, path: string, init?: RequestInit): Promise<unknown> {
  const bases = resolveConfigBaseUrls(api);
  const timeoutMs = resolveTimeoutMs(api);
  const errors: string[] = [];

  if (!bases.length) {
    throw new Error("Appleseed base URL not configured");
  }

  for (const base of bases) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const res = await fetch(`${base}${path}`, { ...(init ?? {}), signal: controller.signal });
      if (!res.ok) {
        errors.push(`${base}: HTTP ${res.status}`);
        continue;
      }
      return await res.json();
    } catch (err) {
      errors.push(`${base}: ${err instanceof Error ? err.message : String(err)}`);
    } finally {
      clearTimeout(timer);
    }
  }
  throw new Error(`Appleseed unavailable (${errors.join("; ")})`);
}

async function appleseedSearch(api: OpenClawPluginApi, query: string, limit: number): Promise<AppleseedSearchItem[]> {
  const data = (await fetchJsonFromAppleseed(api, "/memories/search", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ query, limit, ...resolveIdentity(api) }),
  })) as { results?: AppleseedSearchItem[] };
  return Array.isArray(data?.results) ? data.results : [];
}

async function appleseedGet(api: OpenClawPluginApi, id: string): Promise<AppleseedMemoryRecord> {
  return (await fetchJsonFromAppleseed(api, `/memories/${encodeURIComponent(id)}`)) as AppleseedMemoryRecord;
}

async function appleseedSave(
  api: OpenClawPluginApi,
  params: {
    id?: string;
    title?: string;
    content?: string;
    importance?: number;
    confidence?: number;
    source?: string;
    sourceThreadId?: string | null;
    labels?: string[];
    metadata?: Record<string, unknown>;
  },
): Promise<AppleseedMemoryRecord> {
  const payload: Record<string, unknown> = {};
  if (params.title !== undefined) payload.title = params.title;
  if (params.content !== undefined) payload.content = params.content;
  if (params.importance !== undefined) payload.importance = params.importance;
  if (params.confidence !== undefined) payload.confidence = params.confidence;
  if (params.source !== undefined) payload.source = params.source;
  if (params.sourceThreadId !== undefined) payload.source_thread_id = params.sourceThreadId;
  if (params.labels !== undefined) payload.labels = params.labels;
  if (params.metadata !== undefined) payload.metadata = params.metadata;

  const identity = resolveIdentity(api);

  if (params.id) {
    return (await fetchJsonFromAppleseed(api, `/memories/${encodeURIComponent(params.id)}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ ...payload, ...identity }),
    })) as AppleseedMemoryRecord;
  }

  return (await fetchJsonFromAppleseed(api, "/memories", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ ...payload, ...identity }),
  })) as AppleseedMemoryRecord;
}

function extractAppleseedId(path: string): string | null {
  if (!path) return null;
  if (path.startsWith("appleseed:")) return path.slice("appleseed:".length).trim() || null;

  const m = path.match(/([0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})/i);
  return m?.[1] ?? null;
}

function toLinesSlice(text: string, from?: number, lines?: number): string {
  if (!Number.isFinite(from) || !Number.isFinite(lines) || (from ?? 0) <= 0 || (lines ?? 0) <= 0) {
    return text;
  }
  const arr = text.split(/\r?\n/);
  const start = Math.max(0, Math.floor((from as number) - 1));
  const end = Math.min(arr.length, start + Math.floor(lines as number));
  return arr.slice(start, end).join("\n");
}

function resolveAutoInject(api: OpenClawPluginApi): boolean {
  const cfg = getPluginConfig(api);
  return cfg.autoInject !== false;
}

function resolveAutoInjectLimit(api: OpenClawPluginApi): number {
  const cfg = getPluginConfig(api);
  const n = Number(cfg.autoInjectLimit);
  if (Number.isFinite(n) && n > 0) return Math.max(1, Math.min(20, Math.floor(n)));
  return 5;
}

function resolveAutoInjectMinScore(api: OpenClawPluginApi): number {
  const cfg = getPluginConfig(api);
  const n = Number(cfg.autoInjectMinScore);
  return Number.isFinite(n) && n > 0 ? n : 0.04;
}

function truncateText(text: string, maxLen: number): string {
  if (text.length <= maxLen) return text;
  return `${text.slice(0, maxLen)}...`;
}

function formatAutoRecallContext(rows: AppleseedSearchItem[]): string {
  const lines: string[] = ["[Appleseed Memory Auto-Recall]"];
  rows.forEach((r, idx) => {
    const title = String(r.title ?? "(untitled)").trim() || "(untitled)";
    const snippetRaw = String(r.content ?? "").trim();
    const snippet = truncateText(snippetRaw, 300);
    const score = Number(r.score ?? 0);
    lines.push(`${idx + 1}. title: ${title}`);
    lines.push(`   score: ${score.toFixed(4)}`);
    lines.push(`   snippet: ${snippet || "(no snippet)"}`);
  });
  return lines.join("\n");
}

function createMemorySearchTool(api: OpenClawPluginApi): AnyAgentTool {
  return {
    label: "Memory Search",
    name: "memory_search",
    description: "Appleseed-backed recall: search prior work, decisions, dates, people, preferences, and todos.",
    parameters: {
      type: "object",
      properties: {
        query: { type: "string" },
        maxResults: { type: "number" },
        minScore: { type: "number" },
      },
      required: ["query"],
      additionalProperties: false,
    },
    execute: async (_toolCallId, rawParams) => {
      const params = rawParams as ToolParams;
      try {
        const query = String(params.query ?? "").trim();
        const maxResults = Math.max(1, Math.min(20, Number(params.maxResults ?? 8) || 8));
        const minScore = Number.isFinite(Number(params.minScore)) ? Number(params.minScore) : undefined;

        if (!query) {
          return jsonResult({ results: [], provider: "appleseed", mode: "appleseed-direct" });
        }

        const rows = await appleseedSearch(api, query, maxResults);
        const filtered = minScore == null ? rows : rows.filter((r) => Number(r.score ?? 0) >= minScore);

        const results = filtered.map((r) => {
          const full = String(r.content ?? "");
          const snippet = full.length > 1200 ? `${full.slice(0, 1200)}...` : full;
          return {
            path: `appleseed:${r.id}`,
            text: snippet,
            score: Number(r.score ?? 0),
            title: r.title,
            relPath: `appleseed:${r.id}`,
            lineStart: 1,
            lineEnd: Math.max(1, snippet.split(/\r?\n/).length),
            snippet,
          };
        });

        return jsonResult({
          results,
          provider: "appleseed",
          model: "appleseed-memory",
          fallback: "none",
          mode: "appleseed-direct",
        });
      } catch (err) {
        return jsonResult({
          results: [],
          disabled: true,
          error: err instanceof Error ? err.message : String(err),
          provider: "appleseed",
          mode: "appleseed-direct",
        });
      }
    },
  };
}

function createMemoryGetTool(api: OpenClawPluginApi): AnyAgentTool {
  return {
    label: "Memory Get",
    name: "memory_get",
    description: "Read appleseed memory content by path appleseed:<id>.",
    parameters: {
      type: "object",
      properties: {
        path: { type: "string" },
        from: { type: "number" },
        lines: { type: "number" },
      },
      required: ["path"],
      additionalProperties: false,
    },
    execute: async (_toolCallId, rawParams) => {
      const params = rawParams as ToolParams;
      const path = String(params.path ?? "").trim();
      try {
        const id = extractAppleseedId(path);
        if (!id) {
          return jsonResult({
            path,
            text: "",
            disabled: true,
            error: "Path must be appleseed:<id> (or include an appleseed UUID).",
          });
        }
        const mem = await appleseedGet(api, id);
        const text = toLinesSlice(String(mem.content ?? ""), Number(params.from), Number(params.lines));
        return jsonResult({
          path: `appleseed:${id}`,
          text,
          title: mem.title,
        });
      } catch (err) {
        return jsonResult({
          path,
          text: "",
          disabled: true,
          error: err instanceof Error ? err.message : String(err),
        });
      }
    },
  };
}

function createMemorySaveTool(api: OpenClawPluginApi): AnyAgentTool {
  return {
    label: "Memory Save",
    name: "memory_save",
    description:
      "Create or update an appleseed memory. Omit id/path to create; provide id or appleseed:<id> path to patch one.",
    parameters: {
      type: "object",
      properties: {
        id: { type: "string" },
        path: { type: "string" },
        title: { type: "string" },
        content: { type: "string" },
        importance: { type: "number" },
        confidence: { type: "number" },
        source: { type: "string" },
        sourceThreadId: { type: ["string", "null"] },
        labels: { type: "array", items: { type: "string" } },
        metadata: { type: "object", additionalProperties: true },
      },
      additionalProperties: false,
    },
    execute: async (_toolCallId, rawParams) => {
      const params = rawParams as ToolParams;
      try {
        const rawPath = typeof params.path === "string" ? params.path.trim() : "";
        const rawId = typeof params.id === "string" ? params.id.trim() : "";
        const id = extractAppleseedId(rawPath) ?? (rawId ? extractAppleseedId(rawId) ?? rawId : undefined);
        const title = typeof params.title === "string" ? params.title.trim() : undefined;
        const content = typeof params.content === "string" ? params.content : undefined;

        if (!id && !title && !content) {
          return jsonResult({
            ok: false,
            error: "Provide content/title to create a memory, or id/path plus fields to update one.",
          });
        }

        const result = await appleseedSave(api, {
          id,
          title,
          content,
          importance: Number.isFinite(Number(params.importance)) ? Number(params.importance) : undefined,
          confidence: Number.isFinite(Number(params.confidence)) ? Number(params.confidence) : undefined,
          source: typeof params.source === "string" ? params.source : undefined,
          sourceThreadId:
            params.sourceThreadId === null || typeof params.sourceThreadId === "string"
              ? params.sourceThreadId
              : undefined,
          labels: Array.isArray(params.labels)
            ? params.labels.map((v) => String(v)).filter((v) => v.length > 0)
            : undefined,
          metadata:
            params.metadata && typeof params.metadata === "object" && !Array.isArray(params.metadata)
              ? (params.metadata as Record<string, unknown>)
              : undefined,
        });
        const savedId = String(result.id ?? id ?? "").trim();
        return jsonResult({
          ok: true,
          action: id ? "updated" : "created",
          id: savedId || undefined,
          path: savedId ? `appleseed:${savedId}` : undefined,
          title: result.title ?? title,
          created_at: result.created_at,
          updated_at: result.updated_at,
        });
      } catch (err) {
        return jsonResult({
          ok: false,
          error: err instanceof Error ? err.message : String(err),
        });
      }
    },
  };
}

async function handleBeforePromptBuild(
  api: OpenClawPluginApi,
  event: PluginHookBeforePromptBuildEvent,
  _ctx: PluginHookAgentContext,
) {
  try {
    if (!resolveAutoInject(api)) return;

    const prompt = String(event.prompt ?? "").trim();
    if (!prompt) return;

    const query = prompt.slice(0, 200).trim();
    if (!query) return;

    const minScore = resolveAutoInjectMinScore(api);
    const rawRows = await appleseedSearch(api, query, resolveAutoInjectLimit(api));
    const rows = rawRows.filter((r) => Number(r.score ?? 0) >= minScore);
    if (rows.length === 0) return;

    return {
      prependContext: formatAutoRecallContext(rows),
    };
  } catch {
    return;
  }
}

export default definePluginEntry({
  id: PLUGIN_ID,
  name: "Appleseed Memory OpenClaw Plugin",
  description: "Appleseed-backed memory_search/memory_get/memory_save with OpenClaw-compatible result shape.",
  kind: "memory",
  configSchema,
  register(api) {
    api.on("before_prompt_build", (event, ctx) => handleBeforePromptBuild(api, event, ctx));
    api.registerTool(createMemorySearchTool(api), { names: ["memory_search"] });
    api.registerTool(createMemoryGetTool(api), { names: ["memory_get"] });
    api.registerTool(createMemorySaveTool(api), { names: ["memory_save", "memory_write"] });
  },
});
