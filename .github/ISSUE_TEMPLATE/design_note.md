---
name: Design note or doctrine proposal
about: Propose a mechanism, or record a design decision and the reasoning behind it
title: ''
labels: design
---

<!--
  Issue bodies AND TITLES are published and are never swept by
  contrib/rule0-sweep.generic.sh. You are the only gate on this box.
  Full version: .github/PUBLIC-SAFETY.md · Authority: docs/06-public-safety-checklist.md
-->

## The problem

<!-- State the failure this addresses, not the solution. -->

## What was tried first, and why it failed

<!--
  This section is the point of the template. The obvious implementation is
  usually the one that fails, and a proposal that omits the failed version
  invites the reader to reimplement it.
  Example shape: a single case-insensitive pattern list is the obvious leak
  checker, and it is the one that cries wolf until it gets skipped.
-->

## Proposal

## How this could fail, and how that would be detected

<!--
  Required. A mechanism with no stated failure mode has not been thought
  through. Name what it cannot see, not only what it catches.
-->

## Evidence

- [ ] Every claim about what the code does today cites the file and line it was
      read from.
- [ ] Claims about what *should* exist are marked as proposals, not described in
      the present tense.
- [ ] If this proposes a check, it says how the check would be proven to
      **fail** on known-bad input. A check that has only printed "clean" proves
      nothing.

## Public safety (required before submitting)

- [ ] Portable claims only. "The schema supports X" belongs here; "our instance
      is currently at X" does not.
- [ ] No deployment identifiers, hostnames, keys, personal names, or real row
      counts — in the body or the title.
- [ ] No ordered narrative of what broke on a real system, when, and what was
      tried. Those are internal coordination transcripts wearing a technical hat.
- [ ] Exact digests, receipts, and counts are treated as identifiers even when
      they look like statistics.
- [ ] Nothing here would embarrass anyone if quoted back in six months with no
      surrounding context.
