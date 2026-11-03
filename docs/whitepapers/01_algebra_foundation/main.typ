#import "paper.typ": paper

#show: paper.with(
  title: [
    #set par(justify: false)
    Foundry Operations Algebra — Foundations \
    #text(size: 11pt)[Tomás Ampuero \
    November 3, 2026]
  ],
  abstract: [
    Foundry Operations Algebra defines domain-independent concepts and correctness guarantees for how laboratory work changes authoritative state. Entities, relationships, specifications, tasks, events, and effects separate modeled identity, intended work, evidence, and accepted change. Versioned task lifecycles, checkpoints, and domain-governed commitments constrain valid transitions, while composition distinguishes independent operations, supported atomic effect groups, and ordered dependencies. A systematic derivation method guides new domain models without prescribing storage, service, or orchestration mechanisms. Foundational conformance obligations and a generic uncertain-execution example make authority, failure, retry, and recovery semantics testable independently of inventory. Domain specializations may add constraints but must not weaken these guarantees.
  ],
  index-terms: (
    "Foundry operations algebra",
    "Domain modeling",
    "State transitions",
    "Execution lifecycle",
    "Effect commitment",
    "Conformance",
    "System design",
  ),
)

#set document(title: "Foundry Operations Algebra — Foundations", author: "Tomás Ampuero", date: datetime(year: 2026, month: 11, day: 3))

#include "algebra.typ"
