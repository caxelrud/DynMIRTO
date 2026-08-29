"""
Connects v3 (real-time dynamic optimization) to v1 (blend optimization)
and, since this module's extension to v2, to v2 (tank/multi-period
scheduling) as well: the "missing link" GDOT's patent and press
materials describe -- a planning LP and v3's unit-level real-time
optimizer run as one coordinated loop instead of independent demos that
share no data. See DESIGN.md section 11 for the full design and its
scope cuts (a unit's quality is still static, only its *volume* is
optimized in real time -- see section 11.4).

Each tick, for either coordination:
1. Every sourced component/tank's availability/receipt is set from its
   unit's current reconciled production-rate output (`y_hat`).
2. The planning LP (`optimize_blend` for v1, a single-period
   `optimize_schedule` call for v2) solves and its shadow prices are
   read off.
3. Those shadow prices become the live "price" term in a fresh `econ`
   closure for `successive_lp_optimize`, replacing what was a hardcoded
   constant in the standalone v3 examples.
4. The unit's applied input ramps toward that tick's target, and its
   dynamics/reconciliation advance one step -- same mechanics as
   `run_real_time_loop`, inlined here (via `_advance_units_one_tick`/
   `_apply_rate_limited_step`, shared by both coordination loops) because
   `econ` must be rebuilt every tick from fresh prices, not fixed for the
   whole run.
"""

using HiGHS
using Random

"""
Advance every unit's simulated true state, noisy measurement, and
reconciled estimate by one tick -- the plant-side half of a coordinated
tick, identical to `run_real_time_loop`'s own per-tick body. Returns
`(y_true, y_measured, y_hat)`, each keyed by `(unit_id, output_id)`.
"""
function _advance_units_one_tick(units::Vector{DynamicUnit}, u_applied::Dict{Tuple{String,String},Float64},
    y_true::Dict{Tuple{String,String},Float64}, y_hat::Dict{Tuple{String,String},Float64},
    dt::Float64, measurement_noise_std::Float64, rng::Random.AbstractRNG)

    y_true_new = Dict{Tuple{String,String},Float64}()
    y_hat_new = Dict{Tuple{String,String},Float64}()
    y_measured = Dict{Tuple{String,String},Float64}()
    for unit in units
        u_local = _local_slice(u_applied, unit.id, unit.input_ids)
        stepped = step_state(_local_slice(y_true, unit.id, unit.output_ids), u_local, unit, dt)
        for oid in unit.output_ids
            y_true_new[(unit.id, oid)] = stepped[oid]
            y_measured[(unit.id, oid)] = stepped[oid] + measurement_noise_std * randn(rng)
        end
        reconciled = reconcile(_local_slice(y_hat, unit.id, unit.output_ids), u_local,
            _local_slice(y_measured, unit.id, unit.output_ids), unit, dt)
        for oid in unit.output_ids
            y_hat_new[(unit.id, oid)] = reconciled[oid]
        end
    end
    return y_true_new, y_measured, y_hat_new
end

"""
Move `u_applied` toward `u_target`, clamped to each input's `max_step`
(a real rate-of-change limit) -- the input-side half of a coordinated
tick, shared by both coordination loops.
"""
function _apply_rate_limited_step(u_applied::Dict{Tuple{String,String},Float64},
    u_target::Dict{Tuple{String,String},Float64}, max_step_by_key::Dict{Tuple{String,String},Float64})
    return Dict(
        k => clamp(u_target[k], u_applied[k] - max_step_by_key[k], u_applied[k] + max_step_by_key[k])
        for k in keys(u_applied)
    )
end

"""
Maps one v1 `Component` to the v3 `DynamicUnit` whose output supplies
its available volume this tick. The component's *quality* properties
stay static (v1's usual assumption) -- only how much of it exists is
under real-time control. `component_id` must match a `Component.id` in
`sourced_component_templates`.

`floor_price` is used as the unit's price signal *only on ticks where
the blend is infeasible* (never overriding a real shadow price), as a
minimum exploration incentive -- see DESIGN.md section 11.5. It
defaults to `0.0`, the original behavior: with no floor price, an
infeasible blend gives zero incentive to produce more, which is a real,
permanent deadlock if the unit starts from a state where it's needed
but not yet available (nothing in the objective ever points a way out).
"""
struct ComponentSource
    component_id::String
    unit_id::String
    rate_output_id::String
    floor_price::Float64

    ComponentSource(component_id, unit_id, rate_output_id; floor_price=0.0) =
        new(component_id, unit_id, rate_output_id, Float64(floor_price))
