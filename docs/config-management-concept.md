# Konzept: Sauberes Konfigurationsmanagement (prussian-mcp + prussian-embeddings)

> **Deliverable = dieses Konzept.** Die Umsetzung wird an Repo-Agenten
> delegiert (je ein Agent für `prussian-mcp`, `prussian-embeddings`,
> `prussian` (Binder)). Dieses Dokument ist die Vorlage für diese Agenten.
> Entscheidungen des Nutzers: **hart umbenennen** (keine Alt-Aliase),
> **fail-fast + Start-Report**.

## Kontext / Problem

Das Config-Management ist über drei Repos verteilt und widersprüchlich.
Konkret nachgewiesen im Code:

1. **Zwei Sources of Truth für dieselben Embedding-Variablen.**
   `prussian-mcp/prussian/config.py:15-32` liest `EMBEDDING_BACKEND`,
   `EMBEDDING_MODEL`, `EMBEDDING_DIM`, `RERANKER_MODEL`, `API_KEY`,
   `API_BASE_URL` – als „deprecated pass-throughs" deklariert. Dieselbe
   Logik existiert nochmal in
   `prussian-embeddings/prussian_embeddings/config.py:env_config()` –
   **mit abweichenden Fallbacks/Defaults**:
   - `config.py` kennt zusätzlich `RERANK_API_KEY` / `RERANK_BASE_URL`;
     `env_config()` kennt sie **nicht**.
   - `config.py` `EMBEDDING_DIM` default `1024`; `env_config()` default
     backend-abhängig (`384`/`128`/`1024`).
   - `config.py` `EMBEDDING_MODEL` default `""`; `env_config()`
     backend-abhängiger Default.
   → Zur Laufzeit gewinnt `env_config()` (Runtime-Embedder), die Scripts
   lesen aber `config.py`. Korpus wird also mit einer Config *erzeugt*
   (`scripts/generate_embeddings.py`) und mit einer anderen *durchsucht*.

2. **Die „deprecated" Vars sind nicht tot.** Sie werden von
   `scripts/generate_embeddings.py` und `scripts/test_search.py` importiert.
   Naives Löschen bricht die Scripts.

3. **`.mcp.json` ist eine stille Fehlkonfiguration** – direkt aus dem Split
   entstanden: es setzt `RERANK_BASE_URL=http://localhost:8001/v3` und
   `EMBEDDING_MODEL=Qwen3-…`. Zur Laufzeit liest `env_config()` aber weder
   `RERANK_BASE_URL` (nur `API_BASE_URL`/`JINA_BASE_URL`) noch greift
   `EMBEDDING_MODEL`, solange `EMBEDDING_BACKEND` auf `fastembed` (Default)
   steht. Der lokale Server wird ignoriert, ohne dass irgendwer es merkt.

4. **Inkonsistente Namen:** `EMBEDDING_*` (Singular, Modell) vs
   `EMBEDDINGS_*` (Plural, Storage) vs `OPENAI_*` (LLM) vs blankes
   `API_KEY`/`API_BASE_URL`; `RERANKER_MODEL` vs `RERANK_API_KEY`.
   `API_KEY` ist gefährlich generisch.

5. **Keine Transparenz:** Config wird bei Import gelesen; weder MCP-Server
   (`prussian/adapters/mcp.py:main`) noch CLI (`adapters/agent/cli.py`)
   berichten je, welcher Backend/Modell/Pfad/Endpoint aufgelöst wurde oder
   ob Chunk-Mode / Hybrid / Reranker aktiv sind.

