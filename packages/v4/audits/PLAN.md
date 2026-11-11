# Audit plan

**Status: saved for later. Do not start until the code is declared ready.**

The plan is to audit `packages/v4` from many independent angles, record every finding under the
source that produced it, merge the lot into one master report, and then fix the findings one at a
time.

## 0. Before starting

- [ ] The code is declared ready, and one commit is pinned as the audit target. Every run audits
      that commit and nothing else.
- [ ] Scope is written down: `packages/v4/src` (hook, coin, deployer, router, lens, the two
      libraries, the interface) and `packages/v4/script`. Decide whether v1 is in scope too.
- [ ] One fixed prompt is written for all model runs, so that differences between runs come from
      the model and the harness, not from the wording.
- [ ] Decide whether runs see the README's "Known limits" section. Recommended: no for the first
      pass, so that a run rediscovering a known issue is evidence the run works.

## 1. Models x harnesses: 18 runs

Three models, each run through six harnesses.

| Harness | Fable 5.2 | GPT-6 Astra | Gemini 4 Carbon |
|---|---|---|---|
| [Heesho/gebal](https://github.com/Heesho/gebal) | F-GEBAL | G-GEBAL | C-GEBAL |
| [Uniswap/uniswap-ai](https://github.com/Uniswap/uniswap-ai) | F-UNI | G-UNI | C-UNI |
| [0xsimao/0xsimao-ai](https://github.com/0xsimao/0xsimao-ai) | F-SIMAO | G-SIMAO | C-SIMAO |
| [pashov/skills](https://github.com/pashov/skills) | F-PASHOV | G-PASHOV | C-PASHOV |
| [Kritt-ai/open-kritt](https://github.com/Kritt-ai/open-kritt) | F-KRITT | G-KRITT | C-KRITT |
| [trailofbits/skills](https://github.com/trailofbits/skills) | F-TOB | G-TOB | C-TOB |

Rules for every run:

- A fresh session with no memory of this project and no sight of any other run's findings or of
  `FINDINGS.md`.
- The same pinned commit and the same prompt.
- The run's raw output is saved untouched under `audits/raw/<run id>/` before anything is copied
  out of it.

To settle when we start, not now:

- What each harness actually provides and how it is installed and invoked. None of them has been
  read yet.
- Whether each harness runs under all three models. Some may be written as skills for one agent
  and need a runner or a port for the other two. A cell that cannot be run is recorded as such,
  with the reason, not silently dropped.

## 2. Analysis tools: 4 runs

| Tool | Kind | State today | Work needed |
|---|---|---|---|
| Slither | Static analysis | In CI; 0 results with `slither.config.json` | Also run with nothing excluded and record the full output |
| Aderyn | Static analysis | Not set up | Install and run |
| Echidna | Property fuzzing | Not set up | Port the Foundry invariants to Echidna properties |
| Halmos | Symbolic execution | Not set up | Write symbolic tests, starting with `CurveMath` and `TickRounding` |

Run IDs: `T-SLITHER`, `T-ADERYN`, `T-ECHIDNA`, `T-HALMOS`.

## 3. External AI audits: 2 runs

| Service | Run ID | To confirm |
|---|---|---|
| V12 | X-V12 | Access, cost, what it needs as input |
| Veridise Scout | X-SCOUT | Access, cost, what it needs as input |

## 4. Recording: `audits/FINDINGS.md`

One large file with one section per source, in the order above (24 sources in all). Under each
source, every finding it reported, including ones that look wrong or duplicate another source:

```markdown
## F-PASHOV: Fable 5.2 x pashov/skills

### F-PASHOV-01: <title as reported>
- Severity as reported:
- Location:
- Claim:
- Raw output: raw/F-PASHOV/...
```

Nothing is judged, merged or dropped at this stage. A source that found nothing gets a section
saying so.

## 5. Master report: `audits/REPORT.md`

- Merge duplicates into one entry each, listing every source that found it.
- Verify each entry: reproduce it with a test, or show why it does not hold.
- Give each a verdict (confirmed, not an issue, known limit, out of scope) and our own severity.
- Add a table of which sources found which confirmed issues, so the matrix itself can be judged.

## 6. Fixing

Go through the confirmed entries one by one, most severe first. For each: a failing test, the
fix, the test passing, then the full suite (CI depth, deep invariants, fork tests, Slither).
Each entry in `REPORT.md` is marked with the commit that closed it.

## What already exists

An internal review was done on 2026-11-11 (three independent reads plus a second pass on freezing
and rounding). What it found is fixed or listed under "Known limits" in the README. It is separate
from this plan and does not count as one of the runs.