end

"""
One tick of a solved coordinated run: that tick's blend result (with
shadow prices) and that tick's real-time unit state, in the same shape
`optimize_blend`/`run_real_time_loop` already return on their own.
"""
struct CoordinationTick
    tick::Int
    blend_result::OptimizationResult
    unit_tick::RealTimeTick
end

"""
    run_coordinated_loop(static_components, sourced_component_templates, sources, units,
                         operating_cost, products; n_ticks, dt=1.0, u_init=nothing, y_init=nothing,
                         measurement_noise_std=0.0, rng=Random.default_rng(), optimizer=HiGHS.Optimizer)
        -> Vector{CoordinationTick}

`static_components` are unaffected by v3 (fixed cost/availability/
quality, as in plain v1 usage). `sourced_component_templates` give the
static part (cost, quality properties) of components whose *availability*
is instead read from a unit each tick, per `sources`. `operating_cost`
is `(unit_id, input_id) => \$ per unit of that input`, used as the cost
term in each unit's real-time economic objective (its revenue term is
the live shadow price of the component it sources).

If a tick's blend is infeasible, `component_shadow_prices` for it is
empty, so every sourced unit sees a price of `0.0` that tick (no
special-casing needed) rather than crashing.
"""
function run_coordinated_loop(
    static_components::Vector{Component},
    sourced_component_templates::Vector{Component},
    sources::Vector{ComponentSource},
    units::Vector{DynamicUnit},
    operating_cost::Dict{Tuple{String,String},Float64},
    products::Vector{Product};
    n_ticks::Int, dt::Float64=1.0,
    u_init::Union{Dict{Tuple{String,String},Float64},Nothing}=nothing,
    y_init::Union{Dict{Tuple{String,String},Float64},Nothing}=nothing,
    measurement_noise_std::Float64=0.0, rng::Random.AbstractRNG=Random.default_rng(),
    optimizer=HiGHS.Optimizer)

    isempty(units) && error("run_coordinated_loop: no units given")
    unit_by_id = Dict(u.id => u for u in units)
    template_by_component = Dict(c.id => c for c in sourced_component_templates)

    for s in sources
        haskey(unit_by_id, s.unit_id) ||
            error("ComponentSource for $(s.component_id): no unit $(s.unit_id)")
        s.rate_output_id in unit_by_id[s.unit_id].output_ids ||
            error("ComponentSource for $(s.component_id): unit $(s.unit_id) has no output $(s.rate_output_id)")
        haskey(template_by_component, s.component_id) ||
            error("ComponentSource for $(s.component_id): no matching entry in sourced_component_templates")
    end

    max_step_by_key = Dict((unit.id, iid) => unit.max_step[iid] for unit in units for iid in unit.input_ids)

    u_applied = u_init === nothing ?
        Dict((unit.id, iid) => unit.u_min[iid] for unit in units for iid in unit.input_ids) : copy(u_init)

    y_true = if y_init === nothing
        result = Dict{Tuple{String,String},Float64}()
        for unit in units
            f0 = unit.steady_state_gain(_local_slice(u_applied, unit.id, unit.input_ids))
            for oid in unit.output_ids
                result[(unit.id, oid)] = f0[oid]
            end
        end
        result
    else
        copy(y_init)
    end
    y_hat = copy(y_true)

    history = CoordinationTick[]

    for tick in 1:n_ticks
        # 1. Advance the simulated plant + reconciliation (same mechanics
        #    as run_real_time_loop's own per-tick body).
        y_true, y_measured, y_hat =
            _advance_units_one_tick(units, u_applied, y_true, y_hat, dt, measurement_noise_std, rng)

        # 2. Build this tick's live components: sourced ones get their
        #    availability from the corresponding unit's current output.
        live_components = copy(static_components)
        for s in sources
            t = template_by_component[s.component_id]
            available = y_hat[(s.unit_id, s.rate_output_id)]
            push!(live_components, Component(t.id, t.name, t.cost, max(available, 0.0);
                min_available=t.min_available, properties=t.properties))
        end

        blend_result = optimize_blend(live_components, products; optimizer=optimizer)

        # 3. Translate shadow prices into a fresh econ() for this tick.
        #    On an infeasible tick there is no real shadow price to read;
        #    fall back to each source's floor_price (0.0 by default,
        #    preserving the original deadlock-prone behavior) instead of a
        #    bare 0.0, so a unit can have a real incentive to produce its
        #    way back to feasibility.
        function econ(u, z)
            total = 0.0
            for s in sources
                price = blend_result.status == :optimal ?
                    get(blend_result.component_shadow_prices, s.component_id, 0.0) : s.floor_price
                total += price * z[(s.unit_id, s.rate_output_id)]
            end
            for unit in units, iid in unit.input_ids
                total -= get(operating_cost, (unit.id, iid), 0.0) * u[(unit.id, iid)]
            end
            return total
        end
        no_extra_constraints(model, u, z) = nothing

        u_target, _status = successive_lp_optimize(units, u_applied, econ, no_extra_constraints; optimizer=optimizer)

        u_applied = _apply_rate_limited_step(u_applied, u_target, max_step_by_key)

        unit_tick = RealTimeTick(tick, y_true, y_measured, y_hat, u_applied, u_target)
        push!(history, CoordinationTick(tick, blend_result, unit_tick))
    end

    return history
