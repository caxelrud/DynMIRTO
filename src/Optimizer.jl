using JuMP
using HiGHS

function _to_solver_space(rule::Symbol, prop::Symbol, value::Float64)
    rule === :linear && return value
    rule === :index && return to_index_space(prop, value)
    error("Unknown blend_rule :$rule")
end

function _from_solver_space(rule::Symbol, prop::Symbol, value::Float64)
    rule === :linear && return value
    rule === :index && return from_index_space(prop, value)
    error("Unknown blend_rule :$rule")
end

"""
    OptimizationResult

Outcome of `optimize_blend`. `status` is `:optimal` or `:infeasible`.
`recipes` maps product id -> `BlendRecipe` (empty when infeasible).
`diagnostics` holds human-readable notes explaining an infeasible result.
"""
struct OptimizationResult
    status::Symbol
    recipes::Dict{String,BlendRecipe}
    diagnostics::Vector{String}
end

"""
    optimize_blend(components, products; optimizer=HiGHS.Optimizer)

Solve the joint blend-optimization LP: choose how much of each eligible
component goes into each product so that every product's demand and
quality specs are met, every component's availability is respected, and
total cost is minimized. Components may be shared across products (a
single tank farm feeding several grades).
"""
function optimize_blend(components::Vector{Component}, products::Vector{Product};
    optimizer=HiGHS.Optimizer)

    isempty(components) && error("optimize_blend: no components given")
    isempty(products) && error("optimize_blend: no products given")

    pairs = Tuple{String,String}[]
    for p in products, c in components
        is_eligible(c, p) && push!(pairs, (c.id, p.id))
    end

    diagnostics = _prevalidate(components, products, pairs)
    if !isempty(diagnostics)
        return OptimizationResult(:infeasible, Dict{String,BlendRecipe}(), diagnostics)
    end

    model = Model(optimizer)
    set_silent(model)

    x = Dict{Tuple{String,String},JuMP.VariableRef}()
    for (cid, pid) in pairs
        x[(cid, pid)] = @variable(model, lower_bound = 0, base_name = "x_$(cid)_$(pid)")
    end

    comp_by_id = Dict(c.id => c for c in components)
    prod_by_id = Dict(p.id => p for p in products)

    # Volume balance: each product's inputs sum to its demand.
    for p in products
        vars = [x[(c.id, p.id)] for c in components if haskey(x, (c.id, p.id))]
        isempty(vars) && continue
        @constraint(model, sum(vars) == p.demand)
    end

    # Component availability (shared across all products it feeds).
    for c in components
        vars = [x[(c.id, p.id)] for p in products if haskey(x, (c.id, p.id))]
        isempty(vars) && continue
        @constraint(model, sum(vars) <= c.available)
        if c.min_available > 0
            @constraint(model, sum(vars) >= c.min_available)
        end
    end

    # Quality specs, evaluated in solver (index) space.
    for p in products, (prop, spec) in p.specs
        vars_vals = Tuple{JuMP.VariableRef,Float64}[]
        for c in components
            haskey(x, (c.id, p.id)) || continue
            haskey(c.properties, prop) ||
                error("Component $(c.id) is eligible for product $(p.id) but has no value for property :$prop")
            val = _to_solver_space(spec.blend_rule, prop, c.properties[prop])
            push!(vars_vals, (x[(c.id, p.id)], val))
        end
        isempty(vars_vals) && continue
        weighted = sum(v * val for (v, val) in vars_vals)
        if spec.min !== nothing
            lo = _to_solver_space(spec.blend_rule, prop, spec.min)
            @constraint(model, weighted >= lo * p.demand)
        end
        if spec.max !== nothing
            hi = _to_solver_space(spec.blend_rule, prop, spec.max)
            @constraint(model, weighted <= hi * p.demand)
        end
    end

    @objective(model, Min, sum(comp_by_id[cid].cost * v for ((cid, _), v) in x))

    optimize!(model)
    status = termination_status(model)

    if status != MOI.OPTIMAL
        note = "Solver returned $(status). This can mean the specs/availability are " *
               "infeasible together, or (rarely) numerical trouble. Run with a looser " *
               "spec or more component availability to isolate which constraint binds."
        return OptimizationResult(:infeasible, Dict{String,BlendRecipe}(), [note])
    end

    recipes = Dict{String,BlendRecipe}()
    for p in products
        volumes = Dict{String,Float64}()
        for c in components
            haskey(x, (c.id, p.id)) || continue
            v = value(x[(c.id, p.id)])
            v > 1e-9 && (volumes[c.id] = v)
        end
        fractions = Dict(cid => v / p.demand for (cid, v) in volumes)
        cost = sum(comp_by_id[cid].cost * v for (cid, v) in volumes; init=0.0)

        resulting = Dict{Symbol,Float64}()
        all_props = Set{Symbol}()
        for cid in keys(volumes)
            union!(all_props, keys(comp_by_id[cid].properties))
        end
        for prop in all_props
            rule = haskey(p.specs, prop) ? p.specs[prop].blend_rule : :linear
            weighted = sum(_to_solver_space(rule, prop, comp_by_id[cid].properties[prop]) * v
                            for (cid, v) in volumes if haskey(comp_by_id[cid].properties, prop); init=0.0)
            resulting[prop] = _from_solver_space(rule, prop, weighted / p.demand)
        end

        recipes[p.id] = BlendRecipe(p.id, volumes, fractions, resulting, cost)
    end

    return OptimizationResult(:optimal, recipes, String[])
end

"""
Cheap, pre-solve sanity checks that produce a clear diagnosis for the
common infeasibility cases, instead of a bare solver status code.
"""
function _prevalidate(components::Vector{Component}, products::Vector{Product}, pairs::Vector{Tuple{String,String}})
    notes = String[]
    comp_by_id = Dict(c.id => c for c in components)

    for p in products
        eligible_ids = [cid for (cid, pid) in pairs if pid == p.id]
        if isempty(eligible_ids)
            push!(notes, "Product $(p.id): no eligible components at all.")
            continue
        end
        total_available = sum(comp_by_id[cid].available for cid in eligible_ids)
        if total_available < p.demand
            push!(notes,
                "Product $(p.id): demand ($(p.demand)) exceeds total available volume " *
                "of eligible components ($(total_available)).")
        end
        total_floor = sum(comp_by_id[cid].min_available for cid in eligible_ids)
        if total_floor > p.demand
            push!(notes,
                "Product $(p.id): sum of component must-use minimums ($(total_floor)) " *
                "exceeds demand ($(p.demand)).")
        end
        for (prop, spec) in p.specs
            vals = [comp_by_id[cid].properties[prop] for cid in eligible_ids if haskey(comp_by_id[cid].properties, prop)]
            isempty(vals) && continue
            lo, hi = extrema(vals)
            if spec.max !== nothing && lo > spec.max
                push!(notes,
                    "Product $(p.id), property :$prop: every eligible component " *
                    "($(lo)-$(hi)) exceeds the max spec ($(spec.max)); no blend can meet it.")
            end
            if spec.min !== nothing && hi < spec.min
                push!(notes,
                    "Product $(p.id), property :$prop: every eligible component " *
                    "($(lo)-$(hi)) is below the min spec ($(spec.min)); no blend can meet it.")
            end
        end
    end

    return notes
end
