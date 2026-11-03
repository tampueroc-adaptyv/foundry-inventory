= Material Domain State <material-state>

The material domain specializes #link("../01_algebra_foundation/algebra.pdf")[Foundations, Section III.B] into three connected representations:

$ S_M=(P,C,Q) $

Here $P$ is scientific identity, composition, and provenance; $C$ is physical containment and locations; $Q$ is recorded quantities and movement history. For the material-focused examples:

$ S=(S_M,D,T) $

$D$ contains recorded decisions, restrictions, and authorizations; $T$ retains the task and workflow definitions, executions, and history defined in #link("../01_algebra_foundation/algebra.pdf")[Foundations, Section IV]. Here $S=(S_M,D,T)$ denotes a material-focused projection of the foundational state $((S_k)_(k in K),T)$: it retains relevant material and decision components together with execution state and omits unrelated domain components. It is not an alternative general state model or an exhaustive platform model. A quality decision may change $D$ without changing $S_M$; an observation may refine $P$ without moving material; an execution transition may change $T$ without changing quantities.

== Scientific Identity, Composition, and Provenance

Requirements for $P$ are realized by Material and MaterialSpecification (@material–@material-specification), provenance (@provenance), and composition (@scientific-composition). Identity may survive division between containers, while transformation or independent production may require a new identity. Matching attributes alone do not decide identity. Component contributions must not duplicate available inventory (@composite-accounting).

== Physical Containment

Requirements for $C$ are realized by Container, ContainerSpecification, Location, LocationSpecification, Placement, and ContainerContent (@container–@container-content). Specifications distinguish direct material holdings, child containers, fixed positions, and movable contents. Placement and occupancy constraints apply independently of scientific identity.

== Material Quantities and Movements

Requirements for $Q$ are realized by MaterialMovement and the movement algebra. Quantity changes must be balanced within compatible scopes, traceable, and auditable (@movement-invariants). Double-entry principles provide internal correctness without requiring financial terminology in laboratory-facing operations.

== Operational Eligibility <eligibility>

Eligibility is derived for a particular intended use rather than stored as an intrinsic property of Material.

$ op("Eligible")(m,u,t,S,Sigma) arrow.r {"Yes","No","Unknown"} $

Where:

- $m$: Material or ContainerContent.
- $u$: Intended use.
- $t$: Assessment time.
- $S$: Relevant operational state.
- $Sigma$: Applicable specifications and policies.

Eligibility may depend on quality decisions, observations, material specifications, quantities, containment, methods, and policy. `Unknown` is not approval. A TaskExecution requiring eligible material validates that condition at the appropriate lifecycle boundary; stale approval cannot bypass commitment-time validation.

Location requirements are checked against the holding's current placement and applicable LocationSpecification versions (@location-specification). For a use requiring BSL-2 containment, known placement outside an authorized BSL-2 scope makes `Eligible` return `No`; missing placement or required containment evidence yields `Unknown`, not approval. This is a use-specific policy requirement, not a universal rule for all living cells.

*Workflow-Scoped Material Eligibility.* Material eligibility is evaluated in two operational contexts, not as two independent eligibility states. Both use the existing `Eligible(m,u,t,S,Σ)` assessment; the workflow contract governs when it is checked and how changes are handled.

*Pre-flight eligibility* determines whether specified material holdings may be admitted to a workflow for its intended operations. The admission contract validates applicable quantity, quality, stability, containment, scientific evidence, and restrictions, and retains the material identities, governing Specification versions, and evidence or decision references supporting authorization.

*In-flight continuation authorization* determines whether an admitted workflow may initiate a subsequent operation. The applicable TaskSchema defines its required checkpoints, relevant condition changes, and intervention rules. Pre-flight authorization does not unconditionally authorize all future operations.

Workflow admission may establish material allocation or custody through the responsible workflow authority. Such allocation is distinct from physical consumption and does not itself create a MaterialMovement. Material availability and eligibility remain governed by their respective authoritative states.

Eligibility governs authorization for use, not the existence or recorded quantity of material. Available quantity is derived for a holding, intended use, and assessment time from recorded inventory, eligibility, and applicable restrictions; it is not a second independent balance (@quantity-state).

=== Stability and Provenance-Dependent Expiration <expiration-assessment>

Expiration is a stability assessment, not necessarily an intrinsic, fixed Material property. Applicable MaterialSpecifications and validated evidence may distinguish source stability, transformations, preparation or opening time, holding-specific handling, storage conditions, and intended use. Aliquoting may preserve or shorten a limit; dilution, mixing, or transformation may require a distinct assessment. These are policy-dependent possibilities, not universal scientific rules.

$ &op("ExpirationAssessment")(m,c,u,t,S,Sigma) \
&arrow.r {"Valid","Expired","Unknown"} $

Here $m$ is Material, $c$ is its ContainerContent, $u$ is intended use, $t$ is assessment time, $S$ includes provenance and operational history, and $Sigma$ supplies the applicable Specification and policy versions. `Valid` means the applicable stability criteria are satisfied; `Expired` means a stability limit has been exceeded; `Unknown` means required information cannot establish the outcome.

For uses requiring stability approval of $c$, `Expired` makes that holding ineligible and `Unknown` precludes approval. A holding-specific result does not automatically classify other holdings of the same Material. `Valid` satisfies only the stability condition, not other eligibility requirements. Time alone can change the derived assessment without a state write. Assessment, expiration, or restriction does not consume or dispose of material and does not change recorded quantity.

The declared storage condition is taken from the nearest enclosing Location that declares one, following the holding's Container and Location placement chain; assessment over time uses effective-dated placement and LocationSpecification bindings plus required condition evidence, not merely the current location or its nominal temperature. Missing required history or evidence yields `Unknown`; the governing stability policy defines clock start, qualifying temperature ranges, excursions, and any reset rules.

An accepted expiration assertion records its cutoff or stability criteria, Material/holding and use scope, applicable versions, source assertions, method and condition evidence, authority, and effective history. Assignment or amendment is a domain-validated scientific or decision Effect; prior assertions remain traceable rather than being overwritten.

Policies declare whether source validity matters at preparation, at later use, or both, and which provenance dependencies or condition changes require reassessment. Required unresolved reassessment cannot silently preserve approval; applicable restrictions govern use pending resolution. Reassessment may retain or revise a limit, but provenance alone neither copies dates to all descendants nor universally resets a stability period. @expiration-case exercises these distinctions.