end

"""
Maps one v2 `Tank` to the v3 `DynamicUnit` whose output supplies that
tank's *receipt* each tick -- the v2 analogue of `ComponentSource` (see
DESIGN.md section 11.6). `tank_id` must match a `Tank.id` in the tanks
passed to `run_coordinated_schedule_loop`.

`floor_price` behaves exactly as it does for `ComponentSource`: used as
the unit's price signal only on ticks where that tick's schedule is
infeasible, as a minimum incentive to keep producing instead of a bare
zero (see DESIGN.md section 11.5 -- the same cold-start deadlock applies
here, for the same reason: an infeasible schedule gives every sourced
tank a price of exactly `0.0`, so with no floor price a unit that starts
too low to ever reach feasibility has no gradient pointing out).
"""
struct TankSource
    tank_id::String
    unit_id::String
    rate_output_id::String
    floor_price::Float64

    TankSource(tank_id, unit_id, rate_output_id; floor_price=0.0) =
        new(tank_id, unit_id, rate_output_id, Float64(floor_price))
end

"""
One tick of a solved v2 coordinated run: that tick's single-period
schedule result (with tank shadow prices) and that tick's real-time unit
state.
"""
struct ScheduleCoordinationTick
    tick::Int
    schedule_result::ScheduleResult
    unit_tick::RealTimeTick
end

