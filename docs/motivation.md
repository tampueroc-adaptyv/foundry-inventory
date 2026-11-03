# Engineering Approach & Design Rationale

*Inventory management for a high-throughput protein characterization laboratory*

## 1. Approach

I approached this assignment by combining experience from logistics and semiconductor manufacturing with research into wet-lab operations and the specific requirements of the binding characterization workflow.

My starting point was not a particular database schema or architectural pattern. It was a set of operational questions informed by systems I had previously worked with:

- How do we maintain trustworthy inventory quantities when physical operations can fail or be retried?
- How do we distinguish intended work from what actually happened?
- How do we accommodate operational exceptions and retrospective corrections without losing history?
- How do we preserve evidence when large instrument datasets can be interpreted in different ways?
- How do we support evolving procedures without continually redesigning the database?

These questions guided the initial design. The assignment's scientific and physical inventory requirements determined the resulting domain model.

## 2. Experience that informed the design

### Inventory correctness from logistics

My experience in warehousing, fulfillment and last-mile operations gave me a baseline for inventory accounting and transactional correctness.

I was already familiar with the importance of separating inventory movements from balances, handling duplicate operations, preserving auditability and distinguishing system records from physical reality.

This influenced the decision to use an immutable double-entry ledger, with `MaterialMovement` and `MaterialPosting` as authoritative records and `MaterialBalance` as a transactionally maintained, rebuildable projection.

I had also experienced the limitations of operational software firsthand. In one warehouse system, querying inventory by lot and expiration date became problematic, leading us to use a workaround involving sink accounts.

That experience reinforced the importance of accommodating operational exceptions and evolving information requirements. It also highlighted the need to distinguish flexibility in accounting operations from flexibility in accounting correctness.

In this design, new counterpart-account types, governed adjustments and read projections can be introduced without allowing operators to arbitrarily edit quantities or rewrite historical postings.

The accounting invariants remain fixed even when operational needs change.

### Fault-tolerant experiments from semiconductor testing

At a fabless semiconductor company, I worked with an internal laboratory used to test sub-lots.

This gave me direct exposure to experimental workflows, instrument execution failures, fault-tolerant result tracking and the practical difference between a defined procedure and its actual execution.

Operational exceptions were normal. Test engineers sometimes performed R&D workflows outside established production procedures, repeated measurements or discovered that an earlier operational record required correction.

I learned that a system needs to preserve what was intended, what was attempted, what was observed and what was subsequently corrected.

I also encountered instruments producing large measurement datasets that could be postprocessed in multiple ways.

The raw measurement might remain unchanged while different analysis methods produced different results. A failed analysis did not necessarily require the instrument measurement to be repeated.

These experiences directly informed the separation between `Task`, `TaskExecution`, `TaskExecutionOutput`, `Observation` and `Assessment`.

## 3. Developing a wet-lab mental model

Although I had worked with physical inventory and manufacturing operations, I did not assume their identity models would transfer directly to a protein characterization laboratory.

I read Adaptyv's parSEQ technical report to better understand the context of high-throughput biological workflows and the importance of relating biological identity to experimental results.

I also explored Benchling to develop a mental model of how scientific entities and their relationships might be represented in wet-lab software.

That research was particularly useful for thinking about the distinction between biological identity, preparation identity, samples, containers and accountable physical holdings.

It helped establish a foundational modeling decision:

**A scientific Material, a physical Container and the inventory held within that Container are different identities.**

For example, aliquoting a protein preparation into multiple wells does not necessarily create multiple new scientific preparations. Conversely, a scientifically meaningful transformation may produce a new Material identity even when the physical container is unchanged.

The system must preserve these distinctions because both inventory accounting and scientific provenance depend on them.

The binding workflow supplied with the assignment then provided concrete operations against which to test the model.

## 4. Deriving the specification-driven architecture

The laboratory performs heterogeneous operations: receiving materials, reconstituting DNA, diluting samples, expressing proteins, transferring quantities between wells, acquiring measurements and interpreting experimental results.

These operations differ substantially in their scientific meaning and physical consequences.

However, they share a recurring operational structure:

**Declared inputs → intended work → actual execution → accepted outcomes → validated consequences.**

I chose to represent this shared structure through versioned specifications and execution records.

A `TaskSpecification` describes an operation's permitted inputs, outputs, lifecycle conditions and effects. A `Task` binds the intended operation to concrete resources and dependencies. `TaskExecution` records attempts, while immutable `TaskExecutionOutput` manifests preserve accepted outcomes, including partial success, failure and uncertainty.

