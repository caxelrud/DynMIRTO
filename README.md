# DynMIRTO

[![CI](https://github.com/caxelrud/DynMIRTO/actions/workflows/ci.yml/badge.svg)](https://github.com/caxelrud/DynMIRTO/actions/workflows/ci.yml)

A Julia optimization engine exploring the ideas behind AspenTech's GDOT
("Generic Dynamic Optimization Technology", from Apex Optimisation,
acquired by AspenTech in 2018) — corrected here from this project's
original (wrong) assumption that GDOT was gasoline-specific. It has
three layers, each a genuinely different kind of model, not three
versions of the same thing:

- **v1** — single-period blend-recipe optimization (an LP): given
  blendstock components and product specs, the minimum-cost blend
  recipe meeting every spec.
- **v2** — multi-period scheduling on top of v1: tank inventory that
  evolves via scheduled receipts and blending draws over a horizon.
- **v3** — a scoped-down implementation of GDOT's *actual* technical
  core (per [its inventor's patent](https://patents.google.com/patent/US20100274368A1)):
  nonlinear dynamic unit models, real-time data reconciliation against
  noisy measurements, and continuous re-optimization via successive
  linear programming — a genuine closed real-time loop, unlike v1/v2's
  one-shot LPs.

v1/v2 use JuMP.jl + HiGHS directly; v3 also uses them, but as the inner
solver of a repeated linearize-and-resolve loop rather than a single
LP. **v1 and v3 are now connected, and so are v2 and v3** (section 11):
v3's units source v1's blend components (or v2's tanks) in real time,
and the planning layer's LP shadow prices become the live economic
signal v3 optimizes against — the actual "missing link" GDOT's own
materials describe, not three independent demos that happen to share a
repo.

See [`DESIGN.md`](DESIGN.md) for the full design of each layer,
including v1's blending-index handling for non-linear properties (RON,
RVP, ...), v2's key simplification (fixed-quality tanks — section 9.1),
v3's scope cuts relative to the real technology (section 10.2), and the
v1↔v3 coordination's own scope cuts and a real limitation it exposed
(a shadow-price cold-start deadlock — section 11.5).

## Quickstart

```sh
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. test/runtests.jl

# v1: single-period blend optimization
julia --project=. scripts/run_scenario.jl data/examples/regular_unleaded.json
julia --project=. scripts/run_scenario.jl data/examples/multi_grade.json

# v2: multi-period scheduling (tanks, receipts, demand over a horizon)
julia --project=. scripts/run_schedule.jl data/examples/schedule_example.json

# v3: real-time dynamic optimization (nonlinear units, noisy sensors, closed loop)
julia --project=. scripts/run_dynamic_demo.jl

# v1 <-> v3 connected: a unit's real-time output feeds v1's blend, whose
# shadow prices feed back as the unit's live economic signal
julia --project=. scripts/run_coordination_demo.jl

# the same, but from a true cold start -- shows the deadlock fix (floor_price)
julia --project=. scripts/run_coordination_coldstart_demo.jl

# v2 <-> v3 connected: the same idea extended to tanks/scheduling, plus
# genuine cross-tick tank accumulation (v1's coordination has no memory
# between ticks at all -- this does)
julia --project=. scripts/run_coordination_schedule_demo.jl
```

## Interactive notebook

`notebooks/blend_explorer.jl` is a [Pluto.jl](https://plutojl.org) notebook:
sliders for component cost/availability and product specs, with the blend
recipe (bar chart, quality-vs-spec table, and the CLI's own text report)
recomputing live as you move them. It develops the `DynMIRTO` package
straight from `src/` (via `Pkg.develop`) into its own throwaway environment,
so it always reflects the current code and never touches your global Julia
install.

```sh
julia -e 'using Pkg; Pkg.add("Pluto")'
julia -e 'using Pluto; Pluto.run(notebook="notebooks/blend_explorer.jl")'
```

The first run installs the notebook's own dependencies (a minute or two);
after that it opens instantly. A static, non-interactive HTML snapshot can
be regenerated with:

```sh
julia -e 'using Pkg; Pkg.add("PlutoSliderServer"); using PlutoSliderServer; PlutoSliderServer.export_notebook("notebooks/blend_explorer.jl")'
```

### Running it without installing anything (e.g. from a phone)

`notebooks/blend_explorer_standalone.jl` is the same idea, but with the
`Types`/`BlendIndices`/`Optimizer` logic and one example scenario inlined
directly into the notebook instead of loaded from `src/`/`data/`. That
means it only depends on registered packages (JuMP, HiGHS, PlutoUI), so
Pluto's own "Edit or run this notebook" → *Run with Binder* button works
with zero local setup — including from a phone browser. Open the exported
HTML (or the notebook via `Pluto.run`), click that button, and wait 1–3
minutes for a fresh cloud Julia session to start.

It is **not auto-synced** with `src/` — if the core logic changes there,
re-copy it into this file by hand. Use `blend_explorer.jl` (above) for
day-to-day development against the live package.

`notebooks/blend_explorer_standalone.pdf` is a print-out of this notebook
(captured from an actual running session, default slider values) for a
quick look without running anything — it's a snapshot, not regenerated
automatically, so it can drift from the notebook over time.

### Schedule Explorer (v2)

`notebooks/schedule_explorer.jl` is the same idea for the multi-period
scheduler: sliders for demand, each scheduled receipt, the octane spec,
and the butane tank's capacity. Recomputing live are a tank-level grid
(one row per tank, one column per period, with a pink cell wherever a
tank is at or near its floor) and a per-period recipe table. It's linked
to `src/` the same way as `blend_explorer.jl`, so it always reflects the
current scheduling code.

```sh
julia -e 'using Pkg; Pkg.add("Pluto")'
julia -e 'using Pluto; Pluto.run(notebook="notebooks/schedule_explorer.jl")'
```

`notebooks/schedule_explorer.pdf` is a print-out (same caveats as the
blend explorer's: a snapshot at default slider values, not auto-
regenerated).

### Coordination Explorer (v1 ↔ v3)

`notebooks/coordination_explorer.jl` is an interactive view of the
real-time loop in "Connecting v3 to v1" below: sliders for the
reformer's initial feed setpoint, its operating cost, REF's
`floor_price`, the octane spec, the number of ticks, and measurement
noise. Recomputing live are a feed/production-rate trend (one row per
tick, pink where that tick's blend was infeasible), a shadow-price/cost
table, and the hand-derived analytical equilibrium (section 11.3),
recomputed live from the operating-cost slider so you can check it
against where the simulation actually converges.

Drag **initial feed (u_init)** down to `0` with **floor_price** left at
`0` to watch the cold-start deadlock (section 11.5) happen live — every
row turns pink and stays there. Then raise **floor_price** and watch the
same run escape it partway through instead.

```sh
julia -e 'using Pkg; Pkg.add("Pluto")'
julia -e 'using Pluto; Pluto.run(notebook="notebooks/coordination_explorer.jl")'
```

`notebooks/coordination_explorer.pdf` is a print-out (same caveats:
default slider values, not auto-regenerated).

## Real-time dynamic optimization (v3)

`scripts/run_dynamic_demo.jl` runs a small closed loop with a mix of
unit types:

- Two single-input/single-output units, each with a concave
  (diminishing-returns) steady-state yield curve, sharing a binding
  utility budget.
- One genuinely **multivariable** unit (`DynamicUnit` supports any
  number of named inputs/outputs — see DESIGN.md section 10.6): a toy
  2-input/2-output "distillation column" where reflux and reboiler duty
  both affect *both* outputs (real cross-coupling), linearized via a
  full Jacobian rather than one derivative per output.

Every tick it re-solves for the economic optimum from a noisy,
reconciled state estimate — watch each `target` lock onto its
analytical optimum immediately (it only depends on the economics) while
`applied` ramps there under that input's own rate limit, and `y_hat`
climbs toward the true steady-state outputs as the dynamics settle.

Unlike v1/v2, v3 scenarios are defined in Julia code, not JSON — see
DESIGN.md section 10.2 for why. There's no notebook for v3 yet.

## Connecting v3 to v1

`scripts/run_coordination_demo.jl` runs a blend (spec: RON ≥ 90) that
draws from a static, always-plentiful filler ($40/unit, RON 80) and a
component sourced live from a `DynamicUnit` reformer ($0 blend-side
cost, RON 95) whose *production rate* is set every tick by maximizing
v1's current shadow price for it against its own operating cost.

Because the reformer's output is both free and higher-quality than the
filler, the blend always uses all of it, so its shadow price holds at
exactly $40 (the cost of the filler it displaces) from tick 1 — watch
that column stay pinned while the feed setpoint and production rate
climb toward the hand-derived optimum (u\*=73.30, rate\*=90.0; see
DESIGN.md section 11.3 for the derivation).

Starting the same reformer at its true minimum instead of a warm start
exposes a real, permanent deadlock, not a slow recovery: an infeasible
blend gives a price of exactly `$0`, and `$0` means zero incentive to
ever produce more. `scripts/run_coordination_coldstart_demo.jl` shows
the fix — `ComponentSource`'s `floor_price`, a minimum price used *only*
while infeasible (never overriding a real shadow price), just large
enough to bootstrap production back into feasibility, at which point
the real $40 shadow price takes back over. Both the raw deadlock and
the fix are covered in `test/test_coordination.jl`, and the full story
(including why too-low a floor price still deadlocks) is in DESIGN.md
section 11.5.

## Connecting v3 to v2

`scripts/run_coordination_schedule_demo.jl` extends the same mechanism
to v2: `TankSource` maps a `Tank` to a `DynamicUnit`'s output, and each
real-time tick *is* one v2 period. With both tanks wide open (only the
receipt/inventory-balance mechanics exercised), it reproduces the v1
demo's own numbers exactly — same $40 shadow price, same u\*=73.30,
rate\*=90.0 — confirming the Tank-based path is mechanically equivalent
to v1's flat-availability one for the same underlying economics.

What v1's coordination *can't* do at all: a tank genuinely carries
inventory across ticks (v1's coordination has no memory between ticks —
it re-derives "availability" from scratch every time). The demo's second
part shows a unit producing faster than demand draws down, building a
real surplus (`20`/tick) with no v1 analogue. The cold-start deadlock and
its `floor_price` fix (section 11.5) apply identically here — see
`TankSource`'s own `floor_price`. Full derivation and scope cuts (a tank
is either fully unit-sourced or fully static, no mixing with a fixed
receipt schedule) are in DESIGN.md section 11.6.

## Layout

```
.github/workflows/
  ci.yml                # runs the full test suite on push/PR, Julia 1.9 + latest (section 12)
src/
  DynMIRTO.jl           # module entry point
  Types.jl              # Component, Product, PropertySpec, BlendRecipe (v1)
  BlendIndices.jl       # pluggable blending-index registry (RON, RVP, ...)
  Optimizer.jl          # builds & solves the v1 (single-period) JuMP/HiGHS LP
  Scheduling.jl         # Tank, ScheduledProduct; builds & solves the v2 (multi-period) LP
  DynamicOptimization.jl # DynamicUnit; Wiener-Hammerstein dynamics, reconciliation, successive-LP (v3)
  Coordination.jl       # connects v3 units to v1's blend LP / v2's tanks via live shadow prices (section 11)
  ScenarioIO.jl         # load a v1 scenario, or a v2 schedule, from JSON
  Report.jl             # pretty-print a solved recipe, schedule, or real-time run
scripts/
  run_scenario.jl            # CLI: run a v1 scenario file end to end
  run_schedule.jl            # CLI: run a v2 schedule file end to end
  run_dynamic_demo.jl        # CLI: run the v3 closed-loop demo end to end
  run_coordination_demo.jl   # CLI: run the v1<->v3 coordinated demo end to end
  run_coordination_coldstart_demo.jl # CLI: same, but from a true cold start (shows the floor_price fix)
  run_coordination_schedule_demo.jl  # CLI: run the v2<->v3 coordinated demo (cross-validation + tank accumulation)
notebooks/
  blend_explorer.jl            # interactive Pluto notebook (v1), linked to src/ (see above)
  blend_explorer_standalone.jl # same, but self-contained for zero-setup/phone use
  schedule_explorer.jl         # interactive Pluto notebook (v2), linked to src/
  coordination_explorer.jl     # interactive Pluto notebook (v1 <-> v3 coordination), linked to src/
test/
  runtests.jl
data/examples/
  regular_unleaded.json  # v1: single product, 4 components
  multi_grade.json       # v1: two products sharing a component pool
  schedule_example.json  # v2: 4 tanks, scheduled receipts, 4-period horizon
```

## Status

Early prototype. The default RON/MON blending-index exponents in
`BlendIndices.jl` are illustrative placeholders, not calibrated refinery
correlations — see the comments there before using this for anything
beyond demonstrating the mechanism. v3's scope cuts relative to the real
GDOT technology are listed in DESIGN.md section 10.2 (single-input/
single-output units, first-order dynamics only, simplified two-source
reconciliation, and more). The v1↔v3 coordination layer's cold-start
deadlock has a fix (`floor_price` — DESIGN.md section 11.5), but picking
a good floor price is still a per-scenario judgment call, and it only
optimizes a sourced component's volume, not its quality (section 11.4).
The same coordination mechanism now also connects to v2 (tanks/
scheduling — section 11.6), carrying over the same scope cuts, plus one
more of its own: a tank is either fully unit-sourced or fully static, no
mixing a unit-sourced receipt with a fixed schedule on the same tank.