"""
    run_coordinated_schedule_loop(components, tanks, tank_sources, units,
                                  operating_cost, products; n_ticks, dt=1.0, u_init=nothing,
                                  y_init=nothing, measurement_noise_std=0.0,
                                  rng=Random.default_rng(), optimizer=HiGHS.Optimizer)
        -> Vector{ScheduleCoordinationTick}

The v2 analogue of `run_coordinated_loop`: each real-time tick *is* one
v2 period (tick `t` solves `optimize_schedule` over `periods=t:t`, so
`products`' `ScheduledProduct.demand` dicts should be keyed by tick
number, letting demand vary tick to tick same as any v2 schedule).

The key difference from v1's coordination -- which is otherwise
completely memoryless between ticks -- is that a tank genuinely
*accumulates* state across ticks: each `Tank` in `tanks` supplies its
`capacity_min`/`capacity_max`/`component_id`, but its live inventory is
carried forward from the previous tick's solved `tank_levels`, seeded
from that `Tank`'s own `initial_inventory` on tick 1. A tank named in
`tank_sources` additionally gets that tick's receipt set from its unit's
current reconciled output (`y_hat`); any other tank in `tanks` gets no
receipt at all (just draws down against its carried-over inventory) --
supplying a fixed non-unit receipt schedule on top is not supported here.

On an infeasible tick, the tank-side state (inventory) is simply frozen
rather than guessed at (this schedule was never actually realizable, so
there is nothing consistent to carry forward) -- exactly analogous to
v1's coordination reporting an empty blend on an infeasible tick. Each
sourced unit still sees a real economic signal on such a tick via
`TankSource`'s `floor_price`, same mechanism and same caveats as
`ComponentSource`'s.
"""
function run_coordinated_schedule_loop(
    components::Vector{Component},
    tanks::Vector{Tank},
    tank_sources::Vector{TankSource},
    units::Vector{DynamicUnit},
    operating_cost::Dict{Tuple{String,String},Float64},
    products::Vector{ScheduledProduct};
    n_ticks::Int, dt::Float64=1.0,
    u_init::Union{Dict{Tuple{String,String},Float64},Nothing}=nothing,
    y_init::Union{Dict{Tuple{String,String},Float64},Nothing}=nothing,
    measurement_noise_std::Float64=0.0, rng::Random.AbstractRNG=Random.default_rng(),
    optimizer=HiGHS.Optimizer)

    isempty(units) && error("run_coordinated_schedule_loop: no units given")
    isempty(tanks) && error("run_coordinated_schedule_loop: no tanks given")
    unit_by_id = Dict(u.id => u for u in units)
    tank_by_id = Dict(tank.id => tank for tank in tanks)

    for ts in tank_sources
        haskey(unit_by_id, ts.unit_id) ||
            error("TankSource for $(ts.tank_id): no unit $(ts.unit_id)")
        ts.rate_output_id in unit_by_id[ts.unit_id].output_ids ||
            error("TankSource for $(ts.tank_id): unit $(ts.unit_id) has no output $(ts.rate_output_id)")
        haskey(tank_by_id, ts.tank_id) ||
            error("TankSource for $(ts.tank_id): no matching entry in tanks")
    end

    max_step_by_key = Dict((unit.id, iid) => unit.max_step[iid] for unit in units for iid in unit.input_ids)

    u_applied = u_init === nothing ?
        Dict((unit.id, iid) => unit.u_min[iid] for unit in units for iid in unit.input_ids) : copy(u_init)

    y_true = if y_init === nothing
        result = Dict{Tuple{String,String},Float64}()
        for unit in units
            f0 = unit.steady_state_gain(_local_slice(u_applied, unit.id, unit.input_ids))
            for oid in unit.output_ids
                result[(unit.id, oid)] = f0[oid]
            end
        end
        result
    else
        copy(y_init)
    end
    y_hat = copy(y_true)

    current_level = Dict(tank.id => tank.initial_inventory for tank in tanks)

    history = ScheduleCoordinationTick[]

    for tick in 1:n_ticks
        # 1. Advance the simulated plant + reconciliation.
        y_true, y_measured, y_hat =
            _advance_units_one_tick(units, u_applied, y_true, y_hat, dt, measurement_noise_std, rng)

        # 2. Build this tick's live tanks (carried-over inventory) and this
        #    period's receipts (sourced tanks get theirs from y_hat).
        live_tanks = [Tank(tank.id, tank.component_id, tank.capacity_min, tank.capacity_max, current_level[tank.id])
                      for tank in tanks]
        receipts = Dict{Tuple{String,Int},Float64}()
        for ts in tank_sources
            receipts[(ts.tank_id, tick)] = max(y_hat[(ts.unit_id, ts.rate_output_id)], 0.0)
        end

        schedule_result = optimize_schedule(components, live_tanks, products, receipts, tick:tick; optimizer=optimizer)

        if schedule_result.status == :optimal
            for tank in tanks
                current_level[tank.id] = schedule_result.tank_levels[(tank.id, tick)]
            end
        end

        # 3. Translate tank shadow prices into a fresh econ() for this tick,
        #    same floor_price fallback as run_coordinated_loop's.
        function econ(u, z)
            total = 0.0
            for ts in tank_sources
                price = schedule_result.status == :optimal ?
                    get(schedule_result.tank_shadow_prices, (ts.tank_id, tick), 0.0) : ts.floor_price
                total += price * z[(ts.unit_id, ts.rate_output_id)]
            end
            for unit in units, iid in unit.input_ids
                total -= get(operating_cost, (unit.id, iid), 0.0) * u[(unit.id, iid)]
            end
            return total
        end
        no_extra_constraints(model, u, z) = nothing

        u_target, _status = successive_lp_optimize(units, u_applied, econ, no_extra_constraints; optimizer=optimizer)

        u_applied = _apply_rate_limited_step(u_applied, u_target, max_step_by_key)

        unit_tick = RealTimeTick(tick, y_true, y_measured, y_hat, u_applied, u_target)
        push!(history, ScheduleCoordinationTick(tick, schedule_result, unit_tick))
    end

    return history
end
