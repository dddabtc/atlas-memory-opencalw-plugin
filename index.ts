import type { OpenClawPluginApi } from "openclaw/plugin-sdk";

// jsonResult was removed from openclaw/plugin-sdk in 2026.3.22+
// Inlined here to avoid the import error
function jsonResult(payload: unknown) {
  return {
    content: [{ type: "text" as const, text: JSON.stringify(payload, null, 2) }],
    _jsonPayload: payload,
  };
}

const DEFAULT_BASE_URLS: string[] = [];
const PLUGIN_ID = "atlas-memory-opencalw-plugin";
const DEFAULT_TIMEOUT_MS = 5000;

type AtlasPluginConfig = {
  baseUrl?: string;
  baseUrls?: string[];
  timeoutMs?: number;
  autoInject?: boolean;
  autoInjectLimit?: number;
  autoInjectMinScore?: number;
};

type AtlasSearchItem = {
  id: string;
  title?: string;
  content?: string;
  score?: number;
  updated_at?: string;
};

function normalizeBase(raw: string): string {
  return raw.replace(/\/+$/, "");
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

  const entry = (api.config?.plugins?.entries?.[PLUGIN_ID] ?? {}) as any;
  const cfg = ((entry?.config ?? entry) ?? {}) as AtlasPluginConfig;

  const remoteBase = (api.config as any)?.agents?.defaults?.memorySearch?.remote?.baseUrl;
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
  if (process.env.ATLAS_MEMORY_BASE_URL?.trim()) {
    return dedupe([normalizeBase(process.env.ATLAS_MEMORY_BASE_URL.trim()), ...DEFAULT_BASE_URLS]);
  }
  if (process.env.ATLAS_BASE_URL?.trim()) {
    return dedupe([normalizeBase(process.env.ATLAS_BASE_URL.trim()), ...DEFAULT_BASE_URLS]);
  }
  return DEFAULT_BASE_URLS;
}

function resolveTimeoutMs(api: OpenClawPluginApi): number {
  const entry = (api.config?.plugins?.entries?.[PLUGIN_ID] ?? {}) as any;
  const cfg = ((entry?.config ?? entry) ?? {}) as AtlasPluginConfig;
  const n = Number(cfg.timeoutMs);
  return Number.isFinite(n) && n >= 500 ? Math.floor(n) : DEFAULT_TIMEOUT_MS;
}

async function fetchJsonFromAtlas(api: OpenClawPluginApi, path: string, init?: RequestInit): Promise<any> {
  const bases = resolveConfigBaseUrls(api);
  const timeoutMs = resolveTimeoutMs(api);
  const errors: string[] = [];

  if (!bases.length) {
    throw new Error("Atlas base URL not configured");
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
  throw new Error(`Atlas unavailable (${errors.join("; ")})`);
}

async function atlasSearch(api: OpenClawPluginApi, query: string, limit: number): Promise<AtlasSearchItem[]> {
  const data = (await fetchJsonFromAtlas(api, "/memories/search", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ query, limit }),
  })) as { results?: AtlasSearchItem[] };
  return Array.isArray(data?.results) ? data.results : [];
}

async function atlasGet(api: OpenClawPluginApi, id: string): Promise<{ id: string; title?: string; content?: string }> {
  return (await fetchJsonFromAtlas(api, `/memories/${encodeURIComponent(id)}`)) as {
    id: string;
    title?: string;
    content?: string;
  };
}

