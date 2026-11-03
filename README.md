# Foundry Inventory

**A Traceable Material & Inventory System for Automated Laboratories**

Engineering design project prepared for Adaptyv Bio.

## Overview

Foundry Inventory explores how to model and maintain trustworthy material inventory in a high-throughput protein characterization laboratory.

The design focuses on scientific identity, physical containment, quantity accounting, provenance, operational eligibility and traceability.

## Repository Structure

| Path | Purpose |
|---|---|
| `docs/motivation.md` | Engineering approach and design rationale |
| `docs/decisions/` | Architecture Decision Records (ADRs) |
| [docs/diagrams/README.md](docs/diagrams/README.md) | Conceptual, relational and transfer-recovery diagrams (PNG previews and editable sources) |
| [docs/diagrams/appendix/foundry-inventory.excalidraw](docs/diagrams/appendix/foundry-inventory.excalidraw) | Complete physical ERD and retained diagram reference |
| `docs/whitepapers/` | Formal domain specifications |
| `src/` | PostgreSQL schema and implementation |

## Architecture

_To be completed._

## Development Methodology

This work began before receiving the assignment. Following my initial 1:1 conversation with Theo, I became interested in understanding how Adaptyv's laboratory operations could be represented as a software system.

I independently researched the business, explored wet-lab practices and existing solutions, and began developing a preliminary domain model and its underlying algebra.

The assignment subsequently provided concrete inventory requirements and a binding workflow against which I could validate, challenge, and refine that initial model.

### Phase 1 — Independent Exploration (Before the Assignment)

1. **Business research:** Investigated Adaptyv's business model, commercial context, and operational direction.
2. **Operational research:** Studied parSEQ and publicly available wet-lab practices.
3. **Adjacent solutions:** Explored Benchling and comparable systems to understand scientific identities and relationships.
4. **System invariants:** Identified preliminary correctness requirements around inventory, identity, provenance, and failure recovery.
5. **Algebraic formalization:** Began modeling entities, relationships, and state-transforming operations.

### Phase 2 — Assignment-Driven Design

6. **Binding workflow analysis:** Evaluated the supplied workflow against the preliminary model.
7. **Architecture Decision Records:** Documented architectural alternatives, decisions, and trade-offs.
8. **Scenario validation:** Challenged the model with partial execution, reruns, corrections, and scientific reassessment.
9. **Parallel modeling and LLM context ablation:**
   - Compared one-shot LLM-generated models using four contexts: brief only, brief + parSEQ, brief + Benchling, and brief + both.
   - Developed independent relational models and evaluated them against the same invariants.
10. **Implementation:** Translated the selected model into PostgreSQL structures, governed operations, and invariant tests.
11. **Final review:** Reconciled requirements, decisions, implementation, and documented limitations.

**Guiding principle:** Model the domain and its state transformations first; choose the database representation afterward. The schema should express the operational ontology and preserve its invariants, not define them by accident.

For the detailed reasoning behind the architecture, see [Engineering Approach & Design Rationale](docs/motivation.md).

## Implementation & Validation

_To be completed._

## Scope and Limitations

### Implementation Boundaries

The formal specifications and ADRs describe a broader operational model than the bounded PostgreSQL implementation delivered here.

The implemented slice demonstrates material and container identity, inventory movements, execution and effect separation, provenance for supported transformations, transactional accounting, idempotency, and selected historical corrections.

The following capabilities are intentionally limited:

- **Quality:** QC-gated eligibility and scientific invalidation are supported; initial QC approvals are seeded rather than established through a complete public QC workflow.
- **Material production:** Single-source reconstitution and provenance are supported; multi-source composition and incremental preparation are not implemented.
- **Specifications:** Published versions and explicit bindings are supported; existing entities cannot currently be rebound.
- **Corrections:** Quantity replacement is supported for selected movement types; generalized reversal and correction of incorrectly identified containers are not implemented.
- **Expiration:** Explicit holding-level expiration cutoffs are supported; environmental exposure evaluation and public cutoff assignment are deferred.

These boundaries distinguish the implemented demonstration from the broader domain contracts described in the whitepapers.
