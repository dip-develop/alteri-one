---
name: Feature request or idea
about: Suggest an idea for AlteriOne
labels: enhancement
---

**Problem to solve**

What are you trying to do, and what is missing? A concrete scenario beats a feature list.

**Proposed solution**

What you would change, roughly. Keep in mind the project principles in `docs/spec/product.md` (section 3): the core knows only contracts, domains live in extensions, fail closed.

**Alternatives considered**

Other approaches, including "do nothing".

**Scope check**

- Is this in the MVP scope (`docs/spec/product.md`, section 2.10, and `docs/spec/roadmap.md`)? If yes, name the milestone.
- Does it touch `PolicyGate`, taint labels, run capabilities, or the host API? Those are owner decisions — expect the issue to be converted into a spec change or ADR proposal first.
