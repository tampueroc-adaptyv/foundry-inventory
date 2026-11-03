= General Invariants and Conformance <general-conformance>

The execution invariants (@execution-invariants), composition invariants (@composition-invariants), state-validation rules (@domain-state), and specialization contract (@specialization-contract) apply to every domain. The obligations below test those guarantees independently of any material or inventory model.

== Foundational Conformance Obligations

#table(
  columns: (1fr, 2fr),
  table.header([Obligation], [Required test and outcome]),
  [F-01 — Identity and versions], [Exercise identity reuse, creation, and amendment under pinned Specifications. Permitted changes preserve Entity identity and prior assertions; changed rules do not silently reinterpret existing references.],
  [F-02 — Authority and valid state], [Attempt an unauthorized effect and a stale-precondition commitment after a concurrent change. The owning domain prevents an invalid authoritative transition.],
  [F-03 — Evidence and history], [Record an observation and correct an erroneous assertion. Evidence alone does not authorize a state change; correction preserves the original history and its links.],
  [F-04 — Lifecycle and checkpoints], [Attempt an undeclared transition and a transition whose checkpoint is unresolved or failed. Neither is accepted as satisfying the required contract.],
  [F-05 — Proposal and completion], [Propose a disallowed effect; then reject or leave unresolved a required effect. Proposal permission and domain acceptance remain distinct, and completion is blocked until required outcomes are satisfied. Optional effects follow the contract's explicit completion rules.],
  [F-06 — Failure and cancellation], [Fail or cancel an execution after a valid commitment. The commitment remains authoritative; cancellation requests do not prove that external activity stopped.],
  [F-07 — Uncertain execution], [Withhold acknowledgment or completion evidence. Non-occurrence is not inferred, unverified consequences remain unresolved, and unsafe physical retries are prevented.],
  [F-08 — Retry identity], [Repeat the same logical effect request. No state change is duplicated. A repeat physical command is evaluated separately under its lifecycle contract rather than assumed safe.],
  [F-09 — Composition], [Exercise independent operations, an invalid atomic group, and an unmet ordered dependency. Independence does not bypass shared-state validation; atomic groups commit all or none; a dependent operation cannot proceed early.],
  [F-10 — Transaction boundaries], [Fail a later operation across an authority boundary. Earlier commitments remain valid, unresolved work is represented, and unsupported cross-boundary atomicity is not claimed.],
  [F-11 — Traceability], [Reconstruct an execution's Specification version, inputs, actors, transitions, checkpoint evidence, outputs, and effects without relying on its final status alone.],
  [F-12 — Specialization], [Review a proposed domain rule that relaxes a foundational guarantee. Reject the claimed conformance; domain constraints may strengthen but not weaken these obligations.],
)

== Generic Example: Uncertain External Execution

An instrument receives a command for one irreversible operating cycle. Communication times out before its physical outcome is established. The TaskSchema requires separate checkpoints for command acceptance, verified outcome, owning-domain commitment, and execution resolution.

The execution enters `AwaitingEvidence`. Command acceptance is retained as evidence, not proof of physical completion. No unverified success Effect is committed, no absence of acknowledgment is treated as proof of non-occurrence, and the physical command is not blindly repeated.

1. *Confirmed full outcome:* The owning domain validates and commits the evidenced Effect once. Completion still requires the contract's remaining checkpoints.
2. *Confirmed non-occurrence:* No physical-outcome Effect is committed; retry or failure follows the lifecycle's declared rules.
3. *Confirmed partial outcome:* Established consequences are recorded using the domain's permitted effect families. The intended cycle may fail without erasing those consequences.
4. *Unknown outcome:* Evidence is retained, dependent operations remain restricted as required, and resolution requires further evidence or authorized reconciliation rather than an invented outcome.

A duplicate confirmation must not duplicate a commitment. A later failure must not reverse established consequences implicitly. This case tests F-05 through F-10 without assuming a particular domain's entities or accounting rules.

== Validation Method

A complete executable case declares its initial state, versioned TaskSchema and lifecycle, dependency conditions, events and evidence, proposed and committed effects, expected state, applicable invariants, and invalid variations. Include concurrency, partial failure, uncertainty, and recovery alongside the success path.

These are conformance obligations and a worked semantic example, not a claim that executable implementations or tests already exist. Every implementation must supply evidence for the applicable obligations. Every domain specialization adds its own cases; passing those cases is not a substitute for foundational conformance.
