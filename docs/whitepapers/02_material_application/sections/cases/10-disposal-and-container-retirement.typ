== Conformance Example \#10 — Disposal and Container Retirement

=== Natural Language

A vial contains 50 µL of material that must be disposed of. After the material is disposed of and accounted for, the vial is retired.

=== Initial State

- Container $V_1$: Active vial.
- ContainerContent $C_1$: 50 µL of Material $M_1$.
- Disposal destination `Disposed`: Internal accountable destination excluded from available stock.

=== Composition

The intended dependency may be expressed as:

$ op("TransferMaterial")(C_1,"Disposed",50 thin mu L)
arrow.r
op("RetireContainer")(V_1) $

This notation specifies that container retirement depends on the disposal being accounted for, under #link("../01_algebra_foundation/algebra.pdf")[Foundations, Section VI.C].

=== Disposal Movement

$ "MM"_("disposal")=
lr((

&(C_1,M_1,-50 thin mu L), \

&("Disposed",M_1,+50 thin mu L)

)) $

=== Expected Success

- Available material quantity becomes zero.
- Disposal is recorded with applicable evidence and authorization.
- Container retirement follows after its preconditions are satisfied.
- Both operations remain auditable.

=== Failure After Disposal

Suppose disposal is confirmed and committed, but container retirement fails.

Expected behavior:

- Disposal remains committed.
- The vial remains active pending resolution.
- The coordinating task or workflow records the incomplete dependency.
- No automatic reversal of disposal occurs.

=== Atomic Alternative

If the authoritative state changes for disposal and retirement are supported within one transaction boundary, their recorded effects may instead be grouped atomically:

$ op("TransferMaterial")(C_1,"Disposed",50 thin mu L)
times.o
op("RetireContainer")(V_1) $

This guarantees all-or-nothing commitment of those recorded effects.

It does not guarantee that physical disposal can be reversed.

=== Invalid Variations

- Retiring a container with unresolved active contents.
- Treating an ordered dependency as automatically atomic.
- Reversing confirmed disposal because retirement failed.
- Treating database rollback as reversal of a physical disposal action.
- Duplicating disposal movements during recovery.
