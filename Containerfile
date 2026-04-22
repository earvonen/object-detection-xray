# ModelCar-style OCI image: serveable model artifacts live under /models.
# See Red Hat guidance on OCI "modelcar" images (e.g. AI Inference Server / KServe patterns).
#
# Build context should be the repository root (after training so weights exist):
#   podman build -f Containerfile -t <your-registry>/<image>:<tag> .
#
# COPY paths assume train.ipynb wrote weights to runs-openshift/exp1/weights/.

FROM registry.access.redhat.com/ubi9/ubi-micro:latest

# Optional: record dataset metadata alongside the checkpoint for downstream services.
COPY images/data.yaml /models/data.yaml
COPY runs-openshift/exp1/weights/best.pt /models/best.pt

USER 1001
WORKDIR /models
