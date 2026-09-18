# Jev Collection evaluation

Standalone, standard-library Python prototype. Does not change the iOS app, its data,
or its recommendation algorithm. Requires Python 3.9+.

## Run

1. Put `TYPESAFE_API_KEY=...` in the root `.env.jev.local` (gitignored), or set that
   environment variable. TMDB credentials come from `Up Next/Info.plist`; optionally
   supply `TMDB_API_KEY` in the same local file or environment.
2. Prepare real metadata and fixed candidate pools:
   `python3 experiments/collection_recommendations/evaluate.py prepare`
3. Evaluate with Jev:
   `python3 experiments/collection_recommendations/evaluate.py run --batch-size 6`
4. Open `.local/jev-eval/report.html` for the comparison. The folder is gitignored.

Use `--case comedy_before --case comedy_after` to evaluate selected cases.
Responses are cached by the complete payload, model ID, and prompt version.
`run --batch-size 6 --fresh` makes new paid calls; `report --batch-size 6` replays cached results without calling Jev. Omit `--batch-size` to reproduce the initial whole-state experiment.
Each live call has a 30-second timeout and no automatic retries. A failed case does
not invent scores; successful responses remain cached for the next run.

## What this measures

- Six cases, including the same comedy collection before and after adding Dodgeball.
- Up to 30 TMDB recommendation candidates per case, plus a few named diagnostic probes.
  Probe IDs are test fixtures, not app rules. All titles and metadata are fetched from TMDB.
- The before/after cases use a shared pool from both movies, excluding current members.
  This isolates ranking changes from retrieval changes. It is not a simulation of the
  production one-seed retrieval path.
- A transparent baseline sums reciprocal positions from each current member's TMDB feed.
  This is **not** an exact reproduction of the Swift app's recommendation engine.
- With `--batch-size 6`, each request evaluates up to six candidates using Collection-fit
  and tone-similarity Scores. Keyword relevance Nouls run separately in groups of up to
  16 keywords. Up to three requests run concurrently within a collection. The initial
  whole-state experiment remains available for comparison. Raw names are preserved; no
  Christmas aliases or technical-keyword blocklists are applied.
- Experimental rank: 75% normalized Collection fit, 25% normalized tone. Confidence
  is displayed separately and is not treated as correctness or multiplied into fit.
- The report records original request latency, model version, token usage, estimated
  model cost, and top-10 overlap after adding Dodgeball. Cached runs are marked.

The pinned model is `jev-1.13.0`. Estimated cost uses the published September 18,
2026 rate of $0.042 per million input tokens (free output). Recheck pricing before
using cost estimates for budgeting. Actual billing may differ.

## Human evaluation and next steps

`review.json` contains blank human judgments and is never overwritten. Label
`human_fit` from 0 (unrelated) through 3 (strong fit), adding notes where the
Collection intent is ambiguous. Inspect the top 10 for each collection and the
keyword judgments, particularly credit-scene metadata for the comedy case.

There is no claimed accuracy percentage without these labels. Movie similarity
scores are model judgments, not facts. Changes in top-10 membership are a diagnostic,
not inherently an error. Empty-collection discovery, TV ranking, model-selected
keyword retrieval, production caching, and backend deployment are outside this first
experiment. Keyword scores are recorded for a subsequent retrieval experiment.

The generated request JSON files make all submitted context reviewable. Only these
synthetic test collections and public TMDB metadata are sent to TypeSafe; this script
does not read the user's actual library or CloudKit data.

## Checks

`python3 -m unittest discover -s experiments/collection_recommendations -p 'test_*.py'`

Checks cover question targeting, verbatim Collection names, baseline deduplication,
missing/invalid model answers, score ranges, distributions, and stable tie-breaking.

## Sources

- [TypeSafe API](https://docs.typesafe.ai/api)
- [Score](https://docs.typesafe.ai/primitives/score)
- [Noul](https://docs.typesafe.ai/primitives/noul)
- [Models and pricing](https://docs.typesafe.ai/models)
- [Re-ranking](https://docs.typesafe.ai/cookbooks/rerank_typesafe)
- [TypeSafe skill](https://github.com/typesafe-ai/skills/blob/main/skills/typesafe-ai/SKILL.md)

## First live results

See [findings.md](findings.md) for the September 18, 2026 experiment, including the
input-order sensitivity found in whole-state requests. The smaller-batch comparison
is the current report at `.local/jev-eval/report.html`; the initial report is preserved
as `report-whole-state.html`. `summary.json` and `diagnostics.json` contain machine-readable
results. These are initial qualitative observations, not human-labeled accuracy scores.
