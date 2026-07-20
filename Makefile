# Prussian binder — clones the module repos listed in repos.tsv into this
# directory (each as its own, full git repo) and optionally checks out the
# pinned revision.  No submodules, no vendoring: separate histories stay
# separate.  Pinning is explicit (`make pin`) — no forced pointer commits.

MANIFEST := repos.tsv

LOOP_START = @while IFS=$$(printf '\t') read -r name url branch rev; do [ -z "$$name" ] && continue;
LOOP_END   = done < $(MANIFEST)

.PHONY: help sync status pin push git-status dev download download-embeddings build-eval clean

help:
	@echo 'Prussian binder targets:'
	@echo '  make sync        - clone missing modules, fetch, checkout pinned rev'
	@echo '  make status      - show pinned vs current rev per module'
	@echo '  make pin         - write current HEADs back into $(MANIFEST)'
	@echo '  make push        - push each module repo (detached HEAD → origin/<branch>)'
	@echo '  make git-status  - run git status in each module repo'
	@echo '  make dev         - sync + wire the Python dev env (uv sync in mcp)'
	@echo '  make download    - fetch corpus + embeddings artifacts from GitHub Releases'
	@echo '  make download-embeddings - fetch only fastembed artifacts'
	@echo '  make build-eval  - full setup for eval: sync, download, FST build, Python env'
	@echo '  make clean       - remove all cloned module directories'

sync:
	$(LOOP_START) \
	  [ -d "$$name/.git" ] || git clone "$$url" "$$name"; \
	  git -C "$$name" fetch --quiet origin; \
	  if [ -n "$$(git -C "$$name" status --porcelain)" ]; then \
	    echo "$$name: uncommitted changes — skipping checkout"; \
	  else \
	    git -C "$$name" checkout --quiet "$$rev" && echo "$$name @ $$rev"; \
	  fi; \
	$(LOOP_END)

status:
	$(LOOP_START) \
	  cur=$$(git -C "$$name" rev-parse --short HEAD 2>/dev/null || echo '—'); \
	  dirty=$$(git -C "$$name" status --porcelain); \
	  rmark=' '; [ "$$cur" != "$$rev" ] && rmark='*'; \
	  dmark=' '; [ -n "$$dirty" ] && dmark='~'; \
	  printf '%s%s %-16s pinned=%-9s current=%-9s (%s)\n' "$$rmark" "$$dmark" "$$name" "$$rev" "$$cur" "$$branch"; \
	$(LOOP_END)

pin:
	@tmp=$$(mktemp); \
	while IFS=$$(printf '\t') read -r name url branch rev; do \
	  [ -z "$$name" ] && continue; \
	  new=$$(git -C "$$name" rev-parse --short HEAD 2>/dev/null || echo "$$rev"); \
	  printf '%s\t%s\t%s\t%s\n' "$$name" "$$url" "$$branch" "$$new" >> $$tmp; \
	  [ "$$new" != "$$rev" ] && echo "$$name: $$rev -> $$new"; \
	done < $(MANIFEST); \
	mv $$tmp $(MANIFEST)

push:
	$(LOOP_START) echo "=== $$name ==="; git -C "$$name" push origin "HEAD:$$branch"; $(LOOP_END)

git-status:
	$(LOOP_START) git -C "$$name" status; $(LOOP_END)

dev: sync
	cd mcp && uv sync

# GitHub-Release-Assets OHNE die GitHub-API laden (die 60 Req/h unauth reißen sonst
# das Rate-Limit) und ohne gh/Token:
#   1. latest-Tag über den /releases/latest-Redirect (Location-Header) auflösen
#   2. Asset-Namen aus der /expanded_assets/<tag>-HTML lesen und per ERE filtern
#   3. Assets direkt vom Release-CDN /releases/download/<tag>/<name> ziehen
# Alle drei Schritte laufen über github.com (nicht api.github.com) → kein API-Limit.
# Aufruf: $(call gh_dl,<owner/repo>,<name-regex (ERE)>,<zieldir>)
define gh_dl
set -eu; repo='$(1)'; pat='$(2)'; dir='$(3)'; mkdir -p "$$dir"; \
tag=$$(curl -fsSI "https://github.com/$$repo/releases/latest" | tr -d '\r' | sed -n 's#^[Ll]ocation:.*/tag/##p'); \
[ -n "$$tag" ] || { echo "$$repo: latest-Tag nicht auflösbar" >&2; exit 1; }; \
names=$$(curl -fsSL "https://github.com/$$repo/releases/expanded_assets/$$tag" | grep -oE 'releases/download/[^"]+' | sed 's#.*/##' | sort -u | grep -E "$$pat"); \
[ -n "$$names" ] || { echo "$$repo@$$tag: keine Assets für /$$pat/" >&2; exit 1; }; \
for n in $$names; do echo "  $$repo@$$tag -> $$n"; curl -fSL "https://github.com/$$repo/releases/download/$$tag/$$n" -o "$$dir/$$n"; done
endef

download: download-embeddings
	@mkdir -p corpus/parsed fst/data/external
	@$(call gh_dl,strfry/prussian-corpus,^(twanksta|prusaspira)_entries\.json$$,corpus/parsed)
	@$(call gh_dl,strfry/prussian-corpus,\.tar\.zst$$,corpus/_dl)
	@set -e; tar --zstd -xf corpus/_dl/*.tar.zst -C corpus/; rm -rf corpus/_dl
	cp corpus/parsed/twanksta_entries.json fst/data/external/

download-embeddings:
	@mkdir -p embeddings/data
	@$(call gh_dl,strfry/prussian-embeddings,^embeddings_fastembed\.,embeddings/data)

build-eval: sync download
	$(MAKE) -C fst/fst gen all cg3-sets cg3-check conllu
	cd mcp && uv sync
	cd eval && uv sync

clean:
	$(LOOP_START) rm -rf "$$name"; $(LOOP_END)
