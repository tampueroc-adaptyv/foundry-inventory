== Conformance Example \#3 — Scientific Transformation

=== Natural Language

Digest a protein sample using a reagent, producing a distinct scientific preparation.

=== Operations

$ &op("RegisterMaterial")(M_2, Sigma _2) \

&op("ConsumeMaterial")(C_("protein"),q_1) \

&op("ConsumeMaterial")(C_("reagent"),q_2) \

&op("ProduceMaterial")(M_2,V_("output"),q_3) \

&op("DeriveMaterial")(M_2,{M_("protein"),M_("reagent")}) $

=== Expected Result

- Distinct output Material identity.
- Input consumption recorded.
- Output quantity tracked.
- Provenance retained.
- No universal assumption of input/output quantity equality.
- Failed execution does not automatically restore consumed inputs.
