= Material Movement Algebra <material-movements>

Balanced postings specialize the foundational requirement for valid, auditable, domain-authorized transitions. Their balance scopes and correction rules apply to material quantities, not to every other domain's effects.

== Quantity State <quantity-state>

Let $A$ be the set of accountable material positions.

Positions may represent:

- Active ContainerContents.
- External receipt sources.
- Consumption destinations.
- Disposal destinations.
- Discrepancies.
- Production sources.

Active ContainerContents are physical accountable holdings under the identity and uniqueness rules in @container-content. Receipt, consumption, disposal, discrepancy, and production positions have accounting roles; they are not available physical stock.

Let $Q(a)$ be shorthand for $Q_("recorded")(a)$, the recorded balance at position $a$. Balance equations are evaluated within a fixed Material and compatible measurement-dimension scope; those arguments are suppressed in this notation.

For ordinary active ContainerContents:

$ Q(a) gt.eq 0 $

unless specifically authorized otherwise.

Available quantity is derived from recorded quantity, eligibility, relevant inventory state, and applicable restrictions for intended use $u$ at time $t$. In general:

$ Q_("recorded")(a) != Q_("available")(a,u,t) $

For a physical holding with a nonnegative recorded balance:

$ 0 lt.eq Q_("available")(a,u,t) lt.eq Q_("recorded")(a) $

A nonphysical position, closed holding, or an eligibility outcome of `No` or `Unknown` authorizes zero available quantity; `Unknown` remains an unresolved assessment, not proof of physical absence. A negative recorded balance has zero available quantity. Even when eligible, additional restrictions may reduce the available amount. Without additional restrictions, an eligible active physical holding makes its full nonnegative recorded balance available. Availability is not independently posted or adjusted; changes to recorded quantity still require committed movements.

In Conformance Case 6, placing the vial on hold leaves the recorded balance unchanged while availability for validated use becomes zero:

$ Q_("recorded")(C_1)&=50 thin mu L \
Q_("available")(C_1,u_("validated"),t)&=0 thin mu L $

== Postings

Each posting has a stable identity unique within its MaterialMovement. Its accounting payload is:

$ p_i=(a_i,m_i,delta q_i) $

Where:

- $a_i$: Accountable position.
- $m_i$: Material identity.
- $delta q_i$: Signed quantity change with units.

A movement identifier and stable posting index may identify an entry. Identical payloads do not imply identical postings. Negative postings reduce a position's quantity; positive postings increase it.

== MaterialMovement

A movement is a finite indexed family of uniquely identifiable postings:

$ "MM"=(p_i)_(i=1)^n $

Let $I_(m,d)$ select posting indices for Material $m$ and measurement dimension $d$, and $I_a$ select indices at position $a$ within the balance's Material/dimension scope. Each index is counted once, even when accounting payloads coincide.

$ sum_(i in I_(m,d)) delta q_i=0 $

Quantities must be expressed in compatible units. The resulting balance is:

$ Q'(a)=Q(a)+sum_(i in I_a) delta q_i $

Movements commit only when relevant invariants hold. Parenthesized rows in the examples denote indexed entries with indices and identifiers omitted for readability, not deduplicated entries. An index identifies a posting; it does not prescribe an execution or commitment order.

== Transfer

Transfer 20 µL of $M_1$ between Contents $C_1$ and $C_2$:

$ "MM"_("transfer")=
lr((

&(C_1,M_1,-20 thin mu L), \

&(C_2,M_1,+20 thin mu L)

)) $

Both postings commit together.

== Consumption and Disposal

Consumption and disposal use the same underlying transfer/posting mechanism.

For consumption:

$ op("ConsumeMaterial")(C,q)
equiv
op("TransferMaterial")(C,"Consumed",q) $

For disposal:

$ op("DiscardMaterial")(C,q)
equiv
op("TransferMaterial")(C,"Disposed",q) $

These equivalences describe their quantity-accounting effects.

