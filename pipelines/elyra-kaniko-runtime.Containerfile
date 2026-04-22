# Optional: runtime for Elyra pipeline node that runs pipelines/kaniko_build_push.ipynb.
# Elyra needs Python in the image; Kaniko provides /kaniko/executor (non-privileged build+push).
#
# OpenShift BuildConfigs often rewrite the *first* Dockerfile FROM to a curated base image.
# If this file began with `FROM gcr.io/...`, the final stage could incorrectly become the
# Kaniko image (distroless, no /bin/sh), and any `RUN` would fail. We therefore declare the
# UBI Python base first, then pull Kaniko as a separate stage.
#
# Build and push to your registry, then set REPLACE_ME_KANIKO_ELYRA_RUNTIME_IMAGE on the Kaniko pipeline node.
#
# Example:
#   podman build -f pipelines/elyra-kaniko-runtime.Containerfile -t quay.io/myorg/elyra-kaniko-runtime:1.0 .

FROM registry.access.redhat.com/ubi9/python-311:latest AS runtime

FROM gcr.io/kaniko-project/executor:v1.23.2 AS kaniko

FROM runtime

USER 0
# Avoid `RUN chmod` (needs /bin/sh); set permissions at copy time (Buildah / OCP builder).
COPY --chmod=755 --from=kaniko /kaniko /kaniko

ENV PATH="/kaniko:${PATH}"
