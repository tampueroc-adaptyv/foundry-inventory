== Conformance Example \#7 — Material Identity Boundary

=== Natural Language

Two independently produced protein batches have identical measured sequence and concentration, but their specification requires distinct identities based on production origin.

=== Algebra

$ op("Attributes")(M_A)
=
op("Attributes")(M_B) $

Yet:

$ M_A≢_( Sigma _1)M_B $

Therefore:

$ op("IdentityDecision")( Sigma _1,"Batch"_B)
arrow.r
op("Create")(M_B) $

=== Expected Result

Separate Material identities and origin histories.

Matching attributes do not cause merging.
