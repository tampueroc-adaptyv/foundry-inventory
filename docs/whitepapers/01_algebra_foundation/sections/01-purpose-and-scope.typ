= Purpose and Scope <foundation-purpose>

Define a foundational reference for how laboratory work changes system state. The document has three responsibilities:

1. *Conceptual data modeling:* Define primitives, relationships, and identity boundaries from which domain models and future schemas can be derived.
2. *Operational correctness:* Define valid transitions, invariants, commitment rules, and the treatment of failure, uncertainty, retries, and corrections.
3. *System-design constraints:* Establish authority and coordination boundaries while leaving implementation mechanisms open.

This document defines the common modeling language and correctness guarantees for laboratory domains, including instruments, analytical results, procurement, scheduling, and material inventory. It does not define any one of those domain models.

== Reasoning Structure

The document proceeds from primitives and state, through task lifecycle and composition, to domain derivation and domain-independent conformance. Definitions establish meaning; invariants establish guarantees; worked cases test their consequences. Formal completeness, internal consistency, and derivability take priority over brevity.

== Architectural Principle <architecture>

*Required semantics, open mechanisms:* A conforming implementation preserves the defined identities, invariants, authority boundaries, and failure semantics. This document does not require a particular database, service decomposition, event-storage pattern, orchestration engine, or algebra interpreter. A logical domain denotes responsibility for state and its rules, not necessarily a deployed service.

Scheduling, reservations, procurement and suppliers, instrument automation, and specialized scientific processing remain capabilities with defined interfaces. Customer experiments and service orders may supply work translated into internal tasks and workflows.

== Specialization Contract <specialization-contract>

The foundational algebra defines the general semantics and correctness requirements for modeling laboratory operations. Domain models specialize its primitives, state structures, operations, and invariants. A domain specialization may introduce additional constraints but must not weaken or contradict the foundational guarantees.

The companion #link("../02_material_application/material-inventory.pdf")[Foundry Inventory — Material & Inventory Operations] is one such specialization. The two documents share v1.7 as their compatibility baseline; a domain revision must identify the foundation version against which it claims conformance. Changes to a domain do not by themselves require changes to the foundations.
