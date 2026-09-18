# Jev Collection evaluation — September 18, 2026

Model: `jev-1.13.0`. Rubric: `collection-fit-v1`. Six synthetic Collections, real
TMDB metadata, fixed candidate pools, no access to the user's actual library.
The app has not been switched to Jev.

## Initial results and a significant failure

The initial six whole-state requests took 0.69–1.01 seconds each (median 0.73 s),
using 102,970 input tokens, approximately $0.00432 at the published input-token rate.
Each request contained 32–33 movies plus keyword metadata and all associated questions.

While the top results mostly appeared relevant, two user-specified positives failed:

| Candidate and Collection | Original fit / 3 | Moved to first position | Two-candidate context |
| --- | ---: | ---: | ---: |
| Dodgeball in Dumb funny with Anchorman | 1.10 | 2.37 | 2.84 |
| Four Christmases in Xmas | 0.64 | 2.09 | 2.53 |

The reordering test preserved the movie metadata, rubric, and collection. It changed
candidate order and regenerated question paths. The compact test kept the target and
The Avengers as a negative control and removed keyword context. These observations show
input-layout/context sensitivity in this experiment. They do not establish its internal
cause or prove all smaller batches will be order-invariant.

## Smaller batches

We kept the same rubric, candidates, and ranking weights. Movie requests contain at most
six candidates; keywords are evaluated separately, up to 16 per request. Three requests
run concurrently per Collection.

| Collection | Leading results |
| --- | --- |
| Xmas | Home Alone 2, Elf, Rudolph the Red-Nosed Reindeer, The Santa Clause 2 |
| Dumb funny — Anchorman only | Wake Up, Ron Burgundy; Dodgeball; The Jerk; The Other Guys |
| Dumb funny — with Dodgeball added | Wake Up, Ron Burgundy; The Jerk; The Other Guys; Major League |
| Quiet, thoughtful sci-fi | After Yang, Contact, Moon, Swan Song, Solaris |
| Rainy day mysteries | Glass Onion, Murder by Death, See How They Run, The Cheap Detective |
| Comfort rewatches | Ponyo, Kiki's Delivery Service, Arrietty, Spirited Away |

Dodgeball rose to #2 with fit 2.86/3. Four Christmases scored 2.53/3 but remained #26:
the member movies and tone weighting favor family-oriented Christmas titles. Jingle All
the Way ranked #11 with fit 2.85/3. Those fit scores are model judgments, not correctness
probabilities. User judgment is still needed about the desired breadth of Xmas suggestions.

The Avengers and Spider-Man: No Way Home were the last two suggestions after adding
Dodgeball. Nine of the comedy top ten were retained after the addition, excluding the
newly added movie from both lists before comparison. This measures stability, not accuracy.

Smaller-batch evaluation took 1.26–1.41 seconds per Collection (median 1.33 s), excluding
TMDB preparation. The six evaluations represent 52 requests and 127,482 input tokens,
approximately $0.00535 for a fully uncached evaluation. One subrequest reused a diagnostic
result. Across the initial run, diagnostics, and smaller-batch run, 61 distinct live calls
used 264,967 input tokens: approximately $0.01113 total model cost. This excludes backend
cost and is an estimate from usage, not a billing statement. Six cases are insufficient
for production latency percentiles.

## Keyword discovery is less conclusive

Jev gave the Christmas keyword 0.95 and murder mystery 0.92 probability of relevance.
For the two-movie comedy Collection, oddball was 0.47 and screwball comedy 0.45.
After-credit and during-credit metadata scored 0.10 and 0.13 respectively. This is useful
evidence against the original bug, but the low positive probabilities do not justify
automatically turning comedy metadata into retrieval filters with a universal threshold.

## Recommendation

Continue with Jev as a candidate reranker using focused contexts. Keep the keyword
judgments diagnostic until evaluated against more collections. Treat low-confidence
results conservatively and retain a TMDB fallback. Before shipping, collect human labels,
test additional candidate permutations, and decide how much seed tone should narrow
broad Collection themes. Empty collections, TV collections, and selecting new retrieval
queries remain separate experiments.

Artifacts are in the gitignored `.local/jev-eval/`: the comparison HTML, original report,
raw request/response caches, diagnostics, and summary. Cached results can be reproduced
with `python3 experiments/collection_recommendations/evaluate.py report --batch-size 6`.
