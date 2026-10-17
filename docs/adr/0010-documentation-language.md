# 0010. Documentation language: English

- Status: Accepted
- Date: 2026-10-17

## Context
The project is open source. Its documentation and code comments are read by contributors and by AI agents that work on the code. Documents were kept in Russian and English in parallel, which caused them to drift apart.

## Decision
All documentation (specification, ADRs, plans, `AGENTS.md` files) and all code comments are written in English. The owner communicates in Russian; assistant answers follow the language of the user's message. The client UI is English for now.

## Alternatives
Russian for internal documents. Rejected: the open-source audience and the agents work in English, and maintaining two languages doubles the risk of drift.

## Consequences
Existing documents are translated. New decisions are written in English.
