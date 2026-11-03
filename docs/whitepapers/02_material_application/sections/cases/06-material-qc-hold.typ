== Conformance Example \#6 — Material QC Hold

=== Natural Language

A reference standard vial contains 50 µL. A QC reviewer places it on hold for validated analytical methods.

=== Algebra

Initially:

$ op("Eligible")(C_1,u_("validated"),t,S, Sigma )
=
"Yes" $

The authorized decision is recorded:

$ op("RecordDecision")(C_1,"Hold",E_1) $

$ D'=D union {op("Hold")(C_1,E_1)} $

$ S_M'=S_M $

Afterward:

$ op("Eligible")(C_1,u_("validated"),t',S', Sigma )
=
"No" $

=== Expected Result

- Quantity and placement unchanged.
- Hold decision committed.
- Restricted use becomes ineligible.
- Other uses are evaluated under their policies.
- Required decision commitment precedes task completion.
