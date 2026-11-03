= Task and Workflow Algebra <task-workflow>

== TaskSchema

A `TaskSchema` is a versioned contract describing an operation.

$ op("TaskSchema")=(I,O,R,cal(F),L) $

Where:

- $I$: Typed input ports, including domain entities, data, and references.
- $O$: Typed output ports, including domain entities, data, and decisions.
- $R$: Resource requirements and preconditions.
- $cal(F)$: Permitted effect families, not individual proposed effects $delta$ or proposed batches $Delta$.
- $L$: Mandatory lifecycle and effect-commitment contract.

Every TaskSchema defines $L$, directly or by referencing a versioned standard lifecycle specification.

$ L=("States","Transitions","Checkpoints","CommitRules") $

Tasks may require domain entities, people, instruments, or external capabilities.

Typed ports may reference domain Specifications to define acceptable inputs and expected output identities.

TaskSchemas declare resource requirements without implementing scheduling or reservations.

Tasks are not fundamentally classified as physical, virtual, manual, or automated.

== TaskExecution

A `TaskExecution` represents one invocation of a TaskSchema.

It records:

- TaskSchema identity and version, applicable Specification bindings, and any reassessment or rebinding history.
- Actual input bindings.
- Actors and external execution references.
- Current lifecycle state and transition history.
- Checkpoint evaluations and supporting evidence.
- Execution events.
- Actual outputs.
- Proposed and committed effect references.
- Failure, interruption, cancellation, and recovery history.

*A task defines an operation. Its execution records what happened. Its effects describe what changed.*

The execution/effect independence principle (@effect-independence) governs the interpretation of its lifecycle status and physical consequences.

== Workflows

A `WorkflowSchema` composes tasks through dependencies and typed input/output connections.

For example:

$ op("AcquireData")
arrow.r
op("ReviewResults")
arrow.r
op("PublishResults") $

A `WorkflowExecution` represents an actual execution of that graph.

Tasks may execute independently of workflows.

The planned workflow remains distinct from its execution history, allowing retries, deviations, and failures.

Workflow dependencies may require task completion, a committed domain effect, or another explicitly defined condition.

Resource feasibility and scheduling may be delegated to external capabilities.
