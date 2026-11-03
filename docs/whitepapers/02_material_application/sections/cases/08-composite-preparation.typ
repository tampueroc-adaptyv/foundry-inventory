== Conformance Example \#8 — Composite Preparation

=== Natural Language

Combine 80 µL of protein solution with 20 µL of buffer to produce one mixed preparation.

Assume additive volumes and no loss for this example.

=== Operations

$ &op("RegisterMaterial")(M_C, Sigma _C) \

&op("ConsumeMaterial")(C_A,80 thin mu L) \

&op("ConsumeMaterial")(C_B,20 thin mu L) \

&op("ProduceMaterial")(M_C,V_C,100 thin mu L) \

&op("DeriveMaterial")(M_C,{M_A,M_B}) \

&op("RecordComposition")(M_C,{(M_A,0.8),(M_B,0.2)}) $

The input consumption movements are:

$ "MM"_A=
lr((

&(C_A,M_A,-80 thin mu L), \

&("Consumed",M_A,+80 thin mu L)

)) $

$ "MM"_B=
lr((

&(C_B,M_B,-20 thin mu L), \

&("Consumed",M_B,+20 thin mu L)

)) $

The output production movement is:

$ "MM"_C=
lr((

&("Produced",M_C,-100 thin mu L), \

&(C_C,M_C,+100 thin mu L)

)) $

=== Expected Result

$ Q(C_C)=100 thin mu L $

$ op("Composition")(M_C)
=
{(M_A,0.8),(M_B,0.2)} $

One output quantity is available.

Its components are not counted again as independent inventory.

Confirmed consumption remains recorded if later preparation steps fail.
