"""
Multi-period scheduling on top of the v1 blend engine: components come
from **tanks** whose inventory evolves period to period via scheduled
receipts and blending draws, instead of a single flat `available` number.

Simplification (see DESIGN.md section 9.1): each tank holds one component
whose quality is fixed — receipts change how much is in the tank, never
its quality. This keeps the model a pure LP, at the cost of not modeling
real in-tank quality mixing. `Component.available`/`min_available` are
ignored here; the tank's dynamic inventory governs availability instead.
"""

struct Tank
    id::String
    component_id::String
    capacity_min::Float64
    capacity_max::Float64
    initial_inventory::Float64

    function Tank(id, component_id, capacity_min, capacity_max, initial_inventory)
        capacity_min <= capacity_max ||
            error("Tank $id: capacity_min ($capacity_min) must be <= capacity_max ($capacity_max)")
        capacity_min <= initial_inventory <= capacity_max ||
            error("Tank $id: initial_inventory ($initial_inventory) must be within " *
                  "[$capacity_min, $capacity_max]")
        new(id, component_id, Float64(capacity_min), Float64(capacity_max), Float64(initial_inventory))
    end
end

"""
Like `Product`, but demand varies by period. A period with no entry in
`demand` has zero required volume that period.
"""
struct ScheduledProduct
    id::String
    name::String
    demand::Dict{Int,Float64}
    price::Float64
    specs::Dict{Symbol,PropertySpec}
    eligible_components::Union{Vector{String},Nothing}

    function ScheduledProduct(id, name, demand::Dict{Int,Float64}; price=0.0,
        specs=Dict{Symbol,PropertySpec}(), eligible_components=nothing)
        all(>=(0), values(demand)) || error("ScheduledProduct $id: demand must be >= 0")
        new(id, name, demand, Float64(price), specs, eligible_components)
    end
end

is_eligible(c::Component, p::ScheduledProduct) =
    p.eligible_components === nothing || c.id in p.eligible_components

demand_at(p::ScheduledProduct, t::Int) = get(p.demand, t, 0.0)

"""
One period's worth of a solved schedule: same shape as `BlendRecipe`,
plus the period number.
"""
struct PeriodRecipe
    period::Int
    product_id::String
    volumes::Dict{String,Float64}
    fractions::Dict{String,Float64}
    resulting_properties::Dict{Symbol,Float64}
    cost::Float64
end

"""
    ScheduleResult

Outcome of `optimize_schedule`. `status` is `:optimal` or `:infeasible`.
`recipes[(product_id, period)]` gives that period's `PeriodRecipe`.
`tank_levels[(tank_id, period)]` gives the tank's inventory at the *end*
of that period (period `0` is each tank's `initial_inventory`).
"""
struct ScheduleResult
    status::Symbol
    recipes::Dict{Tuple{String,Int},PeriodRecipe}
    tank_levels::Dict{Tuple{String,Int},Float64}
    diagnostics::Vector{String}
end

