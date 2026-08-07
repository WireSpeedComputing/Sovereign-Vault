#!/usr/bin/env python3
"""tests/canonicalize_inventory.py

Canonicalize and hash the JSONL emitted by tests/schema_inventory.sql, so two
databases can be compared by DEFINITION rather than by object name.

    usage: canonicalize_inventory.py <inventory.jsonl> [--role-map a=b,c=d]
                                     [--emit-canonical]
    stdout: <sha256>\t<cat>\t<key>            (one line per object, sorted)
            plus a final line: FINGERPRINT\t<sha256 over all of the above>

── THE PROBLEM THIS SOLVES ────────────────────────────────────────────────────
tests/replay_fresh_install.sh proves equivalence by comparing object NAMES. A
reviewer correctly observed that name-equality does not prove definition
equivalence. The obvious fix -- hash the raw definition text -- fails on a real
case in this repo:

  refresh_retrieval_units() as deployed and as written in sql/27 are
  SEMANTICALLY IDENTICAL and TEXTUALLY DIFFERENT. The applied migration carries
  a condensed body; sql/27 keeps the full commentary. md5(pg_get_functiondef())
  differs between them. A raw-text check would report drift on a correct pair,
  forever, and a checker that cries wolf gets muted -- exactly the failure
  sql/28 exists to undo for perimeter_assert().

So the body is canonicalized before hashing: comments stripped, whitespace
collapsed. Everything that is NOT the body -- signature, return type, language,
volatility, security mode, strictness, leakproofness, parallel safety,
search_path (proconfig), ACL, owner, RLS flags, enum labels, comments-as-
documentation -- is compared EXACTLY, because whitespace in a body is noise and
whitespace in a security mode is not a thing.

── WHAT CANONICALIZATION PROVES ───────────────────────────────────────────────
Two bodies that canonicalize to the same string differ only in comments and in
whitespace runs OUTSIDE string literals and quoted identifiers. Given that,
plus exact equality on every attribute above, the two objects behave
identically. That is a real equivalence claim, and it is the strongest one
available without a theorem prover.

── WHAT CANONICALIZATION DOES NOT PROVE (read this before trusting a pass) ────
1. It is not semantic equivalence. Two bodies that differ in keyword CASE
   (`SELECT` vs `select`), in alias names, in the order of commutative
   predicates, or in any other genuinely-textual-but-harmless way will hash
   DIFFERENTLY and be reported as drift. This tool errs toward false positives,
   not false negatives -- deliberately, because the alternative is a checker
   that misses a rewritten body.
2. Conversely, a comment is not always inert. A body whose only difference is a
   comment hashes the same here even though a human reading the two files
   learns different things. Documentation drift is invisible to this check.
3. Whitespace is not always inert either. Inside a string literal or a quoted
   identifier it is preserved (the tokenizer is quote-aware), but a plpgsql body
   that builds SQL by concatenating unquoted fragments across lines could in
   principle change meaning under collapse. No such construct exists in this
   repo; it is a limit of the technique, not an observed defect.
4. Dollar-quoted contents are treated as OPAQUE literals and are not recursed
   into. For pg_proc.prosrc this is correct -- the body itself is never
   dollar-wrapped at this level -- but a function that embeds a nested $$...$$
   block has that block's comments and whitespace preserved rather than
   canonicalized. Such a pair would report drift.
5. Behaviour depends on things outside every definition: extension versions,
   server settings, collation provider and version, and the contents of
   referenced data. Those are captured elsewhere in the package (version
   metadata, per-table hashes) and are NOT part of this hash.

── ROLE NAMES ─────────────────────────────────────────────────────────────────
Owner and ACL strings carry role names. A restore into a different host
legitimately has different role names (a hosted `postgres` vs whatever local
OS user owns a developer cluster), which would report drift on every single
object. --role-map
rewrites source role names to destination ones as whole-word substitutions.
Using it is a DECLARATION that the two roles are meant to be the same principal;
it is not evidence that they are. An unmapped role difference is real drift.
"""

import sys
import json
import re
import hashlib

# ── SQL-aware canonicalizer ────────────────────────────────────────────────


