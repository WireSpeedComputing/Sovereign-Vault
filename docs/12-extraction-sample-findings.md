# Synthetic extraction examples

These examples are invented to demonstrate evaluation cases. They are not
customer records, measurements or evidence of a deployed extraction system.

| Synthetic text | Expected handling |
| --- | --- |
| “Store North receives deliveries on Tuesdays, effective next month.” | Extract a dated schedule assertion; retain the source and uncertainty about the exact start date. |
| “Please ask Store North whether Tuesday delivery still works.” | Coordination request; do not extract Tuesday delivery as a confirmed current fact. |
| “Release 8 disables the legacy endpoint; release 7 remains supported until Friday.” | Two version-scoped assertions with distinct subjects and effective intervals. |
| “Do not state that every customer has migrated.” | Negative instruction; do not extract universal migration as a fact. |
| “The previous notice was replaced by this version.” | Resolve the explicit predecessor through authorized evidence; retain both versions. |
| “An attachment may contain the approval.” | Missing evidence; do not synthesize an approval or source locator. |

## Controls for an evaluation suite

Use labeled synthetic fixtures to verify that:

- Facts and requests remain distinct.
- Negation and uncertainty survive normalization.
- Sources resolve under the caller's authority.
- Supersession preserves history and current-only retrieval excludes prior versions.
- Private and out-of-scope records do not enter outputs or aggregate counts.
- Missing source extraction, incomplete evaluation and truncated results remain
  visible as coverage gaps.
- Normalized candidates remain proposals until an authorized review transition.

Report test results for the exact source revision and synthetic corpus. Real
dataset descriptions, operational findings, counts and customer decisions belong
in private evaluation records.
