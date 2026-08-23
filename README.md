# DynMIRTO

A Julia blend-optimization engine, inspired by AspenTech GDOT (Gasoline
Distribution/blend Optimization Tool). Given blendstock components (cost,
availability, quality properties) and product specs (demand, quality
ranges), it computes the minimum-cost blend recipe that meets every spec.

v1 is single-period recipe optimization; v2 adds multi-period scheduling
on top — tanks with inventory that evolves via scheduled receipts and
blending draws over a horizon. Both are LPs solved with
[JuMP.jl](https://jump.dev) + [HiGHS](https://highs.dev). See
[`DESIGN.md`](DESIGN.md) for the full design, including how non-linear
blending properties (RON, RVP, ...) are handled via blending indices, and
v2's key simplification (fixed-quality tanks — see DESIGN.md section 9.1
for why, and what's still out of scope: real in-tank quality mixing,
procurement optimization).

## Quickstart

```sh
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. test/runtests.jl

# v1: single-period blend optimization
julia --project=. scripts/run_scenario.jl data/examples/regular_unleaded.json
julia --project=. scripts/run_scenario.jl data/examples/multi_grade.json

# v2: multi-period scheduling (tanks, receipts, demand over a horizon)
julia --project=. scripts/run_schedule.jl data/examples/schedule_example.json
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

## Layout

```
src/
  DynMIRTO.jl     # module entry point
  Types.jl        # Component, Product, PropertySpec, BlendRecipe (v1)
  BlendIndices.jl # pluggable blending-index registry (RON, RVP, ...)
  Optimizer.jl    # builds & solves the v1 (single-period) JuMP/HiGHS LP
  Scheduling.jl   # Tank, ScheduledProduct; builds & solves the v2 (multi-period) LP
  ScenarioIO.jl   # load a v1 scenario, or a v2 schedule, from JSON
  Report.jl       # pretty-print a solved recipe or schedule
scripts/
  run_scenario.jl # CLI: run a v1 scenario file end to end
  run_schedule.jl # CLI: run a v2 schedule file end to end
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
beyond demonstrating the mechanism.
