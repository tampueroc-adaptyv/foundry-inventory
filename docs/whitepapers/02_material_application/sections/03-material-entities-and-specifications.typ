= Material Entities and Specifications <material-entities>

These entities and versioned Specifications specialize the foundational primitives. Scientific identity and physical holding identity remain distinct.

== Material <material>

`Material` represents an identifiable scientific entity, such as a protein, reagent, sample, or preparation.

A Material has stable identity, scientific metadata, an applicable MaterialSpecification version, and optional composition and provenance relationships.

One Material may occupy multiple ContainerContents.

We do not initially impose a universal hierarchy of material definitions, lots, and samples.

== MaterialSpecification <material-specification>

`MaterialSpecification` specializes `Specification`.

It defines:

- Identity-defining scientific distinctions.
- Descriptive attributes.
- Validation requirements.
- Relevant provenance and production boundaries.

Two independently produced protein batches may require separate identities even if their measured attributes match.

An aliquot may preserve identity despite occupying a new physical container.

We define specification-relative identity:

$ m_1 equiv _( Sigma )m_2 $

For a proposed material output $o$:

$ op("IdentityDecision")( Sigma ,o)
arrow.r
{op("Reuse")(M),op("Create")(M')} $

Identity validation may require scientific evidence or authorized judgment.

Materials must satisfy their applicable MaterialSpecification's identity and validation rules. Specification changes do not silently rewrite existing identities. Amendments preserve prior scientific assertions, supporting evidence, and applicable specification versions.

== Container <container>

`Container` represents a physical object capable of holding material, other containers, or both.

Examples include vials, tubes, plate wells, plates, boxes, and racks.

These share one generalized Container abstraction, distinguished by specifications. Container identity remains stable through relocation and lifecycle changes. Retirement requires resolution of active contents and child placements; it does not erase their history.

== ContainerSpecification <container-specification>

A `ContainerSpecification` defines physical capabilities and constraints.

#table(
  columns: (1fr, 1fr, 1fr, 1fr),
  table.header([Example], [Direct material], [Child containers], [Placement behavior]),
  [Vial], [Yes], [No], [Movable],
  [Tube], [Yes], [No], [Movable],
  [Plate well], [Yes], [No], [Fixed to plate],
  [Plate], [No], [Yes], [Fixed well grid],
  [Box], [No], [Yes], [Movable container grid],
  [Rack], [No], [Yes], [Compatible slots],
)

Specifications may define occupancy, compatibility, positions, geometry, capacity, and lifecycle rules.

== Location <location>

`Location` represents a physical place or address, such as a laboratory, room, freezer, or shelf.

Locations are distinct from movable Containers.

Locations may be nested and may contain Containers. Each Location references a versioned LocationSpecification, with effective-dated bindings and placement history retained. The enclosing-location path must be unambiguous and acyclic.

=== LocationSpecification <location-specification>

`LocationSpecification` specializes `Specification` and defines a Location's declared operating envelope:

- `condition`: optional storage-condition declaration, including temperature and optional humidity ranges, with units.
- `containment_level`: declared biosafety or other containment classification, its applicable standard, and authorized scope.
- `capabilities`: supported process kinds, such as characterization.
- `capacity`: optional occupancy limits with an explicit measurement basis.
- `environmental`: additional applicable constraints, such as atmosphere, light exposure, or cleanliness.

Declarations describe requirements or qualified capabilities, not proof of actual conditions or current authorization. Applicable evidence and restrictions must establish their validity for the intended use. Scope and inheritance of containment and capabilities are explicit in the Specification; the nearest-storage-condition rule does not automatically propagate process authorization. Placement must respect applicable compatibility and capacity constraints.

Version changes follow the foundational applicability and reassessment rules; they do not silently reinterpret historical storage or authorize in-flight work. Condition excursions and relevant placement or Specification changes trigger reassessment where required by the governing material or task policy.

== ContainerContent <container-content>

`ContainerContent` represents scientific Material occupying a particular Container.

It connects:

- Material identity.
- Physical Container.
- Accountable quantity.
- Content-specific metadata and history.

The same Material may appear in multiple ContainerContents. Each holding has a stable identifier distinct from its Material and Container identities. Its bindings identify the holding being accounted for: ordinary transfers debit the source and credit a destination holding rather than retarget the source holding's identity. Relocating the enclosing Container preserves holding identity.

Within one direct material-holding Container, at most one active ContainerContent exists for each Material identity. Separate holdings of the same Material require distinct Containers, including child Containers where applicable. Additional receipts of the same Material credit the existing active holding while retaining distinct movement and provenance references; different receipt histories or labels alone do not create parallel balances.

A Container may hold multiple Materials where permitted by its ContainerSpecification, with each holding independently identifiable and accountable. Physically combining portions into one undifferentiated holding does not leave independently withdrawable component balances: same-Material additions share one holding, and preparations managed as one quantity follow the composite accounting rule (@composite-accounting).

ContainerContent is the ordinary quantity-tracking unit. Active content must reference a compatible, active Container. Closure requires zero recorded quantity and resolved physical outcomes. Zero quantity alone does not close a holding; closure is explicit under applicable lifecycle rules. Closed identifiers are not reused, and their movement history remains traceable.

A separate bulk or in-transit holding model is deferred until required.

== MaterialMovement

`MaterialMovement` records quantity changes associated with laboratory activity or correction.

Examples include receiving, transferring, consuming, producing, disposing, and reconciling material.

Current recorded quantities derive from committed movements.

Committed movements are immutable and corrected through additional linked movements.