6. **Silent Fails / unerwünschte optionale Pfade:**
   - `prussian/engine/embeddings/rerank.py:build_reranker()` →
     `try: … except Exception: return None`. Jeder Fehler (ImportError von
     `get_reranker`, fehlender Key, Netz) ⇒ Reranker still `None`. Genau
     das maskiert aktuell einen echten Versions-Drift: der gepinnte
     embeddings-Rev (`repos.tsv` `408ce76`) exportiert `get_reranker`,
     der Default-Branch-HEAD nicht.
   - `prussian/tools/runtime.py:get_reranker()` cached dieses `None`
     dauerhaft, ohne Grund/Retry.
   - `engine/search.py:249` `if self.store is None: return []` – stiller
     Leerlauf.
   - `engine/backends.py:_filter_by_tags` `if not fst_available(): return`
     – Tags still weg.
   - `adapters/mcp.py:110` `--web` default aus `MCP_TRANSPORT == "sse"` –
     Name/Wert passt nicht zum Transport („streamable-http").

## Zielarchitektur

**Ein einziger env-lesender Ort. Getippt. Validiert. Beim Start berichtet.**

### A. `prussian-mcp` wird der alleinige Config-Owner (Single Source of Truth)

`prussian/config.py` wird von losen Modul-`os.getenv`-Aufrufen zu **einem
gefrorenen, getippten Dataclass-Baum** mit einer `Config.from_env()`
Factory umgebaut. Gruppiert nach Domäne:

```
Config
├── paths:  DataPaths      (data_dir, embeddings_dir, prompts_dir, dictionary, agent_prompt)
├── embed:  EmbedConfig    (backend, model, dim, api_url, api_key, query_prefix)
├── rerank: RerankConfig   (enabled, model, api_url, api_key)
├── store:  StoreConfig    (name, chunk_name|None, hybrid, chunk_rerank_topn)
├── llm:    LlmConfig      (model, api_url, api_key)
└── mcp:    McpConfig      (host, port, transport)
```

- Kein Lesen von env bei Modul-Import mehr. `Config.from_env()` wird
  **explizit** in `mcp.py:main()` und `cli.py:main()` aufgerufen – nach
  Sourcen des env-Files, vor Bau der Engine.
- `search.py`, `backends.py`, `runtime.py`, `rerank.py`, die Scripts
  bekommen die aufgelöste `Config` (bzw. Teilobjekte) **injiziert** statt
  selbst env oder Modul-Konstanten zu lesen.

### B. `prussian-embeddings` wird eine reine, injizierbare Library

- `env_config()` / implizites env-Lesen in `get_embedder`, `client.py`,
  `backends.py` wird **entfernt**. Die Library liest keine Umgebung mehr.
- Öffentliche API nimmt explizite Specs entgegen:
  `get_embedder(EmbedSpec)`, `EmbeddingClient(RerankSpec|EmbedSpec)`.
  `EnvConfig`/`env_config`/`from_env` entfallen (hart – keine Aliase).
- Der App-Owner (`prussian-mcp`) mappt seine `EmbedConfig`/`RerankConfig`
  auf diese Specs. Damit gibt es **exakt eine** Stelle, die env liest.
- Validierung, die intrinsisch zur Library gehört (z.B. „api-Backend
  braucht Key"), bleibt als harter `ValueError` in den Konstruktoren
  (existiert schon in `ApiEmbedder.__init__`), wird aber vom App-Report
  vorab sauber angezeigt.

### C. Neues, konsistentes Env-Schema (hart umbenannt)

Einheitliches `PRUSSIAN_`-Präfix, klare Domänen-Gruppen. Embed / Rerank /
LLM sind **drei getrennte Provider** (auch wenn sie faktisch auf dieselbe
URL zeigen) – das löst die `RERANK_BASE_URL`-Verwirrung endgültig.

| Domäne | alt | neu |
|---|---|---|
| Embed | `EMBEDDING_BACKEND` | `PRUSSIAN_EMBED_BACKEND` |
| Embed | `EMBEDDING_MODEL` | `PRUSSIAN_EMBED_MODEL` |
| Embed | `EMBEDDING_DIM` | `PRUSSIAN_EMBED_DIM` |
| Embed | `API_KEY`/`JINA_API_KEY` | `PRUSSIAN_EMBED_API_KEY` |
| Embed | `API_BASE_URL`/`JINA_BASE_URL` | `PRUSSIAN_EMBED_API_URL` |
| Embed | `QUERY_PREFIX` | `PRUSSIAN_EMBED_QUERY_PREFIX` |
| Rerank | `RERANKER_MODEL` | `PRUSSIAN_RERANK_MODEL` |
| Rerank | `RERANK_API_KEY` | `PRUSSIAN_RERANK_API_KEY` |
| Rerank | `RERANK_BASE_URL` | `PRUSSIAN_RERANK_API_URL` |
| Store | `EMBEDDINGS_NAME` | `PRUSSIAN_STORE_NAME` |
| Store | `CHUNK_EMBEDDINGS_NAME` | `PRUSSIAN_CHUNK_STORE_NAME` |
| Store | *(hardcodiert)* | `PRUSSIAN_EMBEDDINGS_DIR` (neu, optional) |
| Store | `HYBRID_SEARCH` | `PRUSSIAN_HYBRID_SEARCH` |
| Store | `CHUNK_RERANK_TOPN` | `PRUSSIAN_CHUNK_RERANK_TOPN` |
| LLM | `OPENAI_MODEL` | `PRUSSIAN_LLM_MODEL` |
| LLM | `OPENAI_BASE_URL` | `PRUSSIAN_LLM_API_URL` |
| LLM | `OPENAI_API_KEY` | `PRUSSIAN_LLM_API_KEY` |
| MCP | `MCP_HOST` | `PRUSSIAN_MCP_HOST` |
| MCP | `MCP_PORT` | `PRUSSIAN_MCP_PORT` |
| MCP | `MCP_TRANSPORT` (`=="sse"`) | `PRUSSIAN_MCP_TRANSPORT` (`stdio`\|`http`) |

- **Reranker ist opt-in:** aktiv nur wenn `PRUSSIAN_RERANK_API_URL`
  gesetzt ist. Kein URL ⇒ `rerank.enabled=False`, wird im Report als
  „disabled (not configured)" ausgewiesen – nicht still.
- **Caveat LLM-Var (im Report/Doku vermerken):** das OpenAI-SDK
  (`smolagents.OpenAIModel`) liest `OPENAI_API_KEY` selbst aus env, wenn
  nichts übergeben wird. `runner.py:build_model` übergibt bereits explizit,
  also bleibt es kontrolliert – aber Repo-Agent muss sicherstellen, dass
  nirgends implizit `OPENAI_*` durchsickert.

### D. Start-Report (fail-fast + laut)

`Config.from_env()` → `config.validate()` → `config.report()`. Beide
Entry-Points drucken den Report **vor** dem Engine-Bau nach stderr:

```
Prussian config (source: env)
  embed.backend    = fastembed
  embed.model      = intfloat/multilingual-e5-small
  embed.dim        = 384
  store.name       = embeddings_fastembed
  store.path       = <dir>/embeddings_fastembed.*   [OK | MISSING]
  chunk.mode       = off | on (<chunk_store_name>)  [OK | MISSING]
  hybrid.search    = on
  rerank           = enabled (jina-reranker-…, <url>) | DISABLED (not configured)
  llm.model        = eurollm-22b-instruct-int4
  llm.api_url      = http://localhost:8001/v3
  mcp.transport    = stdio  (host=127.0.0.1 port=8001)
```

`validate()` sammelt **alle** harten Fehler und wirft **einen**
`ConfigError` mit vollständiger Liste (nicht nur der erste):
- Embeddings-Store-Datei fehlt auf Platte.
- `embed.backend == "api"` ohne `PRUSSIAN_EMBED_API_URL`/`_KEY`.
- Chunk-Mode angefragt, aber Chunk-Store fehlt.
- Unbekannter Backend-Wert.

Optionale Features melden ihren Deaktivierungsgrund laut (Reranker
disabled: `<Grund>`), statt Exceptions zu schlucken.

### E. Silent-Fail-Pfade entfernen

- `rerank.py:build_reranker`: kein blankes `except Exception`. Wenn
  `rerank.enabled` und Bau scheitert ⇒ **laut** (Report-Zeile mit echtem
  Fehler; bei explizit angefordertem Context-Rerank ⇒ Fehler statt stiller
  Leerergebnisse). ImportError von `get_reranker` ⇒ klare Meldung
  „embeddings pin zu alt?" (adressiert den nachgewiesenen Drift).
- `runtime.py:get_reranker`: kein dauerhaftes Cachen von `None` ohne Grund;
  Reranker beim Start eager bauen, damit der Report stimmt.
- `search.py` `if self.store is None: return []`: nach Fail-fast-Load nicht
  mehr erreichbar ⇒ entfernen/`assert`.
- `mcp.py` `--web`-Default: aus `PRUSSIAN_MCP_TRANSPORT in {stdio,http}`
  ableiten, kein `"sse"`-Sonderwert.

## Delegations-Aufteilung (je Repo-Agent)

**prussian-embeddings-Agent**
- `config.py`: `env_config`/`EnvConfig` entfernen; stattdessen getippte
  `EmbedSpec`/`RerankSpec` Dataclasses (reine Datencontainer, kein env).
- `backends.py`, `client.py`: implizites `env_config()` raus; Specs rein;
  harte Validierung in Konstruktoren behalten/schärfen.
- `__init__.py`: Exporte anpassen (`env_config` weg).
- Versions-Drift adressieren: sicherstellen, dass `get_reranker`,
  `hybrid_query`, `annotate_chunk`, `BM25Index` auf dem Ziel-Branch
  exportiert sind (sonst schlägt `prussian-mcp` fehl – aktuell nur durch
  den Silent-`except` verdeckt).

**prussian-mcp-Agent**
- `config.py`: neu als getippter `Config`-Baum + `from_env()`/`validate()`/
  `report()`; alte Modul-Konstanten & deprecated Embedding-Dupes entfernen.
- `adapters/mcp.py`, `adapters/agent/cli.py`: `Config.from_env()`,
  Report+Validate vor Engine-Bau; MCP-Transport-Flag umstellen.
- `engine/search.py`, `engine/backends.py`, `tools/runtime.py`,
  `engine/embeddings/rerank.py`: Config-Injektion statt env/Modulkonstanten;
  Silent-Fails entfernen.
- `scripts/generate_embeddings.py`, `scripts/test_search.py`: auf neue
  `Config`/`EmbedSpec` umstellen (behebt Erzeugen-≠-Suchen-Split).
- Client-Configs & Doku: `.mcp.json`, `opencode.json`, `CLAUDE.md`,
  `README.md`, Beispiel-env-Files – auf neue `PRUSSIAN_*`-Namen; `.mcp.json`
  konsistent machen (Embed/Rerank/LLM-URLs korrekt getrennt).

**prussian (Binder)-Agent**
- Nach Modul-Änderungen `repos.tsv` neu pinnen (`make pin`).
- Falls Beispiel-/Doku-env-Files oder README-Config-Hinweise im Binder:
  auf neues Schema angleichen.

## Verifikation

1. **Report sichtbar:** `uv run prussian-mcp` und `uv run prussian-agent …`
   drucken den Config-Report nach stderr (Backend, Modell, Pfade,
   Rerank-Status, Transport).
2. **Fail-fast greift:** Store-Datei umbenennen ⇒ sofortiger `ConfigError`
   mit klarer Meldung, kein stiller Leerlauf. `PRUSSIAN_EMBED_BACKEND=api`
   ohne URL/Key ⇒ sofortiger Abbruch mit Grund.
3. **Reranker-Transparenz:** ohne `PRUSSIAN_RERANK_API_URL` meldet der
   Report „rerank DISABLED (not configured)"; mit gesetzter, aber kaputter
   URL ⇒ lauter Fehler statt stiller `None`.
4. **Kein Erzeugen-≠-Suchen-Drift:** `scripts/generate_embeddings.py` und
   der Runtime-Embedder lösen dieselbe `EmbedConfig` auf (per Report
   vergleichbar).
5. **Keine Altnamen mehr:** `git grep -nE 'EMBEDDING_|EMBEDDINGS_NAME|
   \bAPI_KEY\b|API_BASE_URL|RERANKER_MODEL|RERANK_(API_KEY|BASE_URL)|
   OPENAI_(MODEL|BASE_URL|API_KEY)|MCP_(HOST|PORT|TRANSPORT)|QUERY_PREFIX|
   HYBRID_SEARCH|env_config'` in beiden Repos ist leer (bis auf bewusste
   Doku der Migration).
6. **Tests:** `pytest -q` (mcp: `tests/`, embeddings: `tests/`) grün;
   `--validate-only`-Pfad unberührt.
```
