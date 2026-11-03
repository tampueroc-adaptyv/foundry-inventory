= Validation and Implementation Mapping <material-validation>

A complete executable conformance case must specify:

1. Natural-language scenario.
2. Initial state.
3. TaskSchema and mandatory lifecycle contract.
4. Relevant operation composition or dependencies.
5. Execution events and checkpoint evaluations.
6. Lifecycle transitions.
7. Proposed and committed effects.
8. Expected resulting state.
9. Applicable invariants.
10. Invalid variations and failure behavior.

The twelve worked cases above establish core semantic expectations; not every case yet supplies a complete executable fixture. The coverage inventory below includes both worked scenarios and scenarios to develop under this methodology:

#table(
  columns: (1fr, 1fr),
  table.header([Scenario], [Primary modeling concern]),
  [Aliquot a sample], [Shared identity, transfers, interruption],
  [Transfer into a plate well], [Unified Container model, atomic content creation],
  [Move a vial between boxes], [Placement constraints],
  [Store or process material at a qualified location], [Versioned storage conditions, containment gates, process capabilities, and capacity; @eligibility, @location-specification, and @workflow-intervention],
  [Consume a reagent], [Quantity accounting],
  [Dilute a sample], [Identity and quantity transformation],
  [Digest a protein], [Scientific derivation and irreversible consumption],
  [Mix a preparation], [Composition without duplicate inventory],
  [Independently produce protein batches], [Material identity boundaries],
  [Dispose of material and retire container], [Ordered dependency and transaction boundaries],
  [Correct concentration metadata], [Scientific correction without physical movement],
  [Correct a preparation after downstream use], [Assertion-version dependencies, preserved accounting, and reassessment without stale authorization; case 12],
  [Reverse an erroneous transfer], [Historical correction],
  [Replace an incorrect transfer], [Supersession and atomic correction],
  [Reconcile stock], [Recorded versus observed quantity],
  [Place material on QC hold], [Decision state versus material state],
  [Provenance-dependent expiration], [Stability, holding history, and policy-triggered reassessment without quantity movement],
  [Release material for specific use], [Context-dependent eligibility],
  [Admit a workflow and intervene after correction], [Pre-flight eligibility, continuation boundaries, and operator authority; @workflow-intervention and case 12],
  [Release analytical results (interface)], [Delegation to result-domain authority],
  [Automated transfer timeout], [Uncertain execution, safe retries, and effect commitment],
)

Conformance review checks both directions: every required invariant needs a test, and every test outcome must follow from a definition or guarantee. Material-model revisions follow the same derivation method (#link("../01_algebra_foundation/algebra.pdf")[Foundations, Section VII]). Additional domain constraints must remain consistent with the pinned foundational contract; a missing material scenario is not by itself a reason to redefine the algebra.

== Two-Level Implementation Evidence

The foundational obligations F-01 through F-12 in #link("../01_algebra_foundation/algebra.pdf")[Foundations, Section VIII] require independent evidence. The material cases add the following implementation mappings.

#table(
  columns: (1fr, 2fr),
  table.header([Domain concern], [Required mapping and evidence]),
  [Identity and Specifications], [Stable identifiers, pinned Specification versions, scientific validation, and amendment history; identity preservation and separation in cases 1 and 7],
  [Containment and placement], [Stable holding identifiers, active holding uniqueness, Material/Container links, fixed positions, compatibility, and acyclicity checks; well constraints in case 2],
  [Quantities and movements], [Material/dimension balance, individually identified postings without deduplication, compatible units, nonnegative active quantities, atomic commitment, and correction integrity after later activity; cases 1–5 and 8–10],
  [Provenance and composition], [Source and execution references, contribution values and measurement basis, versioned scientific dependencies, and absence of duplicate stock; cases 3, 8, 11, and 12],
  [Decisions and eligibility], [Decision scope, evidence, authority, effective history, intended-use assessment, versioned stability assertions, policy-triggered reassessment, and derived availability without changing recorded quantity; cases 6, 11, and 12; admission evidence and no new authorization on stale approval after a relevant correction commits],
  [Execution and recovery], [TaskSchema versions, lifecycle transitions, checkpoint evidence, effect identities, dependencies, uncertainty, and safe retries; cases 9 and 10. Workflow admission and continuation checks, enforceable restriction/version barriers, scoped operator authority, and duplicate/delayed notifications; @workflow-intervention and case 12],
)

The table identifies traceability obligations, not mandatory database tables or service boundaries. Every proposed schema element or architectural responsibility must link to a domain concept, owning authority, invariant, and conformance test. Additional fixtures are needed for the coverage inventory above, especially concurrency, relocation, containment cycles, and unauthorized operations. Include distinct postings with equal payloads, repeated same-Material receipts into one Container, availability under `Unknown` eligibility, and correction after legitimate subsequent consumption.

Location conformance evidence must additionally exercise nearest-declaring-location storage lookup, missing condition history, and relocation between qualified and unqualified storage. Under a fixture policy allowing six months at a specified −80 °C range, calculate stability from qualifying history rather than a current freezer label. Test a BSL-2-required use outside its authorized scope (`No`), missing containment evidence (`Unknown`), a characterization step at an incompatible location, and capacity overflow. None of these assessments independently changes recorded quantity.

== Review Deliverables

A material implementation provides a derivation map, a correctness contract, and conformance evidence. Together they must demonstrate scientific identity, provenance, containment, quantity correctness, historical integrity, operational eligibility, and execution correctness.

A domain-specific design choice is acceptable only if it satisfies both this specification and the pinned foundations. Future specifications for instruments, results, quality, or scheduling can specialize the same foundations without importing this material-accounting model.
