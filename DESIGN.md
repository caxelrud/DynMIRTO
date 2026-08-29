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

## 10. v3: real-time dynamic optimization

v1 and v2 are both **one-shot LPs**: given a snapshot (or a fixed
schedule of snapshots), solve once. Neither has anything analogous to
what AspenTech's actual GDOT does at its core — this section corrects
course after checking primary sources instead of guessing.

GDOT ("Generic Dynamic Optimization Technology") came from Apex
Optimisation, acquired by AspenTech in 2018; despite this project's
original working assumption, the name has nothing to do with gasoline
specifically. Its inventor, Henrik Terndrup, holds the patent describing
the actual mechanism:
[US 2010/0274368 A1, "Method and system for dynamic optimisation of
industrial processes"](https://patents.google.com/patent/US20100274368A1)
(assignee now AspenTech Corporation). v3 is a deliberately scoped-down
but mechanistically faithful implementation of that patent's core idea,
not the gasoline-specific v1/v2 model.

### 10.1 The real mechanism, per the patent

1. **Wiener-Hammerstein unit models**: each unit's output is a nonlinear
   *steady-state* function of its input, `z∞ = f(u∞)`, reached via
   *linear* dynamics — the patent writes this as `h = f(z∞)·g(s)`. This
   lets the optimizer predict where a unit will *end up* while it is
   still mid-transient, instead of waiting for steady state (what
   classic real-time optimization, RTO, requires).
2. **Successive linear programming (SLP)**: the true objective is
   nonlinear (because `f` is), so it is solved as a *sequence of linear
   static optimization problems* via repeated linearization around the
   current operating point — not a single LP, and not a full nonlinear
   solve either.
3. **Real-time data reconciliation**: a module continuously estimates
   the true state by minimizing weighted deviations between the dynamic
   model's prediction and noisy measurements, so the optimizer always
   works from a clean, consistent estimate rather than raw sensor noise.
4. **One shared model, run continuously**: the same model serves both
   reconciliation and profit-maximizing optimization, re-solved on every
   control cycle as new measurements arrive — a genuine closed loop,
   which is what "real-time" and "dynamic" mean here.

### 10.2 Scope cuts (documented, not hidden)

- **Single-input/single-output units, first-order dynamics only.** The
  patent's model class is general LTI dynamics and multivariable units;
  v3 uses one manipulated variable and one first-order lag per unit.
  This keeps the dynamic update exact and closed-form
  (`z + (y-z)·exp(-dt/τ)`) instead of needing a general linear
  state-space solver.
- **Reconciliation is a two-source weighted average** (model prediction
  vs. measurement) per unit, closed-form. Real data reconciliation
  spans many redundant, correlated measurements and mass/energy balance
  constraints across a whole plant — a much bigger estimation problem
  (typically nonlinear least squares over a plant-wide model).
- **SLP uses a shrinking trust region with true-objective backtracking**:
  a candidate step is accepted only if it actually improves the true
  (non-linearized) objective; otherwise the trust region shrinks and the
  step is retried from the same point. This is a standard, defensible
  SLP safeguard, but a step's *constraints* are only checked in
  linearized form each iteration, not re-verified against the true
  nonlinear constraint — acceptable given steps are kept small by the
  trust region, but not a guarantee the real constraint always holds.
- **Rate-of-change limits vs. optimizer trust region are kept separate
  on purpose**: `DynamicUnit.max_step` is a *real* limit on how fast the
  applied input may move per control tick (like an APC output ramp
  limit); the SLP's internal trust region is a *numerical* device for
  convergence, initialized from `max_step` but free to shrink further
  within one solve. Conflating the two would either make the optimizer
  converge too slowly or let it plan targets faster than the plant could
  actually be moved toward.
- **Scenarios are Julia code, not JSON.** Nonlinear gain functions aren't
  naturally JSON-serializable without a small expression DSL; v3
  scenarios are plain Julia closures instead, consistent with how the
  gain-function-heavy `BlendIndices.jl` registry already works.

### 10.3 Domain model

```
DynamicUnit
  id::String
  tau::Float64                  # time constant of the first-order lag
  steady_state_gain::Function   # f(u) -> z∞, nonlinear, smooth
  u_min::Float64, u_max::Float64
  max_step::Float64             # real rate-of-change limit per tick

RealTimeTick   (one tick of a solved closed loop)
  tick::Int
  y_true, y_measured, y_hat::Dict{String,Float64}   # hidden / noisy / reconciled
  u_applied, u_target::Dict{String,Float64}
```

`econ(u, z)` and `constraints(model, u, z)` are user-supplied callbacks
(plain Julia, not stored on `DynamicUnit`) — `econ` must work identically
whether `u`/`z` hold JuMP expressions (inside the LP) or plain `Float64`s
(when evaluating the true objective for trust-region backtracking).

### 10.4 The closed loop, per tick

1. The (simulated) true plant evolves one step under the *previously
   applied* input (`step_state`).
2. A noisy measurement is taken.
3. Reconciliation blends the model's one-step prediction with that
   measurement (`reconcile`).
4. `successive_lp_optimize` re-solves for the steady-state economic
   target `u_target` from the current applied input.
5. The applied input moves toward `u_target` by at most `max_step` (the
   real rate limit) — not necessarily reaching it in one tick.

### 10.5 Acceptance criteria (v3)

1. `step_state` matches the closed-form exponential solution of the
   first-order lag exactly (not just approximately) for constant input
   over an interval.
2. `reconcile` recovers the measurement exactly when weighted entirely
   on measurement, and the model's prediction exactly when weighted
   entirely on the model — the two boundary cases of the closed-form
   weighted average.
3. `successive_lp_optimize` on a single concave quadratic gain converges
   to the exact calculus-derived unconstrained optimum.
4. `successive_lp_optimize` on two units sharing a binding linear budget
   constraint converges to the exact Lagrangian (equal-marginal-value)
   constrained optimum, hand-derived.
5. `run_real_time_loop` (no noise) drives the applied inputs toward that
   same constrained optimum over ticks, subject to the rate limit.

### 10.6 Multivariable units

The first version of this module only supported one input and one
output per unit — a real simplification even relative to v3's own
stated scope (section 10.2 already flagged general LTI/multivariable
units as cut). This section extends `DynamicUnit` to the general case:
one or more named inputs, one or more named outputs, related by a
single nonlinear map `F: inputs -> outputs` (still reached via
independent first-order dynamics per output — that part of the original
scope cut stands).

**What changes:**
- `steady_state_gain` becomes `F(u::Dict{String,Float64}) -> Dict{String,Float64}`
  instead of a scalar function — a unit can have inputs that each affect
  *multiple* outputs (real cross-coupling, e.g. a distillation column
  where both reflux and reboiler duty affect both top and bottoms
  purity).
- `tau`, `u_min`, `u_max`, `max_step` become `Dict`s keyed by output id
  (for `tau`) or input id (for the rest), since different
  inputs/outputs of the same unit can have different ranges, rate
  limits, and response speeds.
- Linearizing `F` now needs its full **Jacobian** (every output's
  partial derivative with respect to every input), computed by finite
  differences one input at a time — a single derivative is no longer
  enough once an output can depend on more than one input.
- Every `Dict` passed to `econ`/`constraints`, and every field of
  `RealTimeTick`, is now keyed by `(unit_id, variable_id)` tuples
  (matching the pattern v2's `Scheduling.jl` already uses for
  `receipts`/`tank_levels`) instead of plain `unit_id` strings — this
  is a breaking change from the original single-input/single-output
  API, applied uniformly rather than special-cased for units that
  happen to have exactly one input and one output.
- A convenience constructor, `DynamicUnit(id, tau, gain; ...)`, keeps
  the simple single-input/single-output case easy to write — it just
  wraps the scalar function into the `Dict`-based interface with a
  fixed input name `"u"` and output name `"y"`.

**Why this matters, concretely**: a Jacobian that only captured each
output's "own" partial derivative (ignoring cross-terms) would still
run without erroring, but would converge to the *wrong* optimum on any
unit with real coupling — silently. `test_dynamic_optimization.jl`
includes a coupled two-input/two-output case (reflux/duty affecting
both top and bottoms purity) with a hand-derived optimum specifically
chosen so that dropping the off-diagonal Jacobian terms gives a
different, wrong answer (45, 45) instead of the correct one
(51, 53.33) — a test that would pass with a naive diagonal-only
Jacobian is not actually testing the multivariable case.

**Still not modeled**: interaction *dynamics* (e.g. one input's effect
on an output arriving with a different time delay/lag shape than
another input's effect on that same output — real transfer-function
matrices can have off-diagonal dynamics, not just off-diagonal
steady-state gains); the reconciliation step is still a per-output
two-source weighted average, not a joint estimate across a unit's
correlated outputs.

## 11. Connecting v3 to v1

Until now, v1, v2, and v3 were three independent demos that happened to
share a repo, not a coordinated system. This is the actual "missing
link" GDOT's own materials describe: aligning real-time unit-level
economics (v3) with the blend/scheduling layer's needs (v1), as a
genuine bidirectional loop, not just piping one layer's output into the
next. v2 (tanks/scheduling) is not connected yet — see section 11.6.

### 11.1 Architecture

Each tick (`src/Coordination.jl`, `run_coordinated_loop`):

1. Every **sourced** component's `available` is set from its
   `DynamicUnit`'s current reconciled output (`y_hat`) — v3 → v1.
2. `optimize_blend` solves the live blend LP.
3. Its **shadow price** for that component's availability constraint
   (added to v1 for exactly this purpose — see 11.2) becomes the live
   "price" term in a fresh `econ` closure for that unit's
   `successive_lp_optimize` call, replacing what was a hardcoded
   constant in the standalone v3 examples — v1 → v3.
4. The unit's applied input ramps toward that tick's target under its
   own rate limit, and its dynamics/reconciliation advance one step.

A component can still be `static` (untouched by any unit, exactly as in
plain v1 usage) — only components explicitly given a `ComponentSource`
are put under real-time control.

### 11.2 Shadow prices, added to v1

`optimize_blend` now returns `component_shadow_prices` (on
`OptimizationResult`) and `spec_shadow_prices` (on `BlendRecipe`),
computed from `JuMP.shadow_price` on the constraints. This also closes
a gap in v1's own original acceptance criteria (section 7, point 3),
which wanted "which spec constraints are binding (shadow-price style)"
and only ever got a binding/violated flag, not a number.

Both are scaled to read as **positive dollars per one unit of
loosening the constraint** — "value of one more unit of availability"
for a component, "cost of tightening by one unit" for a spec bound —
regardless of whether the underlying JuMP constraint is `<=` or `>=`.
This is `-shadow_price(constraint)` in both cases, and for spec bounds
additionally scaled by the product's `demand` (the constraint's raw RHS
is `spec_value * demand`, so its raw dual is "per unit of demand", not
"per unit of spec value"). None of this was assumed: three small
hand-derived LPs (an availability cap, a max-type spec, a min-type
spec) were solved directly in JuMP first to pin down the sign and
scaling before writing the real code — see `test_optimizer.jl`'s
"shadow prices match hand-derived LP duality" test, which reproduces
all three.

