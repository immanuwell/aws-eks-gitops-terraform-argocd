# Multi-stage build — minimal final image for security and size
# Stage 1: Build the Go binary
FROM golang:1.22-alpine AS builder

WORKDIR /build

# Copy go module files first for better layer caching
COPY go.mod go.sum ./
RUN go mod download

COPY . .

# Build static binary — no external dependencies in final image
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -trimpath \
    -ldflags="-s -w -extldflags '-static'" \
    -o /demo-app \
    ./cmd/server

# Stage 2: Minimal runtime image — no shell, no package manager, no root
FROM gcr.io/distroless/static-debian12:nonroot

# Build metadata labels (OCI Image Spec)
ARG BUILD_DATE
ARG VCS_REF
LABEL org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.title="demo-app" \
      org.opencontainers.image.description="EKS GitOps demo application" \
      org.opencontainers.image.source="https://github.com/immanuwell/aws-eks-gitops-terraform-argocd"

COPY --from=builder /demo-app /demo-app

# Run as non-root user (distroless nonroot = uid 65532)
USER nonroot:nonroot

EXPOSE 8080

ENTRYPOINT ["/demo-app"]
