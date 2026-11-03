#import "paper.typ": paper

#show: paper.with(
  title: [Laboratory Operations Algebra — Foundations — Draft v1.7],
  abstract: [
    Laboratory Operations Algebra defines domain-independent concepts and correctness guarantees for how laboratory work changes authoritative state. Entities, relationships, specifications, tasks, events, and effects separate modeled identity, intended work, evidence, and accepted change. Versioned task lifecycles, checkpoints, and domain-governed commitments constrain valid transitions, while composition distinguishes independent operations, supported atomic effect groups, and ordered dependencies. A systematic derivation method guides new domain models without prescribing storage, service, or orchestration mechanisms. Foundational conformance obligations and a generic uncertain-execution example make authority, failure, retry, and recovery semantics testable independently of inventory. Domain specializations may add constraints but must not weaken these guarantees.
  ],
  index-terms: (
    "Laboratory operations algebra",
    "Domain modeling",
    "State transitions",
    "Execution lifecycle",
    "Effect commitment",
    "Conformance",
    "System design",
  ),
)

#include "algebra.typ"
