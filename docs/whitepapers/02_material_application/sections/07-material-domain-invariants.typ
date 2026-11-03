= Material Domain Invariants <material-invariants>

These material-specific guarantees supplement the foundations. The index points to the defining rules and does not replace the movement invariant table. Each guarantee must be traced to implementation checks and conformance tests.

#table(
  columns: (1fr, 1fr),
  table.header([Guarantee], [Defining sections]),
  [Identity stability], [@material, @container],
  [Scientific identity and validation], [@material-specification],
  [Identity amendments and evidence], [@material-specification],
  [Nonnegative active quantities], [@movement-invariants],
  [Balanced, atomic, auditable movements], [@movement-invariants],
  [No duplicate component inventory], [@composite-accounting],
  [Traceable composition contributions], [@scientific-composition],
  [Exclusive physical placement], [@placement],
  [Acyclic containment], [@placement],
  [Placement compatibility], [@container-specification, @location-specification, @placement],
  [Versioned location conditions and use constraints], [@location, @eligibility, @expiration-assessment, @workflow-intervention],
  [Fixed well parent and position], [@placement],
  [Compatible, active content holdings], [@container-content],
  [Holding identity and active uniqueness], [@container-content],
  [Retirement resolves contents and children], [@container],
  [Traceable scientific provenance], [@provenance],
  [Dependent Scientific Assertion Integrity], [@provenance, invariant below; @scientific-correction-case],
  [Correction distinct from reconciliation], [@corrections, @correction-integrity],
  [Authorized restricted operations], [@movement-invariants, @decisions],
  [Context-dependent eligibility], [@eligibility],
  [Workflow admission and continuation authorization], [@eligibility, authorization boundaries below, @workflow-intervention, @scientific-correction-case],
  [Traceable, policy-governed stability assessment], [@expiration-assessment],
  [Derived availability, not a second balance], [@quantity-state],
)

Cross-domain coordination follows #link("../01_algebra_foundation/algebra.pdf")[Foundations, Section VI.D]; it does not weaken any participating domain's invariants.

*Dependent Scientific Assertion Integrity.* When an authoritative scientific assertion is corrected or superseded, dependent assertions and decisions must be evaluated for reassessment according to their applicable Specifications. Required unresolved reassessment must not silently preserve an authorization that depends on superseded evidence. From commitment of the relevant correction, affected approvals must not grant new material-use authorizations on stale evidence; delayed dependency evaluation must not create a stale-approval window. This applies through dependent assertions and decisions wherever their governing Specifications require it, without automatically invalidating every descendant. Historical assertions, committed movements, observations, and legitimate downstream operations remain traceable. Reassessment does not itself reverse physical activity or quantity postings.

*Authorization Boundaries During Execution.* A correction or supersession that requires reassessment prevents new affected material-use authorizations from relying on stale evidence from the time that correction becomes authoritative.

A physical operation already authorized and initiated before that point is not retroactively undone. Its actual outcome must be established and recorded under the applicable execution contract. Any subsequent affected operation must satisfy the required continuation conditions or obtain an appropriately authorized intervention decision before initiation.

An operator decision may permit continuation only within the exceptions and authority defined by the governing Specifications. Asynchronous notification or reassessment must not silently bypass a mandatory intervention boundary. At that boundary, authorization must be checked against the relevant authoritative restrictions and evidence versions, or an equivalent enforceable barrier; notification delivery alone is insufficient.

== Inherited Foundational Guarantees

Mandatory task lifecycle, checkpoint validation, owning-domain commitment, defined completion conditions, failure integrity, retry safety, supported atomic groups, and ordered dependencies remain obligations of #link("../01_algebra_foundation/algebra.pdf")[Foundations, Section VIII]. They are not redefined here or relaxed by a balanced movement.

A conforming material implementation must therefore preserve the foundational execution and composition guarantees as well as the material constraints above.