### 11.3 The demo scenario, hand-derived

`scripts/run_coordination_demo.jl` and the matching test: a blend
(demand 100/tick, spec RON ≥ 90) draws from a static filler (FILL: $40,
RON 80 — below spec alone) and a reformer-sourced component (REF: $0
blend-side cost, RON 95 — above spec alone), whose volume is set by a
`DynamicUnit` maximizing `price * rate(u) - 30 * u` where
`rate(u) = 150*(1-e^{-u/80})`.

Because REF is both free and higher-quality than FILL, the blend always
uses *all* available REF (up to full demand) — so as long as
`0 < rate(u) < 100`, REF's shadow price is pinned at exactly $40 (the
cost of the FILL it displaces), independent of the octane spec. That
turns the reformer's problem into the same diminishing-returns
allocation already solved (and verified) in v3's own test suite, just
with a live price instead of a constant:

```
maximize  40 * 150*(1-e^{-u/80}) - 30*u
d/du = 0  =>  e^{-u/80} = 0.4  =>  u* = -80*ln(0.4) = 73.297...
rate* = 150*(1-0.4) = 90                      (consistent: 90 < 100)
```

`test_coordination.jl` checks the shadow price stays at exactly $40.0
on *every* tick (not just at the end) and that the applied input and
reconciled output converge to `u* ≈ 73.3`, `rate* ≈ 90`.