function extractAtlasId(path: string): string | null {
  if (!path) return null;
  if (path.startsWith("atlas:")) return path.slice("atlas:".length).trim() || null;

  // support memory/atlas/Foo_<uuid>.md style paths
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

function getPluginConfig(api: OpenClawPluginApi): AtlasPluginConfig {
  const entry = (api.config?.plugins?.entries?.[PLUGIN_ID] ?? {}) as any;
  return ((entry?.config ?? entry) ?? {}) as AtlasPluginConfig;
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

function formatAutoRecallContext(rows: AtlasSearchItem[]): string {
  const lines: string[] = ["[Atlas Memory Auto-Recall]"];
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

export default {
  id: "atlas-memory-opencalw-plugin",
  name: "Atlas Memory OpenCalw Plugin",
  description: "Atlas-backed memory_search/memory_get with OpenClaw-compatible result shape",
  kind: "memory",
  configSchema: {
    type: "object",
    additionalProperties: false,
    properties: {
      baseUrl: { type: "string" },
      baseUrls: { type: "array", items: { type: "string" } },
      timeoutMs: { type: "number", minimum: 500 },
      autoInject: { type: "boolean", default: true },
      autoInjectLimit: { type: "number", minimum: 1, maximum: 20, default: 5 },
      autoInjectMinScore: { type: "number", minimum: 0, maximum: 1, default: 0.04 },
    },
  },
  register(api: OpenClawPluginApi) {
    api.on("before_prompt_build", async (event: any) => {
      try {
        if (!resolveAutoInject(api)) return;

        const prompt = String(event?.prompt ?? "").trim();
        if (!prompt) return;

        const query = prompt.slice(0, 200).trim();
        if (!query) return;

        const minScore = resolveAutoInjectMinScore(api);
        const rawRows = await atlasSearch(api, query, resolveAutoInjectLimit(api));
        const rows = (rawRows ?? []).filter((r) => Number(r.score ?? 0) >= minScore);
        if (rows.length === 0) return;

        return {
          prependContext: formatAutoRecallContext(rows),
        };
      } catch {
        // silent skip: do not affect normal prompt flow
        return;
      }
    });

    api.registerTool(
      {
        label: "Memory Search",
        name: "memory_search",
        description:
          "Atlas-backed recall: search prior work, decisions, dates, people, preferences, and todos.",
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
        execute: async (_toolCallId: string, params: any) => {
          try {
            const query = String(params?.query ?? "").trim();
            const maxResults = Math.max(1, Math.min(20, Number(params?.maxResults ?? 8) || 8));
            const minScore = Number.isFinite(Number(params?.minScore)) ? Number(params?.minScore) : undefined;

            if (!query) {
              return jsonResult({ results: [], provider: "atlas", mode: "atlas-direct" });
            }

            const rows = await atlasSearch(api, query, maxResults);
            const filtered = minScore == null ? rows : rows.filter((r) => (Number(r.score ?? 0) >= minScore));

            const results = filtered.map((r) => {
              const full = String(r.content ?? "");
              const snippet = full.length > 1200 ? `${full.slice(0, 1200)}...` : full;
              return {
                // OpenClaw memory tool convention
                path: `atlas:${r.id}`,
                text: snippet,
                score: Number(r.score ?? 0),

                // extra fields for compatibility/UX
                title: r.title,
                relPath: `atlas:${r.id}`,
                lineStart: 1,
                lineEnd: Math.max(1, snippet.split(/\r?\n/).length),
                snippet,
              };
            });

            return jsonResult({
              results,
              provider: "atlas",
              model: "atlas-memory",
              fallback: "none",
              mode: "atlas-direct",
            });
          } catch (err) {
            return jsonResult({
              results: [],
              disabled: true,
              error: err instanceof Error ? err.message : String(err),
              provider: "atlas",
              mode: "atlas-direct",
            });
          }
        },
      } as any,
      { names: ["memory_search"] },
    );

    api.registerTool(
      {
        label: "Memory Get",
        name: "memory_get",
        description: "Read Atlas memory content by path atlas:<id>.",
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
        execute: async (_toolCallId: string, params: any) => {
          const path = String(params?.path ?? "").trim();
          try {
            const id = extractAtlasId(path);
            if (!id) {
              return jsonResult({
                path,
                text: "",
                disabled: true,
                error: "Path must be atlas:<id> (or include an Atlas UUID).",
              });
            }
            const mem = await atlasGet(api, id);
            const full = String(mem?.content ?? "");
            const text = toLinesSlice(full, Number(params?.from), Number(params?.lines));
            return jsonResult({
              path: `atlas:${id}`,
              text,
              title: mem?.title,
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
      } as any,
      { names: ["memory_get"] },
    );
  },
};
