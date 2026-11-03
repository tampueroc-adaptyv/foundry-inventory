== Conformance Example \#1 — Aliquoting

=== Natural Language

A scientist divides 100 µL of protein sample into two 50 µL aliquots in separate empty vials.

Both retain the same Material identity.

=== Initial State

- Material $M_1$, governed by $Sigma _1$.
- Source Vial $V_1$, Content $C_1$: 100 µL.
- Empty destination Vials $V_2,V_3$.

=== Operations

$ &op("PlaceContent")(M_1,V_2) arrow.r C_2 \

&op("PlaceContent")(M_1,V_3) arrow.r C_3 \

&op("TransferMaterial")(C_1,C_2,50 thin mu L) \

&op("TransferMaterial")(C_1,C_3,50 thin mu L) $

The committed movement is:

$ "MM"_("aliquot")=
lr((

&(C_1,M_1,-100 thin mu L), \

&(C_2,M_1,+50 thin mu L), \

&(C_3,M_1,+50 thin mu L)

)) $

=== Expected Result

$ op("Material")(C_1)
=
op("Material")(C_2)
=
op("Material")(C_3)
=
M_1 $

$ Q(C_1)&=0 thin mu L \

Q(C_2)&=50 thin mu L \

Q(C_3)&=50 thin mu L $

Required physical confirmation and inventory commitment checkpoints are satisfied before completion.

Interruption after one aliquot must not imply completion or non-occurrence of the other.