def canonicalize_sql(text):
    """Strip comments and collapse whitespace, preserving literals exactly.

    Handles: '...' (with '' escape), "..." (with "" escape), $tag$...$tag$,
    -- line comments, /* ... */ block comments (PostgreSQL nests these).
    """
    out = []
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]

        # line comment
        if ch == '-' and i + 1 < n and text[i + 1] == '-':
            j = text.find('\n', i)
            i = n if j < 0 else j          # leave the newline; it collapses below
            out.append(' ')
            continue

        # block comment (nesting)
        if ch == '/' and i + 1 < n and text[i + 1] == '*':
            depth = 1
            i += 2
            while i < n and depth:
                if text[i] == '/' and i + 1 < n and text[i + 1] == '*':
                    depth += 1
                    i += 2
                elif text[i] == '*' and i + 1 < n and text[i + 1] == '/':
                    depth -= 1
                    i += 2
                else:
                    i += 1
            out.append(' ')
            continue

        # single-quoted literal (incl. E'' -- the E was emitted as a bare ident
        # before this point and is preserved)
        if ch == "'":
            j = i + 1
            while j < n:
                if text[j] == '\\' and j + 1 < n:
                    j += 2                 # E'' escape; harmless for plain ''
                    continue
                if text[j] == "'":
                    if j + 1 < n and text[j + 1] == "'":
                        j += 2
                        continue
                    j += 1
                    break
                j += 1
            out.append(text[i:j])
            i = j
            continue

        # quoted identifier
        if ch == '"':
            j = i + 1
            while j < n:
                if text[j] == '"':
                    if j + 1 < n and text[j + 1] == '"':
                        j += 2
                        continue
                    j += 1
                    break
                j += 1
            out.append(text[i:j])
            i = j
            continue

        # dollar-quoted string: $tag$ ... $tag$   (opaque, not recursed into)
        if ch == '$':
            m = re.match(r'\$([A-Za-z_][A-Za-z0-9_]*)?\$', text[i:])
            if m:
                tag = m.group(0)
                end = text.find(tag, i + len(tag))
                if end < 0:
                    out.append(text[i:])
                    i = n
                else:
                    out.append(text[i:end + len(tag)])
                    i = end + len(tag)
                continue

        if ch.isspace():
            out.append(' ')
            i += 1
            continue

        out.append(ch)
        i += 1

    # collapse runs of the spaces we emitted, but only OUTSIDE literals. The
    # pieces appended above are either single chars, single spaces, or whole
    # literals, so rejoin literal-aware rather than regexing the result.
    result = []
    prev_space = False
    for piece in out:
        if piece == ' ':
            if not prev_space:
                result.append(' ')
            prev_space = True
        else:
            result.append(piece)
            prev_space = False
    return ''.join(result).strip()


def apply_role_map(text, role_map):
    for src, dst in role_map:
        text = re.sub(r'(?<![A-Za-z0-9_])' + re.escape(src) + r'(?![A-Za-z0-9_])',
                      dst, text)
    return text


def object_canonical(rec, role_map):
    """Deterministic canonical string for one inventory record."""
    cat = rec['cat']
    key = apply_role_map(rec['key'], role_map)
    attrs = rec.get('attrs') or {}
    parts = ['cat=' + cat, 'key=' + key]
    for k in sorted(attrs):
        v = attrs[k]
        if v is None:
            v = ''
        elif isinstance(v, bool):
            v = 'true' if v else 'false'
        else:
            v = str(v)
        parts.append(k + '=' + apply_role_map(v, role_map))
    body = rec.get('def') or ''
    parts.append('def=' + apply_role_map(canonicalize_sql(body), role_map))
    return '\x1f'.join(parts)


# ── self-test: prove the canonicalizer DISCRIMINATES ───────────────────────
# A canonicalizer that has only ever said "same" proves nothing. These cases
# pin down both directions: what it must call equal, and what it must call
# different. The first case is the real one from sql/27 -- the repo body and the
# condensed body that was actually applied.

_RRU_REPO = """
declare v_inv int := 0; v_acl int := 0;
begin
  -- Count ACL drift BEFORE invalidating, so the number reported is the number
  -- that was actually wrong rather than whatever survived the sweep.
  select count(*) into v_acl
  from retrieval_units ru
  where ru.invalidated_at is null
    and (ru.owner      is distinct from m.owner
      or ru.visibility is distinct from m.visibility);

  /* block comment, possibly nested /* like this */ and closed */
  return query select v_inv, v_acl;
end;
"""

_RRU_CONDENSED = (
    "declare v_inv int := 0; v_acl int := 0; begin select count(*) into v_acl "
    "from retrieval_units ru where ru.invalidated_at is null and (ru.owner is "
    "distinct from m.owner or ru.visibility is distinct from m.visibility); "
    "return query select v_inv, v_acl; end;"
)

# One predicate flipped: `is distinct from` -> `=`. Same shape, different rows.
_RRU_SEMANTIC_CHANGE = _RRU_CONDENSED.replace(
    "ru.visibility is distinct from m.visibility",
    "ru.visibility = m.visibility")

# Only the prose changed.
_RRU_COMMENT_ONLY = _RRU_REPO.replace(
    "Count ACL drift BEFORE invalidating",
    "Completely different explanation of the same code")

# Only keyword case changed.
_RRU_CASE_CHANGE = _RRU_CONDENSED.replace("select count(*)", "SELECT COUNT(*)")


