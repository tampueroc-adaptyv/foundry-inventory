= Domain Operations <material-operations>

#table(
  columns: (1fr, 1fr),
  table.header([Operation], [Meaning]),
  [`RegisterMaterial`], [Register scientific Material identity],
  [`ReceiveMaterial`], [Introduce material into tracked inventory],
  [`TransferMaterial`], [Move quantity between accountable positions],
  [`PlaceContent`], [Associate Material with a compatible Container],
  [`RelocateContainer`], [Change a Container's placement],
  [`ConsumeMaterial`], [Account for material used],
  [`ProduceMaterial`], [Account for material produced],
  [`DeriveMaterial`], [Record scientific lineage],
  [`RecordComposition`], [Record constituent identities and contributions],
  [`DiscardMaterial`], [Account for material disposed],
  [`RetireContainer`], [End a Container's active lifecycle],
  [`ReverseMovement`], [Compensate erroneous movement history],
  [`ReplaceMovement`], [Supersede an erroneous movement],
  [`ReconcileQuantity`], [Align recorded quantity with verified observation],
  [`RecordObservation`], [Record scientific or physical evidence],
  [`RecordDecision`], [Record authorized quality or disposition decisions],
)

These operations specialize the general transition contract: they propose entity, relationship, lifecycle, decision, or movement effects. TaskSchema CommitRules govern permission to propose (#link("../01_algebra_foundation/algebra.pdf")[Foundations, Section V.D]); the owning domain validates and commits. Their semantic composition follows #link("../01_algebra_foundation/algebra.pdf")[Foundations, Section VI.E].

== Permitted Effect Families

These operation families identify what may change; each proposal is still subject to current-state validation, applicable Specifications, evidence, and authorization by the owning domain.

- `RegisterMaterial` proposes scientific identity creation and Specification binding. `PlaceContent` proposes a holding and its Material/Container links; it does not itself introduce quantity. `RelocateContainer` changes placement. `RetireContainer` changes lifecycle only after active contents and child placements are resolved.
- `ReceiveMaterial`, `TransferMaterial`, `ConsumeMaterial`, `ProduceMaterial`, and `DiscardMaterial` propose movement postings. `ReverseMovement`, `ReplaceMovement`, and `ReconcileQuantity` propose the linked correction or discrepancy postings defined in @corrections, with evidence and authority rather than an implied physical action.
- `DeriveMaterial` and `RecordComposition` propose scientific relationships and contribution assertions. Neither independently creates available stock.
- `RecordObservation` records evidence without automatically changing quantities. `RecordDecision` proposes a scoped, authorized decision; it may change eligibility without moving material.

The list is an effect-family contract, not a complete scientific protocol for each operation. Concrete TaskSchemas add their typed bindings, lifecycle conditions, and required outcomes (@material-applications).
