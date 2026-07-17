# prussian — binder repo

This repo does **not** contain code. It is a thin *binder* that clones the
independent Prussian module repos into place and — optionally — checks them
out at pinned revisions for a reproducible, known-good combination.

Each module keeps its own repository and history:

| Module | Repo | Role |
|---|---|---|
| `prussian-fst` | [strfry/prussian-fst](https://github.com/strfry/prussian-fst) | FST/CG3 morphology + grammar |
| `prussian-mcp` | [strfry/prussian-mcp](https://github.com/strfry/prussian-mcp) | MCP server + `prussian-agent` CLI |
| `prussian-corpus` | [strfry/prussian-corpus](https://github.com/strfry/prussian-corpus) | Dictionary + corpus data |
| `prussian-lora` | [strfry/prussian-lora](https://github.com/strfry/prussian-lora) | LoRA / training experiments |
| `prussian-bot` | [strfry/prussian-bot](https://github.com/strfry/prussian-bot) | Go bot |

## Why a binder (and not submodules / a monorepo)

The modules are separate work sites with independent lifecycles. A monorepo
would fuse their histories; submodules add pointer-update noise and
detached-HEAD friction. The binder keeps them fully separate repos and
records a *known-good combination* only when you ask for it.

## Usage

```bash
make sync      # clone missing modules, fetch, checkout the pinned rev
make status    # show pinned vs current rev per module (* = differs)
make dev       # sync + wire the Python dev env (uv sync in prussian-mcp,
               #   which pulls prussian-fst editable from ../prussian-fst)
make pin       # write the modules' current HEADs back into repos.tsv
make clean     # remove all cloned module directories
```

The pinned revisions live in **`repos.tsv`** (`name  url  branch  rev`,
tab-separated). `make pin` updates the `rev` column from each module's
current HEAD — run it deliberately when you want to freeze a working
combination. A pin diff is human-readable (`prussian-fst: abc → def`).

Because the modules are cloned under their original names, `prussian-mcp`'s
existing `[tool.uv.sources] prussian-fst = { path = "../prussian-fst" }`
resolves against the sibling clone with no changes to any module.

> Pinned revs must exist on the module's remote. If you pinned a local-only
> commit, push it first, then `make sync`.
