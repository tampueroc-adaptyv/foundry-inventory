= Operation Composition and Transaction Boundaries

Operations may be composed to express independence, atomic effect commitment, and ordered dependencies.

The algebra provides three conceptual operators.

#table(
  columns: (1fr, 1fr),
  table.header([Operator], [Semantics]),
  [$O_1 plus.o O_2$], [Independent composition],
  [$O_1 times.o O_2$], [Atomic effect commitment],
  [$O_1 arrow.r O_2$], [Ordered dependency],
)

*These operators express semantic guarantees*, subject to the architectural principle in @architecture.

== Independent Composition

$ O_1 plus.o O_2 $

The operations have no declared ordering or atomicity dependency.

Either may succeed or fail independently.

Independence does not guarantee conflict-free concurrent execution when operations affect shared state.

All domain invariants remain applicable.

== Atomic Composition <atomic-composition>

$ O_1 times.o O_2 $

Atomic composition selects explicit state-effect batches $Delta_1$ and $Delta_2$ proposed by $O_1$ and $O_2$ for joint validation and commitment within one supported transaction boundary. The notation does not make arbitrary operations atomically composable.

$ op("Commit")(Delta_1,Delta_2)=
cases(op("CommitBoth") & "if valid", op("CommitNeither") & "otherwise") $

`CommitBoth` and `CommitNeither` refer only to the selected effect batches, not to complete operation lifecycles or unselected effects.

For example:

$ op("CreateEntity")(e)
times.o
op("LinkEntity")(e,r) $

Here the relationship references the Entity created in the same effect group. The owning domain may commit creation and relationship establishment together.

An atomic group is valid only where the participating state changes are covered by a supported transaction boundary.

Atomic effect commitment does not imply atomic physical execution.

== Ordered Composition <ordered-composition>

$ O_1 arrow.r O_2 $

The second operation depends on a defined completion condition of the first.

The condition may be:

- A committed domain effect.
- A satisfied execution checkpoint.
- A completed TaskExecution.
- Another explicitly defined dependency condition.

Ordered composition does not imply atomicity or automatic rollback.

For example:

$ op("AuthorizeResult")(R)
arrow.r
op("PublishResult")(R) $

Publication depends on the result's committed authorization.

If authorization is committed but publication fails, authorization remains committed while delivery requires resolution.

The coordinating task or workflow records the incomplete sequence and manages resolution.

== Composition Across Transaction Boundaries <cross-domain>

Operations may declare atomic effect groups and inter-operation dependencies.

Atomic groups are committed within a supported domain transaction boundary.

Dependencies spanning transaction boundaries are coordinated through TaskExecution or WorkflowExecution, with explicit completion, failure, and unresolved outcomes.

Execution/effect independence (@effect-independence) and uncertainty rules (@uncertainty) apply across these boundaries.

== Composition Invariants <composition-invariants>

1. Independent composition does not imply transactional coupling.
2. Atomic effect groups commit entirely or not at all within their supported transaction boundary.
3. Ordered dependencies must be satisfied before dependent operations proceed.
4. Ordered composition does not imply automatic rollback.
5. No composition operator makes physical laboratory actions reversible.
6. Failed or uncertain compositions retain confirmed effects and explicitly represent unresolved consequences.
7. Repeated execution and commitment requests remain subject to idempotency and retry rules.

The operators are notation for these guarantees, not additional primitives.
