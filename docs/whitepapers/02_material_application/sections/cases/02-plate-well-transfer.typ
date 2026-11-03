== Conformance Example \#2 — Plate Well Transfer

=== Natural Language

Transfer 20 µL of protein sample from a vial into well A1 of a 96-well plate.

=== Initial State

- Material $M_1$.
- Source Vial $V_1$, Content $C_1$: 100 µL.
- Plate $P_1$ with 96-well specification.
- Well $W_1$ fixed at A1 and initially empty.

=== Operations

$ op("PlacedIn")(W_1,P_1,"A1") $

$ &op("PlaceContent")(M_1,W_1) arrow.r C_2 \

&op("TransferMaterial")(C_1,C_2,20 thin mu L) $

Movement:

$ "MM"_("well")=
lr((

&(C_1,M_1,-20 thin mu L), \

&(C_2,M_1,+20 thin mu L)

)) $

=== Expected Result

- Source vial: 80 µL.
- Well A1: 20 µL.
- Same scientific Material.
- Fixed well position preserved.
- Required effects committed.

The content creation and transfer postings may form an atomic effect group within the Material domain.
