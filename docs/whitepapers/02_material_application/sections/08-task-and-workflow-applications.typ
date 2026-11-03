= Task and Workflow Applications <material-applications>

Laboratory operations instantiate the TaskSchema, TaskExecution, and WorkflowExecution semantics of #link("../01_algebra_foundation/algebra.pdf")[Foundations, Section IV]. An operation name in @material-operations denotes a domain operation, not automatically a complete TaskSchema or instrument command.

Each concrete TaskSchema pins its versioned input/output contracts, resource requirements, allowed effect families, lifecycle, checkpoints, and CommitRules. The following application contracts identify the required distinctions; they do not replace method-specific scientific or authorization rules.

== Material Transfer

A transfer schema binds a source ContainerContent, destination holding or compatible Container, Material identity, requested quantity with units, and actor or instrument reference. Preconditions include compatible identity and containment, valid quantity, applicable use restrictions, and authority.

Outcome verification establishes the actual transfer, not merely command acceptance. Required checkpoints distinguish physical confirmation from movement commitment and execution resolution. CommitRules permit only evidenced movements; a newly required ContainerContent and the associated transfer postings may form one supported atomic effect group.

Confirmed partial transfer is represented even if the requested transfer fails. A timeout enters an explicit unresolved state. Required movement commitments precede completion; an idempotent commitment request does not make a physical retry safe. Cases 1, 2, and 9 in @material-cases exercise these obligations.

== Composite Preparation

A preparation schema binds input holdings and quantities, an output MaterialSpecification and compatible Container, method and resource references, and required scientific evidence. Its permitted families include consumption, output production, derivation, and composition.

Checkpoints establish actual input consumption, the output's scientific identity and quantity, and required provenance and contribution assertions. CommitRules distinguish confirmed consumed inputs from output quantities that have not yet been established. The composite accounting rule (@composite-accounting) prevents duplicate constituent inventory.

The schema defines which effects are required for completion. Confirmed consumption survives later failure; neither atomic recorded effects nor workflow failure can restore physically consumed inputs. Cases 3 and 8 test these semantics.

== Material Quality Review

A review schema binds a Material or ContainerContent, applicable policy version, intended decision scope, reviewer authority, and supporting observations. Outputs include the scoped decision and its evidence references.

A decision-authority checkpoint precedes proposal, and the designated domain commits the decision before required completion. This changes decision state, not quantity or placement. Eligibility is then assessed for the intended use and time under @eligibility; an unresolved assessment is not approval. Case 6 tests this separation.

== Composition Applications <material-composition>

Content creation and quantity transfer may be composed atomically within a supported Material-domain transaction boundary:

$ op("PlaceContent")(M,V)
times.o
op("TransferMaterial")(C_("source"),C_("new"),q) $

Here the transfer references the content created in the same effect group. The Material domain may commit content creation and its transfer postings together.

This is atomic recorded commitment under #link("../01_algebra_foundation/algebra.pdf")[Foundations, Section VI.B], not atomic physical execution. The transfer references the content created in the same group.

Disposal followed by retirement is an ordered dependency under #link("../01_algebra_foundation/algebra.pdf")[Foundations, Section VI.C]. Retirement requires disposal to be accounted for and all other retirement preconditions to hold. If retirement fails after disposal is committed, disposal remains authoritative; case 10 tests both this sequence and the supported atomic alternative.

Dependencies spanning authorities or transaction boundaries are coordinated through task or workflow execution as required by #link("../01_algebra_foundation/algebra.pdf")[Foundations, Section VI.D], without assuming rollback of physical consequences.

== Workflow Admission and Active Intervention <workflow-intervention>

A workflow requiring material eligibility defines an admission contract and applicable continuation checkpoints through its versioned TaskSchemas.

A TaskSchema may require execution in a specified Location, such as the characterization cell, with a declared process capability and containment level. Admission and continuation checkpoints validate the actual execution location, applicable LocationSpecification version, required evidence, and current restrictions. A location name or capability declaration alone does not satisfy the precondition; relocation or relevant changes require validation at the applicable authorization boundary.

Admission binds the intended material inputs, their eligible use scopes, supporting scientific assertions and decisions, and applicable Specification versions. The coordinating workflow authority may establish exclusive allocation or custody under a separate operational contract. Admission and allocation do not imply that material has been physically consumed.

During execution, the workflow evaluates newly applicable restrictions and evidence changes at the intervention boundaries required by its TaskSchemas. An affected operation may begin only when the applicable continuation conditions are satisfied or an appropriately authorized operator has resolved the intervention.

Operator intervention records its scope, evidence, authority, decision, and relationship to the affected TaskExecution. Permitted outcomes may include continuation, additional verification, rework, quarantine, or termination. No operator decision overrides a non-waivable Specification requirement.

An operation already in physical execution may complete, partially complete, or remain unresolved. Its confirmed effects remain authoritative and are not automatically reversed. Required intervention prevents subsequent affected operations from being newly authorized; it does not assume instantaneous cancellation of physical actions.

The workflow must preserve the provenance of admission, interventions, physical outcomes, and resulting decisions. Allocation, instrument control, and notification mechanisms remain outside the material domain except through their defined contracts.
