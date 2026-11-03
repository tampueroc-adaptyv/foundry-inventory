#import "paper.typ": paper

#show: paper.with(
  title: [Laboratory Domain Model — Material and Inventory Operations — Draft v1.9],
  abstract: [
    This specification applies Laboratory Operations Algebra — Foundations to material and inventory operations. It derives scientific identity, physical containment, accountable quantities, decisions, and operational eligibility from the foundational primitives and state model. Versioned MaterialSpecifications and ContainerSpecifications define identity and compatibility boundaries; provenance and composition remain distinct from available stock. Immutable, balanced material movements establish quantity correctness and distinguish historical correction from physical reconciliation. Concrete task and workflow applications connect scientific and physical evidence to authorized effects, including partial failure and uncertain execution. Twelve detailed conformance cases and implementation-mapping obligations support evaluation at both foundational and material-domain levels. The material-accounting constraints supplement, rather than redefine or weaken, the foundational guarantees.
  ],
  index-terms: (
    "Material identity",
    "Inventory accounting",
    "Scientific provenance",
    "Containment",
    "Eligibility",
    "Laboratory workflows",
    "Conformance",
  ),
)

#include "material-inventory-content.typ"
