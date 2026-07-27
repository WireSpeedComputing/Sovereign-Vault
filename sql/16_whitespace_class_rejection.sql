-- Whitespace-class rejection: reject all-whitespace values in required text columns
-- (content, citation) using a real whitespace-class regex, not a btrim-only emptiness
-- check. btrim() with no explicit character set strips spaces only -- a value consisting
-- solely of tabs and/or newlines would pass a btrim-based check while still being
-- functionally empty.
--
-- NULL values are unaffected -- a CHECK constraint treats NULL as satisfied, so this only
-- rejects a NON-NULL value that is empty or all-whitespace. citation stays optional where
-- it already was; it just cannot be set to whitespace-only garbage.

ALTER TABLE public.memories ADD CONSTRAINT memories_content_not_whitespace CHECK (content !~ '^\s*$');
ALTER TABLE public.memories ADD CONSTRAINT memories_citation_not_whitespace CHECK (citation !~ '^\s*$');

ALTER TABLE public.wiki_pages ADD CONSTRAINT wiki_pages_content_not_whitespace CHECK (content !~ '^\s*$');
ALTER TABLE public.wiki_pages ADD CONSTRAINT wiki_pages_citation_not_whitespace CHECK (citation !~ '^\s*$');

-- Any additional domain-specific tables with content/citation-style required text columns
-- (e.g. the example module in sql/10-12) should get the same constraint pattern:
-- ALTER TABLE public.<table> ADD CONSTRAINT <table>_<column>_not_whitespace CHECK (<column> !~ '^\s*$');
