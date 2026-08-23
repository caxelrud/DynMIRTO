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

## 8. Roadmap beyond v1

- ~~Multi-period scheduling~~ — see v2 below.
- Nonlinear/interaction blending corrections beyond simple indices.
- A small web front-end for scenario editing (could reuse this session's
  Artifact tooling for a demo UI once the engine is solid).
- Sensitivity/what-if reporting, batch scenario comparison.
- Procurement optimization (v2 treats receipts as fixed input; deciding
  *when/how much* to receive, under contract/cost terms, is a natural
  follow-on once v2 is solid).

## 9. v2: Multi-period scheduling

This is GDOT's other major half: instead of one snapshot in time, plan a
blend schedule across a horizon of periods (e.g. days), where component
availability comes from **tanks** whose inventory evolves period to period
via scheduled **receipts** (deliveries) and consumption (blending draws).

### 9.1 Key simplification: fixed-quality tanks

Real terminal/refinery scheduling has to handle a tank's quality *changing*
as new receipts mix with existing inventory (a bilinear, non-convex
problem — the hard part of real GDOT-class scheduling, usually handled
with MINLP or sequential-LP heuristics). v2 deliberately sidesteps this:
**each tank holds one component whose quality properties are fixed** (set
once on the `Component`, same as v1); receipts change *how much* is in the
tank, never *what quality* it is. This keeps the whole model a clean LP —
same solver, same tractability as v1 — while still answering the real
scheduling question ("given tank capacity and a receipts calendar, what's
the optimal per-period blend plan to meet demand over time without running
a tank dry or overflowing it"). Tank-quality-mixing dynamics are flagged as
future work, not built now.

A second simplification: **one tank per component** (no tank-selection
sub-problem when several tanks could hold the same stock). And receipts are
**fixed input data**, not a decision — procurement timing/quantity
optimization is future work (see roadmap).

### 9.2 Domain model additions

```
Tank
  id::String
  component_id::String     # which Component's quality this tank holds
  capacity_min::Float64     # e.g. minimum heel that must stay in the tank
  capacity_max::Float64
  initial_inventory::Float64

ScheduledProduct   (like Product, but demand varies by period)
  id, name, price, specs, eligible_components   # same as Product
  demand::Dict{Int,Float64}   # period => volume required (periods w/o an
                               # entry have zero demand)

receipts::Dict{Tuple{String,Int},Float64}   # (tank_id, period) => volume
                                              # delivered at the start of
                                              # that period
```

`Component.available`/`min_available` are **ignored** in the scheduling
model — a tank's dynamic inventory governs availability instead. This is
called out in the code, not silently overloaded.

### 9.3 Optimization formulation

Decision variables: `x[c,p,t]` (component volume used, per product, per
period — same as v1's `x[c,p]` with a time index) and `inv[tank,t]` for
`t = 1..T` (`inv[tank,0]` is fixed data: `initial_inventory`).

```
minimize  sum(cost[c] * x[c,p,t] for c,p,t)

subject to, for each period t = 1..T:
  sum(x[c,p,t] for c) == demand[p,t]                for each product p
  inv[tank,t] == inv[tank,t-1] + receipts[tank,t]
                - sum(x[c,p,t] for p, where c == tank.component_id)
  capacity_min[tank] <= inv[tank,t] <= capacity_max[tank]
  for each property spec (same index-space handling as v1):
      lo*demand[p,t] <= sum(val[c,p]*x[c,p,t]) <= hi*demand[p,t]
  x[c,p,t] >= 0
```

This is the same LP structure as v1, just replicated per period and linked
across periods by the inventory balance equation — still a pure LP (no
integer variables, no bilinear terms), solvable directly by HiGHS.

### 9.4 Module additions

```
src/
  Scheduling.jl   # Tank, ScheduledProduct, optimize_schedule, prevalidation
scripts/
  run_schedule.jl # CLI: run a multi-period scenario end to end
data/examples/
  schedule_example.json   # small horizon, 2 tanks, receipts, 1 product
test/
  test_scheduling.jl
```

`ScenarioIO.jl` gains a `load_schedule(path)` loading a JSON shape parallel
to the v1 scenario format (components, tanks, receipts, products-with-
per-period-demand, horizon length).

### 9.5 Acceptance criteria (v2)

1. A tank that would run below `capacity_min` or above `capacity_max` in
   some period is caught and reported by name/period, not just a bare
   solver infeasibility code.
2. A hand-verifiable 2-period test: a tank starts with just enough
   inventory for period 1, a receipt arrives before period 2, and the
   optimal schedule matches a hand calculation.
3. A capacity-binding test: demand forces a tank to draw down to its
   `capacity_min` in some period (the binding constraint is visible in the
   result).
4. Reuses v1's `Component`/`PropertySpec`/blending-index machinery
   unchanged — no duplication of the blend math, only the new tank/time
   layer is new code.
