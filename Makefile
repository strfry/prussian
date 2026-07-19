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
	  mark=' '; [ "$$cur" = "$$rev" ] && mark='=' || mark='*'; \
	  printf '%s %-16s pinned=%-9s current=%-9s (%s)\n' "$$mark" "$$name" "$$rev" "$$cur" "$$branch"; \
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

download: download-embeddings
	@mkdir -p corpus/parsed fst/data/external
	gh release download --repo strfry/prussian-corpus \
	    --pattern 'twanksta_entries.json' --dir corpus/parsed --clobber
	gh release download --repo strfry/prussian-corpus \
	    --pattern 'prusaspira_entries.json' --dir corpus/parsed --clobber
	@set -e; \
	 tmp=$$(mktemp -d); \
	 gh release download --repo strfry/prussian-corpus \
	     --pattern '*.tar.zst' --dir $$tmp --clobber; \
	 tar --zstd -xf $$tmp/*.tar.zst -C corpus/; \
	 rm -rf $$tmp
	cp corpus/parsed/twanksta_entries.json fst/data/external/

download-embeddings:
	@mkdir -p embeddings/data
	gh release download --repo strfry/prussian-embeddings \
	    --pattern 'embeddings_fastembed.*' --dir embeddings/data --clobber

build-eval: sync download
	$(MAKE) -C fst/fst gen all cg3-sets cg3-check conllu
	cd mcp && uv sync
	cd eval && uv sync

clean:
	$(LOOP_START) rm -rf "$$name"; $(LOOP_END)
