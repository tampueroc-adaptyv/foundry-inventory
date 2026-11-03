= State and Authority <state-authority>

Let $S$ represent the logical state of the system.

Use distinct notation for permissions and proposals:

- $cal(F)$: The set of permitted effect families; each family defines a kind of change and its payload contract.
- $delta$: An individual proposed effect, with its logical identity, family, affected state, concrete change, and origin and evidence references required by the domain contract.
- $Delta$: A proposed batch of concrete effects.

An effect family is not itself a proposed state change. A proposed effect becomes committed only after authoritative validation and acceptance; proposing it does not by itself apply the described change.

An operation proposes an effect batch $Delta$:

$ op("apply")(S, Delta )
arrow.r
cases(S' & "if valid", op("Error") & "otherwise") $

Let $cal(I)$ represent the system's invariants.

For every accepted transition:

$ cal(I)(S)
and
op("Valid")(S, Delta )
arrow.r.double
cal(I)(S') $

An operation may change system state only when the relevant domain invariants remain satisfied.

The domain responsible for the affected state validates and commits its effects. Validation must apply to the authoritative state against which commitment occurs; concurrent changes must not allow an invalid transition merely because an earlier check succeeded.

This state model follows the architectural principle in @architecture.

== Historical and Observed State

We distinguish three concepts:

#table(
  columns: (1fr, 1fr),
  table.header([Concept], [Meaning]),
  [Recorded history], [The immutable record of what the system previously recorded],
  [Authoritative state], [The current system representation after valid domain transitions and corrections],
  [Observed physical state], [Measurements or observations about the actual laboratory],
)

These may disagree.

A correction changes the authoritative representation without rewriting recorded history.

A physical observation provides evidence about reality but does not automatically change authoritative domain state.

References connect observations, corrections, and affected domain records.

== Domain State and Authority <domain-state>

For modeled domains indexed by $k$ in $K$, let $S_k$ denote each domain's authoritative state and let $T$ denote task and workflow definitions, executions, and history. A logical view is:

$ S=((S_k)_(k in K),T) $

Each state component has a declared authoritative owner and applicable invariants. The notation does not imply one physical store, disjoint records, or a globally atomic snapshot.

An operation identifies its proposed effects, affected state, validating authority, and required evidence. Task and workflow coordination depend on the owning domain's commitment, not on a local assumption of success. Dependencies outside one supported transaction boundary follow @cross-domain.

Instrument, decision, and result state are possible specializations. Their domain-specific structures do not redefine the general algebra.
