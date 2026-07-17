# Prussian binder — clones the module repos listed in repos.tsv into this
# directory (each as its own, full git repo) and optionally checks out the
# pinned revision.  No submodules, no vendoring: separate histories stay
# separate.  Pinning is explicit (`make pin`) — no forced pointer commits.

MANIFEST := repos.tsv

.PHONY: help sync status pin dev clean

help:
	@echo 'Prussian binder targets:'
	@echo '  make sync    - clone missing modules, fetch, checkout pinned rev'
	@echo '  make status  - show pinned vs current rev per module'
	@echo '  make pin     - write current HEADs back into $(MANIFEST)'
	@echo '  make dev     - sync + wire the Python dev env (uv sync in prussian-mcp)'
	@echo '  make clean   - remove all cloned module directories'

sync:
	@while IFS=$$'\t' read -r name url branch rev; do \
	  [ -z "$$name" ] && continue; \
	  [ -d "$$name/.git" ] || git clone "$$url" "$$name"; \
	  git -C "$$name" fetch --quiet origin; \
	  if [ -n "$$(git -C "$$name" status --porcelain)" ]; then \
	    echo "$$name: uncommitted changes — skipping checkout"; \
	  else \
	    git -C "$$name" checkout --quiet "$$rev" && echo "$$name @ $$rev"; \
	  fi; \
	done < $(MANIFEST)

status:
	@while IFS=$$'\t' read -r name url branch rev; do \
	  [ -z "$$name" ] && continue; \
	  cur=$$(git -C "$$name" rev-parse --short HEAD 2>/dev/null || echo '—'); \
	  mark=' '; [ "$$cur" = "$$rev" ] && mark='=' || mark='*'; \
	  printf '%s %-16s pinned=%-9s current=%-9s (%s)\n' "$$mark" "$$name" "$$rev" "$$cur" "$$branch"; \
	done < $(MANIFEST)

pin:
	@tmp=$$(mktemp); \
	while IFS=$$'\t' read -r name url branch rev; do \
	  [ -z "$$name" ] && continue; \
	  new=$$(git -C "$$name" rev-parse --short HEAD 2>/dev/null || echo "$$rev"); \
	  printf '%s\t%s\t%s\t%s\n' "$$name" "$$url" "$$branch" "$$new" >> $$tmp; \
	  [ "$$new" != "$$rev" ] && echo "$$name: $$rev -> $$new"; \
	done < $(MANIFEST); \
	mv $$tmp $(MANIFEST)

dev: sync
	cd prussian-mcp && uv sync

clean:
	@while IFS=$$'\t' read -r name url branch rev; do \
	  [ -z "$$name" ] && continue; \
	  rm -rf "$$name"; \
	done < $(MANIFEST)
