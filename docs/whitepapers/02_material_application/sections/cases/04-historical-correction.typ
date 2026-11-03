== Conformance Example \#4 — Historical Correction

=== Natural Language

The system recorded a 20 µL transfer, but the actual transfer was 15 µL.

=== Algebra

$ "MM"_("old")=
lr((

&(C_A,M_1,-20 thin mu L), \

&(C_B,M_1,+20 thin mu L)

)) $

$ "MM"_("new")=
lr((

&(C_A,M_1,-15 thin mu L), \

&(C_B,M_1,+15 thin mu L)

)) $

$ op("ReplaceMovement")("MM"_("old"),"MM"_("new")) $

=== Expected Result

- Net recorded transfer: 15 µL.
- Original history preserved.
- Correction auditable.
- No new physical transfer implied.

Reversal and replacement commit atomically within the Material domain.
