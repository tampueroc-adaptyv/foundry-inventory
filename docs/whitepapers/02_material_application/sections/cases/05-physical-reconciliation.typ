== Conformance Example \#5 — Physical Reconciliation

=== Natural Language

The system reports 50 µL in a vial, while verified observation establishes 45 µL.

=== Algebra

$ op("ReconcileQuantity")(C_1,45 thin mu L,"Observation") $

$ "MM"_("reconcile")=
lr((

&(C_1,M_1,-5 thin mu L), \

&("Discrepancy",M_1,+5 thin mu L)

)) $

=== Expected Result

- Recorded quantity: 45 µL.
- Observation and authorization retained.
- Original history unchanged.
- Discrepancy traceable without inventing its cause.
