== Conformance Example \#11 — Provenance-Dependent Material Expiration <expiration-case>

=== Scenario and Policy Fixture

A scientist aliquots protein stock Material $M_A$, then uses another portion to prepare diluted Material $M_B$. All dates and rules below are illustrative fixture assumptions, not scientific recommendations. Cutoffs are explicit UTC instants; a holding is expired at or after its applicable cutoff.

- Stock holding $C_S$: 100 µL of $M_A$, with accepted source assertion A.expiry.v1 valid through 30 November 2026; its cutoff is 1 December 2026, 00:00 UTC.
- Buffer holding $C_R$: 25 µL of distinct Material $M_R$, with acceptable input stability and condition evidence.
- Empty, compatible destination vials for aliquot $C_A$ and diluted preparation $C_B$; intended use $u$ requires stability approval.
- Preparation time: 25 November 2026, 09:00 UTC. All required evidence is initially satisfactory.
- MaterialSpecification version A1 preserves scientific identity on aliquoting and limits a new aliquot to 48 hours after division, capped by the accepted source expiry.
- MaterialSpecification version B1 requires a distinct diluted identity, stable inputs at preparation, and validated method/handling evidence. It allows 24 hours after preparation and requires reassessment when referenced source stability assertions change.

=== Preparation and Execution Contract

Transfer 50 µL from $C_S$ to $C_A$ without changing Material identity. Consume another 25 µL from $C_S$ and 25 µL from $C_R$ to produce 50 µL of $M_B$ in $C_B$, assuming additive volumes and no loss. Commit the confirmed movements and retain source, method, and execution references.

Recorded quantities are then 25 µL in $C_S$, zero in $C_R$, and 50 µL in each output holding. Accepted assessments establish an aliquot cutoff of 27 November 2026, 09:00 UTC and a diluted-preparation cutoff of 26 November 2026, 09:00 UTC.

The preparation and reassessment TaskSchemas bind policy and assertion versions, inputs, actors, and evidence. Required checkpoints establish provenance and conditions, authorized assessment, and any required assertion or restriction commitment before completion. A resolved expired assessment may complete successfully; missing required evidence places this fixture's assessment execution in `AwaitingEvidence`. Apply @expiration-assessment, not an implicit copy of the source date.

=== Independent Resolution Branches

*A — Passage of time.* At 27 November 2026, 10:00 UTC, both output holdings are expired and ineligible for $u$, although the original stock's accepted source cutoff has not passed. For either output holding $c$:

$ Q_("recorded")(c)&=50 thin mu L \
Q_("available")(c,u,t)&=0 thin mu L $

No movement, disposal, or holding closure is implied by expiration.

*B — Missing condition evidence.* Before either output cutoff, required storage evidence for $C_B$ is missing. Its assessment is `Unknown`, not approval; available quantity for $u$ is zero while recorded quantity remains 50 µL. A future accepted date alone cannot substitute for the missing evidence.

*C — Amended source knowledge.* Independently, at 25 November 2026, 12:00 UTC, authorized evidence changes the source cutoff to 25 November 2026, 10:00 UTC in A.expiry.v2. Preserve A.expiry.v1 and its authority, evidence, and versions. Trigger the reassessments required by A1 and B1, restricting use while required outcomes remain unresolved.

After authorized reassessment, $C_A$ is expired under A1's source cap. Under B1, the source was still stable at the recorded 09:00 preparation time; with the other conditions satisfied, $C_B$ may retain its 26 November cutoff and remain valid at 12:00. Retain each new assessment's rule, evidence, source-version, and authority links. Neither source amendment nor reassessment changes quantities or silently rewrites descendant dates.

=== Invalid Variations

- Expiration or missing stability evidence treated as material consumption or disposal.
- Missing assessment treated as approval, or `Valid` stability treated as unconditional eligibility.
- Aliquot handling history discarded because scientific identity is unchanged.
- A fresh stability period assigned automatically to every transformation.
- All descendants receiving a copied source date without policy-governed reassessment.
- Earlier assertions, governing versions, evidence, or authority overwritten.
