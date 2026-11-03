== Conformance Example \#9 — Automated Transfer Timeout

=== Natural Language

An instrument receives a command to transfer 20 µL from a vial to a plate well.

Communication times out before completion is confirmed.

=== Initial State

- Material $M_1$.
- Source Content $C_A$: 100 µL.
- Destination well empty.
- No committed transfer movement.

=== Lifecycle Checkpoints

#table(
  columns: (1fr, 1fr),
  table.header([Checkpoint], [Condition]),
  [`CommandAccepted`], [Instrument acknowledges command],
  [`TransferConfirmed`], [Actual transferred quantity established],
  [`InventoryCommitted`], [Material domain confirms movement],
  [`ExecutionResolved`], [Required outcomes accounted for],
)

After timeout:

$ "Running" arrow.r "AwaitingEvidence" $

No unverified movement is committed.

Blind physical retry is prohibited.

=== Resolution A — Full Transfer

Evidence confirms 20 µL.

The Material domain commits:

$ "MM"=
lr((

&(C_A,M_1,-20 thin mu L), \

&(C_B,M_1,+20 thin mu L)

)) $

Result:

$ Q(C_A)=80 thin mu L, quad Q(C_B)=20 thin mu L $

=== Resolution B — No Transfer

Reliable evidence confirms no movement.

Inventory remains unchanged.

The execution resolves according to its lifecycle contract.

=== Resolution C — Partial Transfer

Evidence confirms only 12 µL moved.

The domain commits a 12 µL transfer.

The task may fail its intended 20 µL requirement without reversing the confirmed movement.

=== Resolution D — Unknown Outcome

The outcome cannot be established.

No invented quantity is committed.

The execution and affected inventory remain subject to explicit resolution or reconciliation.

=== Invalid Variations

- Timeout interpreted as proof of non-occurrence.
- Acknowledgment interpreted as proof of physical completion.
- Blind physical retries.
- Duplicate postings on repeated completion messages.
- Completion before required commitments.
- Automatic reversal of confirmed effects after failure.
