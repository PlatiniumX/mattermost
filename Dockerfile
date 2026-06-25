# syntax=docker/dockerfile:1
#
# Mattermost'u BU repodaki kaynak koddan derleyen Dockerfile.
# Coolify'da Build Pack olarak "Nixpacks" yerine "Dockerfile" seçilmelidir.
#
# 3 aşama:
#   1) webapp (Node) -> React istemcisi derlenir  (webapp/channels/dist)
#   2) server (Go)   -> mattermost + mmctl binary'leri derlenir ve paket toplanır
#   3) runtime       -> sadece çalışmak için gereken dosyalar (Team Edition)
#
# Not: Enterprise dizini (../enterprise) repoda olmadığı için Team Edition derlenir.

############################
# 1. Aşama: Web uygulaması #
############################
FROM node:24-bookworm AS webapp
WORKDIR /mm/webapp

# Tüm webapp kaynağını kopyala (postinstall platform workspace'lerini derlediği
# için bağımlılık kurulumu kaynağa ihtiyaç duyar — bu yüzden hepsini birlikte kopyalıyoruz)
COPY webapp ./

# devDependencies derleme için gerekli; production NODE_ENV'i atlardı
RUN npm ci --include=dev
RUN npm run build

###############################
# 2. Aşama: Go server derleme #
###############################
FROM golang:1.26.3-bookworm AS server
ENV GOFLAGS=-buildvcs=false
RUN apt-get update && apt-get install -y --no-install-recommends \
    make git ca-certificates \
  && rm -rf /var/lib/apt/lists/*
RUN git config --global --add safe.directory '*'

WORKDIR /mm
# Tüm repoyu kopyala (.git dahil — BUILD_HASH için gerekli)
COPY . .
# Web uygulamasının derlenmiş çıktısını 1. aşamadan al
COPY --from=webapp /mm/webapp/channels/dist ./webapp/channels/dist

WORKDIR /mm/server
# Go binary'lerini derle (build-client'ı tetiklemeden — webapp zaten hazır)
RUN make build-linux-amd64 BUILD_NUMBER=docker
# Paket dizinini topla (config, client, templates, i18n, fonts)
RUN make package-prep BUILD_NUMBER=docker \
  && mkdir -p dist/mattermost/bin dist/mattermost/logs \
  && cp bin/mattermost bin/mmctl dist/mattermost/bin/

####################
# 3. Aşama: Runtime #
####################
FROM ubuntu:noble
ARG PUID=2000
ARG PGID=2000

ENV PATH="/mattermost/bin:${PATH}"
ENV MM_SERVICESETTINGS_ENABLELOCALMODE="true"
ENV MM_INSTALL_TYPE="docker"

# Çalışma zamanı + döküman işleme bağımlılıkları
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
     ca-certificates media-types mailcap unrtf wv poppler-utils tidy tzdata \
  && rm -rf /var/lib/apt/lists/* \
  && groupadd --gid ${PGID} mattermost \
  && useradd --uid ${PUID} --gid ${PGID} --home-dir /mattermost mattermost \
  && mkdir -p /mattermost/data /mattermost/plugins /mattermost/client/plugins

# Derlenmiş Mattermost dağıtımını kopyala
COPY --from=server --chown=${PUID}:${PGID} /mm/server/dist/mattermost /mattermost
RUN chown -R ${PUID}:${PGID} /mattermost

USER mattermost
WORKDIR /mattermost

HEALTHCHECK --interval=30s --timeout=10s \
  CMD ["/mattermost/bin/mmctl", "system", "status", "--local"]

EXPOSE 8065 8067 8074
VOLUME ["/mattermost/data", "/mattermost/logs", "/mattermost/config", "/mattermost/plugins", "/mattermost/client/plugins"]

CMD ["/mattermost/bin/mattermost"]
