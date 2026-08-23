# DynMIRTO

A Julia blend-optimization engine, inspired by AspenTech GDOT (Gasoline
Distribution/blend Optimization Tool). Given blendstock components (cost,
availability, quality properties) and product specs (demand, quality
ranges), it computes the minimum-cost blend recipe that meets every spec.

v1 scope is single-period recipe optimization (an LP solved with
[JuMP.jl](https://jump.dev) + [HiGHS](https://highs.dev)). See
[`DESIGN.md`](DESIGN.md) for the full design, including how non-linear
blending properties (RON, RVP, ...) are handled via blending indices, and
what's deliberately out of scope for v1 (multi-period scheduling, tank
dynamics).

## Quickstart

```sh
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. test/runtests.jl
julia --project=. scripts/run_scenario.jl data/examples/regular_unleaded.json
julia --project=. scripts/run_scenario.jl data/examples/multi_grade.json
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

## Layout

```
src/
  DynMIRTO.jl     # module entry point
  Types.jl        # Component, Product, PropertySpec, BlendRecipe
  BlendIndices.jl # pluggable blending-index registry (RON, RVP, ...)
  Optimizer.jl    # builds & solves the JuMP/HiGHS LP
  ScenarioIO.jl   # load a scenario from JSON
  Report.jl       # pretty-print a solved recipe
scripts/
  run_scenario.jl # CLI: run a scenario file end to end
notebooks/
  blend_explorer.jl # interactive Pluto notebook (see above)
test/
  runtests.jl
data/examples/
  regular_unleaded.json  # single product, 4 components
  multi_grade.json       # two products sharing a component pool
```

## Status

Early prototype. The default RON/MON blending-index exponents in
`BlendIndices.jl` are illustrative placeholders, not calibrated refinery
correlations — see the comments there before using this for anything
beyond demonstrating the mechanism.
