# Julia Blend Optimizer — Design Doc

Scope: core blend-optimization engine, inspired by AspenTech GDOT (Gasoline
Distribution/blend Optimization Tool). Single-period recipe optimization first;
scheduling/multi-period is out of scope for v1.

## 1. Problem being solved

Given a set of blendstocks (components) available in known quantities, with
known quality properties (RON, MON, RVP, sulfur, benzene, aromatics, olefins,
density, cost, ...), compute the volume fractions of each component in a
finished-product blend that:

- minimizes blend cost (or maximizes value/margin),
- meets every product quality specification (min/max per property),
- respects component availability (inventory) and any min/max usage ratio
  per component,
- satisfies mass/volume balance (fractions sum to 1, or multi-blend-header
  volumes balance against demand).

This is the core LP/MIP under GDOT's blending engine. GDOT's real value-add
over naive LP is handling **non-linear blending properties** (RON, MON, RVP,
and some others don't blend linearly by volume) via blending indices —
component values are converted into an index domain where they *do* blend
linearly, optimized there, then converted back for reporting/spec checking.

## 2. Domain model

```
Component
  id::String
  name::String
  cost::Float64                 # $ per volume unit
  available::Float64            # max volume available this period
  min_available::Float64        # must-use minimum (e.g. must clear tank), default 0
  properties::Dict{Symbol,Float64}   # e.g. :RON => 92.3, :RVP => 8.1, :sulfur_ppm => 12.0

Product  (a blend "header"/spec)
  id::String
  name::String
  demand::Float64                # target volume to produce
  price::Float64                 # $ per volume unit (for margin objective)
  specs::Dict{Symbol,PropertySpec}   # per-property min/max

PropertySpec
  min::Union{Float64,Nothing}
  max::Union{Float64,Nothing}
  blend_rule::BlendRule           # :linear or :index

BlendRecipe (solver output)
  product_id::String
  fractions::Dict{String,Float64}   # component_id => volume fraction
  volumes::Dict{String,Float64}     # component_id => absolute volume
  resulting_properties::Dict{Symbol,Float64}
  cost::Float64
```

## 3. Linear vs. index blending

Most properties (sulfur, density, benzene, aromatics, olefins, oxygen) blend
linearly by volume fraction — a straight weighted average is physically
correct. A few (RON, MON, RVP, and to a lesser extent viscosity/cetane in
diesel) do not: mixing two components does not give a volume-weighted average
of octane. Industry practice (and what GDOT does) is to convert the raw
property into a **blending index** via a published/fitted correlation, blend
the index linearly, then invert the correlation to get back the blended
property for spec-checking and reporting.

v1 will support:
- `:linear` rule — used directly in the LP.
- `:index` rule with a pluggable `index_fn` / `inverse_fn` pair per property
  (e.g. the standard RON blending index approximation). Component properties
  are pre-converted to index space before the LP is built; the optimizer
  never needs to see the nonlinear form. This keeps the core model a pure LP
  (fast, robust, MILP-extensible) instead of requiring NLP/nonconvex solvers.

This is a deliberate simplification vs. real GDOT (which supports
interaction-corrected, non-additive blending via more complex correlations),
but matches how most LP-based blend optimizers approximate the problem, and
is easy to extend later without changing the architecture (index_fn is just
swapped per property).

## 4. Optimization formulation (single product, LP)

Decision variables: `x[c]` = volume of component `c` used, for `c` in
components eligible for this product.

```
minimize  sum(cost[c] * x[c] for c in C)

subject to:
  sum(x[c] for c in C) == demand                      # volume balance
  min_available[c] <= x[c] <= available[c]             # inventory bounds
  for each property p with a spec:
      lo[p] * sum(x[c]) <= sum(val[c,p] * x[c]) <= hi[p] * sum(x[c])
  x[c] >= 0
```

The property constraints are linear because `val[c,p]` is pre-computed
(index space if needed) and demand is fixed, so `lo[p]*demand` etc. are
constants — this is a straightforward LP.

Multi-product (multiple blend headers competing for the same shared
component pool) extends this to a joint LP: `x[c,product]` variables, with
a per-component capacity constraint `sum(x[c,*]) <= available[c]` instead of
a per-product one. v1 will support this directly since it's a small
extension and is the realistic use case (several grades pulling from a
shared tank farm).

## 5. Package choices

- **JuMP.jl** — the model layer; keeps solver choice swappable.
- **HiGHS.jl** — default LP/MILP solver (open-source, fast, no license
  needed — matters since GDOT itself is commercial and we want something
  runnable by anyone).
- **DataFrames.jl** — loading component/product tables from CSV for
  scenario input, and presenting results.
- **JSON3.jl** — scenario definitions and results as JSON, for
  interop/testing without a spreadsheet dependency.
- **Test** (stdlib) — unit tests per module.

No web UI in v1; a CLI entry point (`scripts/run_scenario.jl scenario.json`)
that prints a recipe report is enough to validate the engine end to end.

## 6. Module layout

```
julia-blend-optimizer/
  Project.toml
  src/
    JuliaBlendOptimizer.jl   # module entry, exports
    Types.jl                 # Component, Product, PropertySpec, BlendRecipe
    BlendIndices.jl          # index_fn/inverse_fn registry (RON, RVP, ...)
    ScenarioIO.jl            # load/save scenarios (CSV + JSON)
    Optimizer.jl             # builds & solves the JuMP model
    Report.jl                # pretty-print / export a solved recipe
  scripts/
    run_scenario.jl
  test/
    runtests.jl
    test_blend_indices.jl
    test_optimizer.jl
  data/
    examples/
      regular_unleaded.json  # toy scenario: 4 components, 1 product, RON+RVP+sulfur specs
      multi_grade.json       # toy scenario: shared tank farm, 2 products
  README.md
  DESIGN.md
```

## 7. MVP acceptance criteria (v1)

1. Load a scenario (components + products + specs) from JSON.
2. Solve single-product and multi-product LPs via HiGHS.
3. Report: recipe fractions/volumes, resulting property values (post
   inverse-index conversion), total cost, and which spec constraints are
   binding (shadow-price style — useful for "why can't I use more of X"
   questions, a real GDOT-user need).
4. Infeasibility is reported with which constraints conflict, not just a
   solver error code.
5. Unit tests cover: linear blending correctness, at least one index-based
   property (RON) round-tripping correctly, a known-optimal toy scenario,
   and an intentionally infeasible scenario.

## 8. Roadmap beyond v1 (not building yet)

- Multi-period scheduling (tank inventories evolving over time, receipts/
  shipments) — this is GDOT's other major half and a much bigger model
  (time-indexed LP/MILP, tank blending-in-transit dynamics).
- Nonlinear/interaction blending corrections beyond simple indices.
- A small web front-end for scenario editing (could reuse this session's
  Artifact tooling for a demo UI once the engine is solid).
- Sensitivity/what-if reporting, batch scenario comparison.