function _prevalidate_schedule(components::Vector{Component}, tanks::Vector{Tank},
    products::Vector{ScheduledProduct}, receipts::Dict{Tuple{String,Int},Float64},
    periods::AbstractVector{Int})

    notes = String[]
    comp_by_id = Dict(c.id => c for c in components)
    tank_by_component = Dict{String,Tank}()
    for tank in tanks
        haskey(comp_by_id, tank.component_id) ||
            push!(notes, "Tank $(tank.id): no component with id $(tank.component_id).")
        if haskey(tank_by_component, tank.component_id)
            push!(notes, "Component $(tank.component_id) is held by more than one tank " *
                         "($(tank_by_component[tank.component_id].id) and $(tank.id)) — " *
                         "v2 supports at most one tank per component.")
        end
        tank_by_component[tank.component_id] = tank
    end

    for p in products, t in periods
        d = demand_at(p, t)
        d == 0 && continue
        eligible_ids = [c.id for c in components if is_eligible(c, p)]
        isempty(eligible_ids) &&
            push!(notes, "Product $(p.id), period $t: no eligible components at all.")
    end

    # Rough feasibility: run the (non-negative) net draw a component's tank
    # would need across the horizon, ignoring blend ratios, and check the
    # tank never has to go negative even before capacity_min is applied.
    for tank in tanks
        haskey(comp_by_id, tank.component_id) || continue
        max_total_demand = sum(
            demand_at(p, t) for p in products for t in periods
            if is_eligible(comp_by_id[tank.component_id], p)
        ; init=0.0)
        total_receipts = sum(get(receipts, (tank.id, t), 0.0) for t in periods; init=0.0)
        if tank.initial_inventory + total_receipts - max_total_demand < tank.capacity_min - 1e-6 &&
           length(tanks) == 1 && length(products) == 1
            # Only a reliable signal in the simplest case (one tank feeding
            # everything); otherwise this is just a hint, not a proof.
            push!(notes,
                "Tank $(tank.id): initial inventory plus scheduled receipts " *
                "($(tank.initial_inventory + total_receipts)) cannot cover total " *
                "demand it alone must serve ($(max_total_demand)) without breaching " *
                "capacity_min ($(tank.capacity_min)).")
        end
    end

    return notes
end

