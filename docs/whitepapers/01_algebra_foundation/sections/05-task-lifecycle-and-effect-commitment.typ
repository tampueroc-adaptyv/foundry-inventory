= Task Lifecycle and Effect Commitment

Every TaskSchema defines how its executions progress, which conditions must be verified, and when effects may be proposed.

The mandatory lifecycle contract defined by TaskSchema is expanded below.

== States

`States` defines the possible execution states.

A standard lifecycle may include:

#table(
  columns: (1fr, 1fr),
  table.header([State], [Meaning]),
  [`Pending`], [Execution created but not started],
  [`Running`], [Execution underway],
  [`AwaitingEvidence`], [Execution outcome or required conditions cannot yet be established],
  [`Completed`], [Required completion conditions satisfied],
  [`Failed`], [Execution cannot complete as intended],
  [`Canceled`], [Execution stopped under an authorized cancellation process],
)

These are execution states, not authoritative domain outcomes: an external action may physically complete while its TaskExecution remains in `AwaitingEvidence`.

== Transitions

`Transitions` defines allowed changes between execution states and their conditions.

For example:

$ "Pending" arrow.r "Running" $

$ "Running" arrow.r
{"Completed","Failed","Canceled","AwaitingEvidence"} $

$ "AwaitingEvidence" arrow.r
{"Running","Completed","Failed","Canceled"} $

These are example transitions. Each TaskSchema defines or references its actual rules.

A cancellation request does not establish that an external instrument stopped.

An instrument's success response does not establish that required domain effects were committed.

== Checkpoints

`Checkpoints` defines logical verification boundaries during execution.

A checkpoint specifies what must be established before certain transitions or effect proposals are permitted.

Checkpoints may evaluate:

- Instrument results.
- Scientific observations.
- Required execution outputs.
- Domain and operational preconditions.
- Authorization assessments.
- Confirmation of domain effect commitments.

A checkpoint may be satisfied, unresolved, or failed.

Checkpoints are distinct from lifecycle states and need not occur in one fixed sequence.

An external action may be confirmed through an instrument result or authorized physical verification.

== CommitRules <commit-rules>

`CommitRules` defines when an execution may propose concrete effects from its TaskSchema's permitted families and which committed outcomes are required for completion.

For an individual proposed effect $delta$ and execution $E$:

$ op("MayPropose")( delta ,E,L) $

is true only when the effect's family belongs to $cal(F)$ and applicable lifecycle and checkpoint conditions hold.

Permission to propose an effect is not permission to commit it.

The authoritative domain independently validates the concrete proposal's payload, required evidence and authorization, and applicable invariants against current state:

$ op("CommitDomain")(S, delta )
arrow.r
cases(S' & "if valid", op("Error") & "otherwise") $

CommitRules distinguish required effects from optional effects.

Task completion requires satisfaction of its defined completion conditions, not acceptance of every possible optional effect.

== Execution and Effect Independence <effect-independence>

Task lifecycle and domain effect commitment are distinct.

A TaskExecution has its own lifecycle state.

Individual effects may be pending validation, committed, rejected, or unresolved.

In particular:

$ op("Status")(E)="Failed"
⇏
Delta _("committed")(E)= emptyset $

Failure, cancellation, or uncertainty does not automatically reverse committed effects.

Nor does it establish that no physical activity occurred.

Task completion cannot substitute for required domain effect commitments.

== Interrupted and Uncertain Execution <uncertainty>

An external operation may physically occur without definitive system confirmation.

When its outcome is uncertain:

1. Known events and observations are retained.
2. The unresolved execution state is represented explicitly.
3. Unverified physical outcomes are not committed as confirmed facts.
4. Non-occurrence is not assumed from missing acknowledgment.
5. Unsafe repetition of physical commands is prevented.
6. Resolution occurs through further evidence, authorized observation, or reconciliation.

Confirmed partial physical activity must be represented even if the overall task fails.

Unresolved outcomes may require restrictions on dependent operations until an acceptable authoritative state is established.

== Retries and Idempotency <retries>

Software retries and physical retries have different semantics.

Repeated commitment requests for the same logical effect must not duplicate state changes.

Repeating an instrument command may perform an additional physical action.

Idempotent effect commitment does not imply idempotent physical execution.

A physical command may be retried only when its lifecycle contract permits it based on known conditions, or when explicitly authorized as a distinct action.

== Execution Invariants <execution-invariants>

#table(
  columns: (1fr, 1fr),
  table.header([Invariant], [Requirement]),
  [Lifecycle conformance], [Execution transitions follow the versioned TaskSchema lifecycle],
  [Checkpoint validation], [Checkpoints are satisfied only when required conditions are established],
  [Effect permission], [Effects are proposed only when allowed by CommitRules],
  [Domain authority], [Owning domains validate and commit authoritative effects],
  [Completion integrity], [Required checkpoints and effects are resolved before completion],
  [Failure integrity], [Failure does not implicitly reverse committed effects],
  [Retry safety], [Uncertain physical actions are not blindly repeated],
  [Traceability], [Execution transitions, checkpoint results, and effects remain auditable],
)
