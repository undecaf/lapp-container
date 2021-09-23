FROM alpine:3.14

# Build command arguments
ARG MAJOR_VERSION
ARG BUILD_DATE
ARG COMMIT
ARG PRIMARY_TAG=exp
ARG DEPLOY_TAGS=exp

# Build _constants_ (do not change)
ARG APACHE_HOME=/var/www
ARG WWW_VOL=${APACHE_HOME}/www-vol
ARG PG_VOL=/var/lib/postgresql

# Build-time proxy settings (not persisted in the image)
ARG http_proxy=''
ARG https_proxy=''

LABEL \
    org.opencontainers.image.title="A LAPP container image" \
	org.opencontainers.image.description="Apache, PHP, PostgreSQL, Composer and ImageMagick" \
	org.opencontainers.image.version="${PRIMARY_TAG}" \
	org.opencontainers.image.revision="${COMMIT}" \
	org.opencontainers.image.url="https://hub.docker.com/r/undecaf/lapp-container" \
	org.opencontainers.image.documentation="https://github.com/undecaf/lapp-container/#a-lapp-container-image" \
	org.opencontainers.image.source="https://github.com/undecaf/lapp-container" \
	org.opencontainers.image.authors="Ferdinand Kasper <fkasper@modus-operandi.at>" \
	org.opencontainers.image.created="${BUILD_DATE}"

# Run the build inside the container-to-be-built
COPY build-files /
RUN /usr/local/bin/build

# Copy runtime files separately to save time on rebuilds if only the runtime was modified
COPY runtime-files /
RUN /usr/local/bin/configure

VOLUME ${WWW_VOL} ${PG_VOL}

EXPOSE 80 443 5432

# Customize the s6-overlay
ENV \
	S6_LOGGING=2 \
	S6_BEHAVIOUR_IF_STAGE2_FAILS=2

ENTRYPOINT ["/usr/local/bin/init"]
