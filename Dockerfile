# Prussian-Binder: klont dieses Repo und baut alle Module durch (make build-eval).
#
#   docker build -t prussian .
#   docker build -t prussian --build-arg PRUSSIAN_REF=<branch|tag|sha> .
#
# `make build-eval` = sync + download + FST/CG3-Build + `uv sync` in mcp und eval.
# Die Systemtoolchain kommt aus apt (hfst, cg3, zstd), uv wird ergänzt; uv holt
# sich Python 3.12 (requires-python "==3.12.*") beim `uv sync` selbst.
#
# Release-Artefakte lädt `make download` über curl direkt vom Release-CDN
# (github.com/.../releases/...) — bewusst OHNE die GitHub-API und ohne gh/Token,
# weil die API (60 Req/h unauth) sonst am Rate-Limit scheitert. Daher kein gh hier.

FROM debian:bookworm-slim

# Systemtoolchain: Klonen/Makefile (git, make, curl), Build-Skripte (python3),
# der HFST-Stack (hfst-lexc/-invert/-fst2fst/-xfst/-compose/-minimize), CG3 und
# zstd (Korpus-Tarball ist .tar.zst).
RUN apt-get update && apt-get install -y --no-install-recommends \
        git make curl ca-certificates python3 hfst cg3 zstd \
    && rm -rf /var/lib/apt/lists/*

# uv als statisches Binary aus dem offiziellen Image.
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

# Binder klonen (Voraussetzung: der zu bauende Stand ist nach origin gepusht).
ARG PRUSSIAN_REF=main
# Cache-Buster: der Atom-Feed listet die letzten Commits von PRUSSIAN_REF; sein
# Inhalt ändert sich, sobald ein neuer Commit auf dem Ref landet. Dadurch wird die
# Clone-Schicht — und alles danach — nur dann neu gebaut, wenn origin tatsächlich
# einen neuen Stand hat; sonst bleibt der Cache warm. Bewusst der github.com-Feed
# (nicht api.github.com), damit auch der Cache-Buster nicht am API-Limit scheitert.
# (Funktioniert für Branch-Refs; bei SHA/Tag ggf. mit --no-cache bauen.)
ADD https://github.com/strfry/prussian/commits/${PRUSSIAN_REF}.atom /tmp/prussian-ref.atom
RUN git clone https://github.com/strfry/prussian.git /opt/prussian \
    && git -C /opt/prussian checkout "$PRUSSIAN_REF"
WORKDIR /opt/prussian

# Voller Durchbau. Downloads laufen ohne GitHub-API/gh (siehe Makefile: gh_dl).
RUN make build-eval