`Consumed` and `Disposed` are internal accountable destinations, not necessarily physical containers.

Domain-specific operations may impose additional authorization, handling, and evidence requirements.

If material is moved into a tracked physical waste container instead, its destination may be another ContainerContent.

That physical holding remains separately traceable until the waste leaves tracked inventory.

== Production and Scientific Transformation

For input Material $M_i$:

$ "MM"_("input",i)=
lr((

&(C_i,M_i,-q_i), \

&("Consumed",M_i,+q_i)

)) $

For output Material $M_O$:

$ "MM"_("output")=
lr((

&("Produced",M_O,-q_O), \

&(C_O,M_O,+q_O)

)) $

Input and output movements balance independently within their Material identities.

Scientific provenance and composition are recorded separately.

There is no universal requirement that:

$ q_O= sum _i q_i $

== Corrections and Reconciliation <corrections>

Committed MaterialMovements are immutable.

We distinguish correcting erroneous history from reconciling inventory against physical observation.

=== ReverseMovement

For:

$ "MM"=((a_i,m_i,delta q_i))_(i=1)^n $

The reversal is:

$ op("ReverseMovement")("MM")
=
((a_i,m_i,-delta q_i))_(i=1)^n $

It compensates an erroneous recorded movement. Each reversal posting has a new identity and links to the original posting it compensates. The correspondence preserves every original index, even when payloads coincide.

No new physical transfer is implied.

=== ReplaceMovement

$ op("ReplaceMovement")("MM"_("old"),"MM"_("new"))
=
op("ReverseMovement")("MM"_("old"))
+
"MM"_("new") $

The correction commits as one validated group. Here $+$ groups the reversal and replacement postings for joint commitment; it never merges entries with equal payloads.

The original remains in history and is explicitly superseded.

=== ReconcileQuantity

$ delta q=q_("observed")-q_("recorded") $

For recorded 50 µL and observed 45 µL:

$ "MM"_("reconcile")=
lr((

&(C_1,M_1,-5 thin mu L), \

&("Discrepancy",M_1,+5 thin mu L)

)) $

The reconciliation references observation, evidence, and authorization.

It does not invent a historical cause.

== Correction Integrity <correction-integrity>

Under a one-effective-reversal policy:

$ op("EffectiveReversalCount")("MM") lt.eq 1 $

Replacement establishes:

$ op("Supersedes")("MM"_("new"),"MM"_("old")) $

Corrections are validated as complete groups against current authoritative state, including legitimate subsequent activity. A reversal or replacement must not invalidate later valid movements, holdings, or references, nor silently erase or reinterpret legitimate subsequent activity. If that activity prevents a valid correction, reject the proposal or require explicit, evidence-backed, authorized resolution.

For example, a 20 µL transfer into an initially empty holding is followed by legitimate 15 µL consumption, leaving 5 µL. Replacing the transfer with 10 µL would debit another 10 µL and leave -5 µL. With no authorized negative-balance exception, reject that correction; do not delete the consumption or fabricate a receipt. Replacing it with 15 µL instead would leave zero and pass the quantity test, but all other invariants and evidence requirements still apply.

== Movement Invariants <movement-invariants>

#table(
  columns: (1fr, 1fr),
  table.header([Invariant], [Requirement]),
  [Balance], [Postings balance within compatible Material and dimension scopes],
  [Valid quantity], [No unauthorized negative active balances],
  [Posting identity], [Every posting is identifiable; equal payloads remain separate accounting entries],
  [Atomicity], [All postings of one movement commit together],
  [Idempotency], [A movement cannot be committed twice],
  [Traceability], [Movements reference originating executions or events],
  [Immutability], [Committed history is preserved],
  [Compatibility], [Material identity and unit rules are respected],
  [Authorization], [Restricted movements and corrections require permission],
  [Correction integrity], [Corrections cannot conflict or duplicate],
  [Evidence], [Corrections and observations retain supporting evidence],
)

Balanced postings alone do not establish scientific or physical validity.
