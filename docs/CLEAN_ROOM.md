# Clean-Room Reference Policy

This repository intentionally studies upstream behavior without directly porting GPL source code into Swift.

Project license target:
- MIT

Rules:
- Treat `refs/` as behavioral references, not copy sources.
- Do not paste or mechanically translate upstream functions, structs, or file layouts.
- Do not reuse upstream GPL code in a way that would compromise an MIT-licensed clean-room implementation.
- Prefer public documentation first.
- Use references to answer questions that docs do not cover, especially for wire behavior and edge cases.
- When an implementation choice depends on hidden or undocumented behavior, write down:
  - which reference repo informed it
  - the file or subsystem inspected
  - the behavior being matched
  - why it matters for interoperability

Recommended workflow:
1. Describe the behavior to reproduce in plain English.
2. Verify it across at least one client reference and, when possible, Sunshine or Apollo host behavior.
3. Implement the behavior idiomatically in Swift.
4. Add an interoperability or regression test.