### 11.4 Scope cut: quality stays static

A unit here only produces *volume* — a component's quality properties
(RON, etc.) are still fixed numbers, as in plain v1. A quality-flexible
unit (where a spec's own shadow price, not just an availability shadow
price, feeds back into the unit's objective) is a natural next step but
needs a defensible way to translate "the blend spec is worth $X more
per unit of average quality" into "this component's own quality is
worth $Y more per unit" — e.g. weighting by the component's blend
fraction — which wasn't verified carefully enough here to ship.

### 11.5 A real limitation, found by running it: cold-start deadlock

Starting the reformer at `u=0` (its actual minimum, not the demo's
warm-started `u=50`) does not recover on its own — it stays pinned at
`u=0` forever. This was discovered by running exactly that scenario in
`test_coordination.jl`, not assumed away: with no REF available, the
blend is infeasible, `component_shadow_prices` comes back empty, and
every sourced unit sees a price of exactly `0.0` that tick. At price
zero, a unit's economic objective is strictly "produce nothing" (any
`u > 0` only adds operating cost for zero revenue) — a self-reinforcing
deadlock with no gradient pointing out of it, not a slow transient. The
"cold start with no floor_price" test verifies this precise behavior
(stays at exactly `u=0`, every tick infeasible) rather than a false
claim that it recovers.

This is a known real issue for dual-value/shadow-price-driven
coordination generally, not specific to this toy scenario. **Fixed**:
`ComponentSource` now carries a `floor_price` (default `0.0`, preserving
the original behavior above when not set), used as the unit's price
signal *only on ticks where the blend is infeasible* — a minimum
exploration incentive, never overriding a real shadow price. It doesn't
need to be the true equilibrium price, only large enough that the
resulting production crosses back into feasibility; `scripts/run_coordination_coldstart_demo.jl`
and its matching test use `floor_price=35.0` (not the true $40) to show
exactly that handoff: the reformer ramps under the floor price alone
while infeasible, crosses the ~66.67 threshold needed for the blend to
solve again, and the real $40 shadow price immediately takes back over
and continues on to the true optimum. Choosing a good floor price is
still a per-scenario judgment call (too low never escapes the deadlock,
as the same math shows for `floor_price=20` or `28.8`); an explicit
bootstrap/warm-up mode is a further alternative, not built.

### 11.6 Not yet connected: v2

This section only connects v3 to v1 (single-period blending). Extending
it to v2 (multi-period scheduling with tanks) is the natural next step
— a unit's output would feed a `Tank`'s receipts instead of a
`Component`'s flat `available`, and the shadow price would come from
v2's per-period, per-tank capacity constraints instead of v1's
per-component availability constraint.
