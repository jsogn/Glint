# ADR-0003: ModelLab before app inference

## Status

Accepted.

## Decision

M1 model selection happens in `Tools/ModelLab` using Python and the candidate
models. The app's `GlintInference` layer stays behind a protocol and is not
wired to a model runtime until the model comparison selects a winner.

## Consequences

- Model experiments do not shape the app architecture prematurely.
- The default lightweight model can be chosen based on measured quality,
  latency, memory, and size.
- The eventual Swift adapter has a clear target runtime and model format.
