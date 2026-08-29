# DynMIRTO

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
LP. See [`DESIGN.md`](DESIGN.md) for the full design of each layer,
including v1's blending-index handling for non-linear properties (RON,
RVP, ...), v2's key simplification (fixed-quality tanks — section 9.1),
and v3's scope cuts relative to the real technology (section 10.2).

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

## Real-time dynamic optimization (v3)

`scripts/run_dynamic_demo.jl` runs a small closed loop: two process
units, each with a concave (diminishing-returns) steady-state yield
curve reached via first-order dynamics, sharing a binding utility
budget. Every tick it re-solves for the economic optimum from a noisy,
reconciled state estimate — watch `u_target` lock onto the analytical
optimum immediately (it only depends on the economics) while
`u_applied` ramps there under each unit's real rate limit, and `y_hat`
climbs toward the true steady-state output as the dynamics settle.

Unlike v1/v2, v3 scenarios are defined in Julia code, not JSON — see
DESIGN.md section 10.2 for why. There's no notebook for v3 yet.

## Layout

```
src/
  DynMIRTO.jl           # module entry point
  Types.jl              # Component, Product, PropertySpec, BlendRecipe (v1)
  BlendIndices.jl       # pluggable blending-index registry (RON, RVP, ...)
  Optimizer.jl          # builds & solves the v1 (single-period) JuMP/HiGHS LP
  Scheduling.jl         # Tank, ScheduledProduct; builds & solves the v2 (multi-period) LP
  DynamicOptimization.jl # DynamicUnit; Wiener-Hammerstein dynamics, reconciliation, successive-LP (v3)
  ScenarioIO.jl         # load a v1 scenario, or a v2 schedule, from JSON
  Report.jl             # pretty-print a solved recipe, schedule, or real-time run
scripts/
  run_scenario.jl     # CLI: run a v1 scenario file end to end
  run_schedule.jl     # CLI: run a v2 schedule file end to end
  run_dynamic_demo.jl # CLI: run the v3 closed-loop demo end to end
notebooks/
  blend_explorer.jl            # interactive Pluto notebook (v1), linked to src/ (see above)
  blend_explorer_standalone.jl # same, but self-contained for zero-setup/phone use
  schedule_explorer.jl         # interactive Pluto notebook (v2), linked to src/
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
reconciliation, and more).
