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
