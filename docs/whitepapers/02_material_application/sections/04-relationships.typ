= Relationships <material-relationships>

Placement, provenance, composition, and decisions connect the entities without conflating physical location, scientific identity, and available quantity. Scientific identity boundaries follow @material-specification; movement alone does not establish a new Material identity.

== Placement and Position <placement>

Placement is represented by:

$ op("PlacedIn")("Child","Parent","Position") $

Position is an attribute of the relationship, not a mandatory independent Entity.

Examples:

$ op("PlacedIn")("Well"_1,"Plate"_1,"A1") $

$ op("PlacedIn")("Vial"_1,"Box"_1,"B3") $

Placement must satisfy compatibility, fixed-position, exclusivity, and acyclicity constraints. No child may have conflicting active physical positions; containment must not form cycles. A fixed well retains its specified parent plate and position.

== Scientific Provenance <provenance>

Provenance uses typed relationships between Materials and generating executions. Each derived Material retains its source Material and generating execution references.

For example:

$ op("DerivedFrom")(M_2,M_1,E) $

Aliquoting may preserve scientific identity.

Digestion may establish a distinct derived Material.

Physical movement history remains traceable even when identity is unchanged.

Scientific dependencies may connect specific versioned assertions and decisions, not only Material identities. Where a downstream assertion or authorization depends on source composition, concentration, identity, stability, or other scientific knowledge, the governing Specification defines which source changes require reassessment. These dependencies preserve their source versions and evidence references.

== Scientific Composition <scientific-composition>

For composite Material $M_C$:

$ op("Composition")(M_C)
=
{(M_i,r_i)}_(i=1)^(n) $

Where $r_i$ expresses a scientifically defined contribution with an explicit measurement basis.

Composition may describe constituent identities, proportions, concentrations, or other meaningful quantities. Constituent identities, contribution values, and their measurement basis remain traceable.

It does not itself create independently available inventory balances.

$ op("Composition")(M_C)
⇏
Q(C_C,M_i)=r_i Q(C_C) $

== Composite Material Accounting Rule <composite-accounting>

When an operation creates a combined preparation managed as one accountable quantity:

1. Input quantities are accounted for by committed movements.
2. The output Material identity is established under its MaterialSpecification.
3. The output occupies one or more ContainerContents.
4. Component contributions are recorded as scientific composition or provenance.
5. Those contributions do not create duplicate available inventory balances.
6. Output quantity is established using appropriate measurement and evidence.

The output quantity is not universally required to equal the sum of the input quantities.

== Quality Decisions and Restrictions <decisions>

Quality decisions are distinct from physical material state.

They may apply to Materials, ContainerContents, groups, scientific results, or deliverables.

Decisions retain scope, outcome, authority, evidence, and effective history.

TaskExecutions such as `ReviewMaterialQC` and `ReviewResultQC` may produce authorized decisions.

Eligibility is derived from decisions and other applicable conditions.
