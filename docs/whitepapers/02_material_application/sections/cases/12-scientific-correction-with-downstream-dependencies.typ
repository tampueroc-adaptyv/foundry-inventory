== Conformance Example \#12 — Scientific Correction with Downstream Dependencies <scientific-correction-case>

=== Scenario and Policy Fixture

Source holdings contain 100 µL each of distinct Materials A and B. A preparation execution records consumption of 80 µL A and 20 µL B to produce 100 µL of P, with composition assertion P.comp.v1 recording volume fractions 0.8 and 0.2. Assume additive volumes and no loss. Subsequent legitimate executions consume 20 µL P to produce 20 µL D and 10 µL P to produce 10 µL U, leaving 70 µL P. Each output retains its source and generating-execution references.

Pinned Specifications define this fixture's dependencies: D's calculated concentration assertion and use approval reference P.comp.v1 and require reassessment when it changes. U's approval instead depends on an independent accepted measurement; its Specification does not require reassessment for this source-composition change. P's identity rule permits the corrected proportions under the same identity; identity-changing corrections would require a separate authorized identity assessment, not silent relabeling.

=== Correction and Execution Contract

New evidence establishes that the preparation actually consumed 70 µL A and 30 µL B. Recording that evidence alone changes neither quantities nor approval authority. An authorized correction execution binds the governing versions, original movements, assertions, and evidence. Its checkpoints establish the actual inputs, current-state accounting validity, scientific identity decision, superseding assertion, and protection against stale approval before correction completion.

Replace the two erroneous input-consumption movements with 70 µL A and 30 µL B using validated reversal/replacement groups. The net corrections return 10 µL to A's holding and debit another 10 µL from B's holding, with balancing consumption-position postings. Source balances become 30 µL A and 70 µL B. Preserve P's 100 µL production and both downstream consumptions; P remains at 70 µL, D at 20 µL, and U at 10 µL. Commit authorized P.comp.v2 with fractions 0.7 and 0.3, explicitly superseding P.comp.v1 while preserving both versions and their evidence.

Do not assume a shared transaction across scientific and decision authorities. Whatever coordination is used must enforce @material-invariants's stale-approval protection from the relevant scientific correction's commitment.

=== Expected Results and Invalid Variations

- D's affected assertion and approval require reassessment. While mandatory reassessment is unresolved, a downstream task cannot use the prior approval; eligibility for that use is not approved and available quantity is zero, while recorded D quantity remains 20 µL.
- Test a use request after correction commitment but before dependency processing completes, including a request prechecked before correction. Neither may rely on the stale approval to authorize use.
- Authorized reassessment reaffirms, amends, or restricts D under its Specification, retaining prior assertions and decisions and recording the new source-version, evidence, and authority links. Missing evidence leaves reassessment unresolved.
- U's unaffected approval remains usable if its other eligibility conditions hold. Shared ancestry alone must not invalidate it.
- Reassessment propagates further where required by dependent Specifications, not through indiscriminate descendant invalidation.
- Reject correction groups that violate current quantity or other invariants; do not erase downstream consumption, rewrite observations, fabricate stock, or retarget historical Material references to force acceptance. No correction or reassessment implies a new physical preparation.

=== Active Workflow During Scientific Correction

This branch starts after D and U are produced but before the correction above commits. A workflow W admits 20 µL of D for an assay requiring D's accepted composition-dependent authorization. Pre-flight eligibility is satisfied under the original accepted assertion P.comp.v1. The workflow records the relevant authorization references and establishes custody according to its external allocation contract. Admission and custody alone leave D's recorded quantity unchanged.

W authorizes and initiates a robotic transfer using D. Before the instrument confirms the transfer outcome, the correction execution commits P.comp.v2, superseding P.comp.v1. D's governing Specification requires reassessment of the affected authorization.

The instrument may finish the operation already initiated. Its confirmed or unresolved physical outcome is handled using the existing TaskExecution and MaterialMovement rules. No physical reversal is inferred from the scientific correction. Confirmed transfer postings update the actual source and destination holdings; the earlier 20 µL balance for D is not assumed to remain in its original holding after transfer.

Before W initiates its next composition-dependent operation, the workflow must satisfy its continuation conditions or obtain an explicit intervention decision from an operator with the required authority. The decision must retain the corrected evidence, governing Specification, permitted exception or resolution, and effective history.

Expected results:

- Pre-flight authorization and the subsequent correction remain traceable.
- The operation already underway is resolved according to physical evidence, not retroactively canceled. Confirmed effects remain recordable after correction; uncertain or partial outcomes follow the existing execution rules.
- The next affected operation cannot begin using the stale authorization, even before a delayed correction notification arrives. A prechecked but not yet initiated operation must pass the applicable authorization boundary under the corrected state.
- An unaffected operation may proceed if its governing rules permit independent execution.
- Authorized continuation, rework, quarantine, or termination preserves the earlier committed movements and execution history. Continuation requires an applicable permitted exception or resolution, never waiver of a non-waivable requirement.
- A duplicate or delayed correction notification cannot bypass or duplicate the required intervention.
- An operator lacking the required authority cannot permit continuation.
