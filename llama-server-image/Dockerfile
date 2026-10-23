# COPY-only darwin/arm64 image; k3sm builds it natively with `k3sm build`.
# Populate ctx/ with ./bundle.sh first.
FROM scratch
COPY ctx/bin/ /app/bin/
COPY ctx/lib/ /app/lib/
ENTRYPOINT ["/app/bin/llama-server"]
