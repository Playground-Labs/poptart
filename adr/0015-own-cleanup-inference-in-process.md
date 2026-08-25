# Own Cleanup inference in-process

The Poptart MVP will not depend on Ollama or expose external AI-provider configuration. Poptart will install and run one Managed Model for Cleanup inside its own process, controlling lifecycle, residency, request shape, latency, and failure behavior directly; users configure Cleanup behavior rather than model infrastructure.
