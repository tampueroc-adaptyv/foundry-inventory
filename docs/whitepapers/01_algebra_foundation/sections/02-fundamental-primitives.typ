= Fundamental Primitives

We begin with six conceptual primitives.

#table(
  columns: (1fr, 1fr),
  table.header([Primitive], [Definition]),
  [`Entity`], [An identifiable thing with a lifecycle],
  [`Relationship`], [A typed association between identifiable things],
  [`Specification`], [A versioned definition of structure, constraints, or behavior],
  [`Task`], [An independent unit of intended work],
  [`Event`], [An immutable record of something that occurred],
  [`Effect`], [A proposed or committed change to system state],
)

These are conceptual building blocks, not necessarily six generic database tables. Entity identity remains stable through permitted state changes. Identity reuse, creation, and amendment follow explicit versioned Specifications rather than implicit merging based on matching attributes. Relationship endpoint types, cardinality, and temporal constraints are defined by each specialization.

Each Specification must declare its applicability, version-binding, and reevaluation policy: which entities, executions, and authorizations it governs; when a version is bound; and whether a version change retains existing bindings or requires reassessment. The policy must address in-flight executions and existing entities, decisions, and authorizations, including reassessment triggers and timing and any permitted rebinding. Reassessment or rebinding must be authorized and recorded with the prior versions and history preserved. There is no universal rule requiring either automatic upgrade or indefinite use of an earlier version; a new version must not silently reinterpret existing records.

- *Entities and relationships* describe the modeled world.
- *Specifications* define contracts and constraints.
- *Tasks* describe intended work.
- *Events* record what happened.
- *Effects* describe changes to system state.

Events may occur independently of tasks. A task may produce zero, one, or multiple effects.

Intended effects are distinguished from effects actually committed to authoritative state.

These primitives describe conceptual roles, not disjoint storage types. A TaskSchema is a Specification; its TaskExecution has Entity identity and records Events and Effect references. A recorded decision may likewise have stable Entity identity while its commitment changes decision state. Domain derivation must make these roles and their connections explicit (@domain-derivation).