I represent workflows internally as composite Tasks governed by composite TaskSpecifications, while `Workflow` and `WorkflowSpecification` remain first-class concepts at the API layer. This reuses identity, execution, immutable output, dependency and provenance machinery rather than creating a parallel workflow persistence model. Workflow-specific validation and queries become more involved, which I accept initially; specialized views, projections or persistence can follow when demonstrated workloads justify them.

An operator or external system can initiate a workflow, while an external scheduler initiates individual `TaskExecution` attempts. Dependencies are represented through governed Task inputs and accepted upstream outputs; this is a foundation for bounded workflows, not an implemented general-purpose orchestration engine.

An execution completing successfully does not automatically mean its Task is scientifically complete, and a failed execution does not invalidate physical effects that actually occurred.

I also distinguish Task identity, retry identity and semantic Effect identity. Two Tasks with identical specifications and inputs may be intentional experimental replicates. Conversely, accepting the same supplier delivery or authorizing the same physical consequence twice may be invalid even across different Tasks or workflows. Deduplicating API retries is not the same as preventing duplicate real-world Effects.

My architectural choice is for the governing TaskSpecification to declare the semantic uniqueness policy and its scope: Task-local, Workflow-local, Workcell-local, Site-local or Tenant-global. The scope together with the semantic consequence identity determines which operations conflict at Effect acceptance, protecting inventory correctness without suppressing legitimate replicates. This is the intended contract, not a claim that every scope is already implemented and tested.

### Separating evidence from interpretation

Scientific evidence introduces another important distinction.

An instrument may produce a single large dataset containing measurements for an entire plate. That dataset can support many independently meaningful scientific conclusions.

I therefore separated `Observation` from `Assessment`.

An Observation identifies accepted measurement evidence, including its acquisition context, immutable artifact and exact dataset-member relationships.

An Assessment represents an interpretation under a particular versioned scientific contract.

The same Observation may support multiple Assessments, including interpretations produced later using different methods.

This avoids duplicating raw measurements or rewriting previous conclusions when scientific understanding changes.

## 5. Why PostgreSQL and governed JSONB?

Having used both relational and non-relational databases, I was conscious of the tension between stable schemas and organically evolving operational requirements.

Laboratory procedures can change as instruments, scientific methods and operational practices evolve. Modeling every possible procedure-specific field as a dedicated relational structure risks frequent migrations and increasingly awkward abstractions.

At the same time, inventory accounting, identity, provenance and concurrent authorization require strong transactional guarantees.

I therefore chose a hybrid approach.

**The relational model protects stable identities and invariants. Governed JSONB accommodates variability in operational and scientific contracts.**

Immutable specification versions define the required structure and semantics of JSONB payloads, including input/output roles, cardinalities and permitted dependencies.

Trusted PostgreSQL handlers validate these contracts and enforce their consequences.

During SQL reconciliation, I found that required JSONB values could sometimes bypass validation because PostgreSQL comparisons involving NULL return UNKNOWN rather than TRUE or FALSE. This mattered particularly for scientific approval transitions and physical command protocols. The lesson was to make trusted acceptance handlers positively establish required preconditions: missing, null, malformed or ambiguous values cannot count as satisfying a contract.

The specifications are not arbitrary executable programs, and JSONB is not a replacement for referential integrity. Correctness-critical relationships are indexed and validated through relational structures.

This approach lets operation-specific contracts evolve without requiring every new procedure to become a new family of tables.

I also went with UUIDv7 for generated IDs. From previous experience, roughly time-ordered identifiers have come in clutch when debugging distributed workflows and correlating records across different components of a system. It's a small implementation choice, but one I've learned to appreciate. PostgreSQL 18 now supports UUIDv7 natively, so there was little reason not to use it. For related informal reading, there's also this [Hacker News discussion](https://news.ycombinator.com/item?id=50211746).

### Acknowledging polymorphism's cost

I recognize that using a common Task model for heterogeneous operations introduces trade-offs.

Receiving, high-volume plate transfers, instrument acquisition, scientific analysis and workflow coordination have different read/write patterns.

A shared model may introduce validation overhead, write amplification, polymorphic indexes and more complex queries.

I consider that an acceptable initial trade-off within the assignment's scope, not a permanent architectural commitment.

Once real workload data is available, particularly throughput, contention, query latency and execution cardinality, high-pressure operations can be specialized.

For example, plate transfers might require optimized settlement paths, while scientific analysis may benefit from dedicated indexes or projections.

The common contracts and historical provenance can remain stable even if their internal implementations evolve.

The initial shared advisory-lock strategy is another explicit correctness-versus-concurrency trade-off. It simplifies the first implementation but should be revisited if measured contention becomes significant.

