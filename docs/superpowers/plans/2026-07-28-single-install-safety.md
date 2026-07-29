# Single-install safety implementation

1. Replace package-contract tests from the abandoned two-skill experiment with
   single-install security assertions.
2. Add browser device login to `account.sh`, with no secret output and atomic
   credentials storage.
3. Remove interactive key flags and alternate API host flags from public
   scripts while preserving `SHARENOW_API_KEY` for CI.
4. Rewrite the main skill as compact publish-first guidance with progressive
   capability discovery and an explicit untrusted-data boundary.
5. Park channel and local-codebase Knowledge Base helpers outside the
   installable directory while retaining their regression coverage.
6. Rebuild mirrored layouts, run package verification, install locally, and
   smoke-test anonymous and authenticated publishing against the server flow.
