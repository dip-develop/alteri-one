# tools/: development tools

- Tools are not part of runtime dependencies (`publish_to: none`).
- Checks (`arch_check`, `codegen_check`, `docs_check`) are deterministic: the same repository gives the same result.
- Extension signing keys are stored outside the repository. They never appear in code or tests.
