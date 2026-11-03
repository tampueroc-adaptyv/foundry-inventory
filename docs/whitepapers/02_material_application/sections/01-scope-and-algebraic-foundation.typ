= Scope and Algebraic Foundation <material-scope>

This specification derives the material and inventory specialization of #link("../01_algebra_foundation/algebra.pdf")[Foundations, Section I], Draft v1.7. It covers scientific identity, containment, quantities, provenance, composition, material decisions, operational eligibility, and the laboratory operations that change them.

The foundational algebra defines the general semantics and correctness requirements for modeling laboratory operations. Domain models specialize its primitives, state structures, operations, and invariants. A domain specialization may introduce additional constraints but must not weaken or contradict the foundational guarantees.

== Responsibilities and Limits

The material domain owns its scientific identities, containment representation, and quantity accounting. Decision state has an explicitly designated decision authority; task and workflow execution retain their own lifecycle authority. These logical responsibilities do not require separate services or a single shared database.

Instrument control, scheduling, reservations, procurement and suppliers, specialized scientific processing, and comprehensive analytical-result management are outside this specification. They interact through defined references, evidence, effects, and dependencies. Customer experiments and service orders may supply work translated into internal tasks and workflows.

Balanced material postings are an additional requirement of this specialization, not a universal rule imposed on every domain by the foundations.

== Derivation and Conformance

A design is evaluated at two levels: foundational conformance to #link("../01_algebra_foundation/algebra.pdf")[Foundations, Section VIII], and material-domain conformance to @material-invariants and the twelve cases in @material-cases. Passing one level does not establish the other.

The following mapping applies the derivation method (#link("../01_algebra_foundation/algebra.pdf")[Foundations, Section VII]); it does not add universal primitives.

#table(
  columns: (1fr, 1fr),
  table.header([General role], [Material specialization]),
  [Entity], [Material, Container, Location, ContainerContent; stable records for movements and decisions],
  [Relationship], [Placement, content-to-material/container links, derivation, composition, supersession],
  [Specification], [MaterialSpecification, ContainerSpecification, LocationSpecification, and applicable task or decision contracts],
  [Task], [TaskSchemas such as AliquotSample and ReviewMaterialQC, invoked as TaskExecutions],
  [Event], [Transfer confirmations, observations, checkpoint results, and execution transitions],
  [Effect], [Identity or content creation, placement changes, committed movement postings, and decision changes],
)

ContainerContent is an identifiable holding, not a second scientific Material. A committed MaterialMovement is an immutable record of an accepted quantity Effect, not evidence by itself that a physical action occurred. Decisions have their own scope and authority even when they govern material use.