**My intention is to establish reliable shared semantics first and specialize based on operational evidence, rather than anticipate every future bottleneck.**

## 6. Corrections as ordinary, governed operations

The assignment explicitly mentions failed QC, incorrect records, reruns and tracing downstream materials affected by problematic batches.

I wanted corrections to be part of the operational model rather than exceptional database maintenance.

A new measurement Task can acquire additional evidence. A subsequent interpretation Task can produce a new Assessment that confirms, revises or explicitly supersedes an earlier conclusion.

The original evidence and interpretation remain immutable.

Likewise, inventory corrections use attributable compensating or replacement postings rather than modifying historical ledger entries.

Scientific corrections and inventory corrections are related but distinct.

A corrected scientific Assessment may affect whether downstream material is currently usable without changing the fact that a historical physical transfer occurred.

This distinction supports both trustworthy auditing and practical recovery from operational mistakes.

## 7. Workcell, site and tenant boundaries

I also considered three scopes from the beginning because they have different operational and strategic implications.

### Workcell: operational capacity

From my manufacturing experience and wet-lab research, I see the workcell as a useful abstraction for grouping Tasks, operators, instruments and accessible physical resources.

It provides an execution and authorization boundary, but it may also become a natural unit for analyzing operational performance.

Execution histories could eventually help answer questions about throughput, instrument utilization, failure rates and capacity bottlenecks.

Those metrics would support decisions about staffing, instrumentation and expansion.

The initial design needs only a clear workcell identity and scope. Reliable capacity optimization requires additional measurements and operational evidence.

### Site: distributed laboratory operations

The business context also informed my interest in multi-site support, including the London laboratory expansion.

If protein characterization is delivered as a service, customers should not necessarily need to understand which physical laboratory performs their experiment.

This suggests separating customer-facing experimental intent from the site and workcell responsible for execution.

Making site identity explicit from the beginning helps preserve physical custody boundaries and allows future operational assignment across facilities.

However, cross-site inventory movement, logistics, custody transfer and scheduling remain separate capabilities rather than consequences of simply adding a site identifier.

### Tenant: a potential software product boundary

Multi-tenancy reflects a longer-term product possibility informed by my experience building operational systems.

Software developed to coordinate high-throughput physical operations can become valuable independently of the physical service itself.

The management and information layer might eventually be offered as a separate SaaS product, allowing other organizations to benefit from the operational knowledge embedded in the platform.

This is a strategic possibility, not a claim about Adaptyv's current plans.

I therefore consider tenant ownership worth distinguishing from physical site and workcell boundaries.

A tenant represents an organizational and security boundary, while a site represents physical custody and a workcell represents operational execution capacity.

Basic scoping can be modeled early. Full multi-tenant security, cross-organization collaboration and distributed operations require additional implementation and verification.

## 8. Deliberate boundaries and alternatives

I did not aim to recreate a complete LIMS, ELN, manufacturing execution system or workflow orchestration platform.

The intended scope is an inventory foundation that can reliably account for physical materials and preserve their operational and scientific provenance.

I considered two broad alternatives to the shared specification-driven design.

**Dedicated structures for every operation** would be simpler for individual cases, but risk duplicating execution, acceptance, correction and provenance mechanisms.

**A fully generic workflow or rules engine** would provide more configurability, but introduce substantial complexity beyond the requirements and weaken the clarity of the correctness boundary.

I chose versioned, declarative specifications backed by explicit trusted handlers as a middle ground.

The design retains important limitations: not every operation is implemented, arbitrary workflow replanning is excluded, and future operational scale may justify more specialized persistence or execution paths.

The ADRs document these choices, their alternatives and their trade-offs. They are explanations of design intent, not proof that the implementation satisfies every invariant.

That evidence must come from SQL constraints, transactional handlers, integration tests and demonstrated failure recovery.

## 9. Engineering objective

The design reflects three complementary influences.

My logistics experience taught me to treat physical inventory as an accounting and reconciliation problem.

My semiconductor laboratory experience taught me to distinguish operational intent, execution, experimental evidence and scientific interpretation—especially when instruments fail or results are reprocessed.

My research into Adaptyv and wet-lab software helped me adapt those lessons to biological identity, sample preparation and scientific provenance.

My database experience informed the choice to combine a strongly relational correctness core with versioned, flexible operational contracts.

The result is a deliberately bounded specification-driven architecture: **rigid where correctness is essential, flexible where laboratory procedures evolve, and capable of incremental specialization when real operational evidence justifies it.**

The goal is not maximum abstraction. It is to make physical inventory, experimental history and scientific conclusions trustworthy while allowing the laboratory's operations to change.