def _self_test():
    def h(s):
        return hashlib.sha256(canonicalize_sql(s).encode('utf-8')).hexdigest()

    cases = [
        # (name, expectation, a, b, why)
        ("sql/27 repo body vs applied condensed body", "same",
         _RRU_REPO, _RRU_CONDENSED,
         "THE motivating case: semantically identical, textually different. A "
         "raw-text check reports drift on this correct pair forever."),

        ("one predicate flipped to =", "differ",
         _RRU_CONDENSED, _RRU_SEMANTIC_CHANGE,
         "the check must catch a body rewrite that survives whitespace "
         "normalization -- this is the failure mode name-equality misses."),

        ("comment text changed, code identical", "same",
         _RRU_REPO, _RRU_COMMENT_ONLY,
         "DOCUMENTED LIMITATION, asserted so it cannot change silently: "
         "documentation drift is invisible to this check."),

        ("keyword case changed", "differ",
         _RRU_CONDENSED, _RRU_CASE_CHANGE,
         "DOCUMENTED FALSE POSITIVE, asserted so it cannot change silently: "
         "canonicalization is not semantic equivalence. It errs loud."),

        ("whitespace inside a string literal", "differ",
         "select 'a  b' from t;", "select 'a b' from t;",
         "collapsing whitespace inside a literal would change a stored value; "
         "the tokenizer must be quote-aware."),

        ("-- inside a string literal is not a comment", "differ",
         "select 'a -- b' , x from t;", "select 'a ' , x from t;",
         "a naive regex comment-strip truncates the literal and silently "
         "equates two different statements."),

        ("$$ dollar-quoted body is opaque", "differ",
         "execute $q$ select  1 $q$;", "execute $q$ select 1 $q$;",
         "nested dollar-quoted text is preserved verbatim, not canonicalized "
         "-- stated in the docstring, asserted here."),

        ("indentation and line breaks only", "same",
         "select a,\n       b\nfrom t;", "select a, b from t;",
         "the whole point: reformatting is not drift."),
    ]

    failures = 0
    for name, expect, a, b, why in cases:
        same = (h(a) == h(b))
        got = "same" if same else "differ"
        ok = (got == expect)
        if not ok:
            failures += 1
        sys.stdout.write("  %-4s %-46s expected %-6s got %-6s\n"
                         % ("PASS" if ok else "FAIL", name, expect, got))
        sys.stdout.write("       %s\n" % why)
    if failures:
        sys.stdout.write("CANONICALIZER SELF-TEST FAILED (%d case(s))\n" % failures)
        return 1
    sys.stdout.write("CANONICALIZER SELF-TEST PASSED (%d cases, both directions)\n"
                     % len(cases))
    return 0


def main():
    args = sys.argv[1:]
    if args and args[0] == '--self-test':
        return _self_test()
    if not args:
        sys.stderr.write(__doc__)
        return 2
    path = args[0]
    role_map = []
    emit_canonical = False
    i = 1
    while i < len(args):
        if args[i] == '--role-map' and i + 1 < len(args):
            for pair in args[i + 1].split(','):
                if '=' in pair:
                    s, d = pair.split('=', 1)
                    role_map.append((s.strip(), d.strip()))
            i += 2
        elif args[i] == '--emit-canonical':
            emit_canonical = True
            i += 1
        else:
            sys.stderr.write('unknown argument: %s\n' % args[i])
            return 2

    lines = []
    seen = set()
    dupes = []
    with open(path, 'r', encoding='utf-8') as fh:
        for raw in fh:
            raw = raw.strip()
            if not raw:
                continue
            rec = json.loads(raw)
            canon = object_canonical(rec, role_map)
            ident = (rec['cat'], apply_role_map(rec['key'], role_map))
            if ident in seen:
                dupes.append(ident)
            seen.add(ident)
            h = hashlib.sha256(canon.encode('utf-8')).hexdigest()
            lines.append((rec['cat'], apply_role_map(rec['key'], role_map), h, canon))

    lines.sort(key=lambda t: (t[0], t[1]))

    for cat, key, h, canon in lines:
        if emit_canonical:
            sys.stdout.write('%s\t%s\t%s\t%s\n' % (h, cat, key, canon))
        else:
            sys.stdout.write('%s\t%s\t%s\n' % (h, cat, key))

    fp = hashlib.sha256()
    for cat, key, h, _ in lines:
        fp.update(('%s\t%s\t%s\n' % (h, cat, key)).encode('utf-8'))
    sys.stdout.write('FINGERPRINT\t%s\tobjects=%d\n' % (fp.hexdigest(), len(lines)))

    if dupes:
        sys.stderr.write('DUPLICATE OBJECT KEYS (inventory query is ambiguous):\n')
        for d in dupes:
            sys.stderr.write('  %s %s\n' % d)
        return 3
    return 0


if __name__ == '__main__':
    sys.exit(main())