"""
    optimize_schedule(components, tanks, products, receipts, periods; optimizer=HiGHS.Optimizer)

Solve the multi-period blend-scheduling LP: choose, for every period, how
much of each eligible component goes into each product, so that every
period's demand and quality specs are met, every tank stays within its
capacity as its inventory evolves via scheduled receipts and blending
draws, and total cost across the whole horizon is minimized.

`periods` is the sequence of period indices to plan over (e.g. `1:7`).
`receipts` maps `(tank_id, period) => volume` delivered at the start of
that period; a missing entry means no receipt that period.
"""
function optimize_schedule(components::Vector{Component}, tanks::Vector{Tank},
    products::Vector{ScheduledProduct}, receipts::Dict{Tuple{String,Int},Float64},
    periods::AbstractVector{Int}; optimizer=HiGHS.Optimizer)

    isempty(components) && error("optimize_schedule: no components given")
    isempty(tanks) && error("optimize_schedule: no tanks given")
    isempty(products) && error("optimize_schedule: no products given")
    isempty(periods) && error("optimize_schedule: no periods given")

    diagnostics = _prevalidate_schedule(components, tanks, products, receipts, periods)
    if !isempty(diagnostics)
        return ScheduleResult(:infeasible, Dict{Tuple{String,Int},PeriodRecipe}(),
            Dict{Tuple{String,Int},Float64}(), diagnostics)
    end

    comp_by_id = Dict(c.id => c for c in components)
    tank_by_component = Dict(tank.component_id => tank for tank in tanks)

    pairs = Tuple{String,String}[]
    for p in products, c in components
        is_eligible(c, p) && push!(pairs, (c.id, p.id))
    end

    model = Model(optimizer)
    set_silent(model)

    x = Dict{Tuple{String,String,Int},JuMP.VariableRef}()
    for (cid, pid) in pairs, t in periods
        x[(cid, pid, t)] = @variable(model, lower_bound = 0, base_name = "x_$(cid)_$(pid)_$t")
    end

    inv = Dict{Tuple{String,Int},JuMP.VariableRef}()
    for tank in tanks, t in periods
        inv[(tank.id, t)] = @variable(model,
            lower_bound = tank.capacity_min, upper_bound = tank.capacity_max,
            base_name = "inv_$(tank.id)_$t")
    end

    for p in products, t in periods
        vars = [x[(c.id, p.id, t)] for c in components if haskey(x, (c.id, p.id, t))]
        d = demand_at(p, t)
        if isempty(vars)
            d == 0 || error("Product $(p.id), period $t: demand $d but no eligible components")
        else
            @constraint(model, sum(vars) == d)
        end
    end

    ordered_periods = sort(collect(periods))
    for tank in tanks
        prev_inv = tank.initial_inventory
        for t in ordered_periods
            consumed_vars = Tuple{JuMP.VariableRef,Float64}[]
            for (cid, pid, tt) in keys(x)
                tt == t && cid == tank.component_id || continue
                push!(consumed_vars, (x[(cid, pid, t)], 1.0))
            end
            consumed = isempty(consumed_vars) ? 0.0 : sum(v for (v, _) in consumed_vars)
            receipt = get(receipts, (tank.id, t), 0.0)
            @constraint(model, inv[(tank.id, t)] == prev_inv + receipt - consumed)
            prev_inv = inv[(tank.id, t)]
        end
    end

    for p in products, t in periods, (prop, spec) in p.specs
        d = demand_at(p, t)
        d == 0 && continue
        vars_vals = Tuple{JuMP.VariableRef,Float64}[]
        for c in components
            haskey(x, (c.id, p.id, t)) || continue
            haskey(c.properties, prop) ||
                error("Component $(c.id) is eligible for product $(p.id) but has no value for property :$prop")
            val = _to_solver_space(spec.blend_rule, prop, c.properties[prop])
            push!(vars_vals, (x[(c.id, p.id, t)], val))
        end
        isempty(vars_vals) && continue
        weighted = sum(v * val for (v, val) in vars_vals)
        if spec.min !== nothing
            lo = _to_solver_space(spec.blend_rule, prop, spec.min)
            @constraint(model, weighted >= lo * d)
        end
        if spec.max !== nothing
            hi = _to_solver_space(spec.blend_rule, prop, spec.max)
            @constraint(model, weighted <= hi * d)
        end
    end

    @objective(model, Min, sum(comp_by_id[cid].cost * v for ((cid, _, _), v) in x))

    optimize!(model)
    status = termination_status(model)

    if status != MOI.OPTIMAL
        note = "Solver returned $(status). This can mean tank capacity/receipts and " *
               "demand are infeasible together over this horizon, or (rarely) numerical trouble."
        return ScheduleResult(:infeasible, Dict{Tuple{String,Int},PeriodRecipe}(),
            Dict{Tuple{String,Int},Float64}(), [note])
    end

    tank_levels = Dict{Tuple{String,Int},Float64}()
    for tank in tanks, t in periods
        tank_levels[(tank.id, t)] = value(inv[(tank.id, t)])
    end

    recipes = Dict{Tuple{String,Int},PeriodRecipe}()
    for p in products, t in periods
        d = demand_at(p, t)
        volumes = Dict{String,Float64}()
        for c in components
            haskey(x, (c.id, p.id, t)) || continue
            v = value(x[(c.id, p.id, t)])
            v > 1e-9 && (volumes[c.id] = v)
        end
        d == 0 && isempty(volumes) && continue

        fractions = d > 0 ? Dict(cid => v / d for (cid, v) in volumes) : Dict{String,Float64}()
        cost = sum(comp_by_id[cid].cost * v for (cid, v) in volumes; init=0.0)

        resulting = Dict{Symbol,Float64}()
        if d > 0
            all_props = Set{Symbol}()
            for cid in keys(volumes)
                union!(all_props, keys(comp_by_id[cid].properties))
            end
            for prop in all_props
                rule = haskey(p.specs, prop) ? p.specs[prop].blend_rule : :linear
                weighted = sum(_to_solver_space(rule, prop, comp_by_id[cid].properties[prop]) * v
                                for (cid, v) in volumes if haskey(comp_by_id[cid].properties, prop); init=0.0)
                resulting[prop] = _from_solver_space(rule, prop, weighted / d)
            end
        end

        recipes[(p.id, t)] = PeriodRecipe(t, p.id, volumes, fractions, resulting, cost)
    end

    return ScheduleResult(:optimal, recipes, tank_levels, String[])
end
