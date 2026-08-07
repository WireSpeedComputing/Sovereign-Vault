---
name: Bug report
about: Something in this repository behaves differently from what it documents
title: ''
labels: bug
---

<!--
  STOP. Issue bodies AND TITLES are published and are never swept.
  contrib/rule0-sweep.generic.sh reads the working tree and git history. It
  cannot read this box. You are the only gate on it.
  Full version: .github/PUBLIC-SAFETY.md · Authority: docs/06-public-safety-checklist.md
-->

## What happened

<!--
  Describe the behaviour, not the incident. "supersede_memory() rejects a
  5-argument call" is portable. "our deployment started erroring at 14:02
  after migration 39" is a timeline of a real system.
-->

## What the repository says should happen

<!-- Cite the file and line you read it from. -->

## Reproduction

<!--
  Synthetic fixtures only. Never "run this against prod".
  A fresh replay is the right substrate for almost every bug here.
-->

```sh
```

## Public safety (required before submitting)

- [ ] No pasted error output or stack traces. They carry local paths, database
      names, role names, and sometimes connection strings. If the error text is
      load-bearing, retype only the message and drop everything around it.
- [ ] No row counts, table sizes, or record counts from a real deployment.
      "About two hundred rows" is a fact about a private system.
- [ ] No hostnames, project refs, keys, personal names, or domains — including
      in pasted output and in file paths.
- [ ] Nothing here reconstructs which control is currently unenforced, in what
      order the gaps stack, or which one is easiest to reach. Describing a
      missing control generically is doctrine; describing it as the live state
      of a running system is a map.
- [ ] **The title** was checked against all of the above. Titles are indexed,
      quoted into notifications, and almost never edited afterwards.
- [ ] No screenshots or terminal recordings. A browser screenshot carries tab
      titles and URL bars; a recording carries the whole scrollback, including
      the command that set the environment variable.

## Judgement

Answer, do not tick: **does this issue reduce the work required to attack a real
deployment?** Not "does it contain a secret" — does it shorten someone's path.

<!--
  If the honest answer is yes, do not open this issue publicly. Report it
  privately and reference it here only once it is fixed.
-->
