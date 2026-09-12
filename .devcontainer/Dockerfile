# Dev container for working on sclaude itself. It is built from a Dockerfile
# rather than used straight from the image so the apt mirror can be chosen:
# the features and postCreateCommand below install on top of this, and
# inherit whatever sources it leaves behind.
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

# Empty means Ubuntu's own archive, which is the right default nearly
# everywhere. CI names a mirror in the datacentre its runners live in: from
# the default archive one package index there has taken ten minutes and timed
# the job out. A layout this does not understand fails the build rather than
# quietly falling back to the slow default.
ARG APT_MIRROR=""
RUN set -eux; \
    if [ -n "${APT_MIRROR}" ]; then \
        for f in /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources; do \
            [ -f "$f" ] || continue; \
            sed -i -E "s#https?://(archive[.]ubuntu[.]com/ubuntu|ports[.]ubuntu[.]com/ubuntu-ports|security[.]ubuntu[.]com/ubuntu)/#${APT_MIRROR}#g" "$f"; \
        done; \
        grep -Rqs -- "${APT_MIRROR}" /etc/apt/sources.list /etc/apt/sources.list.d/; \
    fi
