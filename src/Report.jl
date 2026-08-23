using Printf

"""
    print_report(io, product, recipe)

Pretty-print a solved recipe: component volumes/fractions, resulting
quality vs. spec, and total cost.
"""
function print_report(io::IO, product::Product, recipe::BlendRecipe)
    @printf(io, "Product: %s (%s)\n", product.name, product.id)
    @printf(io, "Demand:  %.2f\n", product.demand)
    _print_recipe_body(io, product.specs, recipe.volumes, recipe.fractions, recipe.resulting_properties, recipe.cost)
end

print_report(product::Product, recipe::BlendRecipe) = print_report(stdout, product, recipe)

"""
    print_schedule_report(io, products, tanks, result, periods)

Pretty-print a solved multi-period schedule: each period's per-product
recipe (same shape as `print_report`) followed by every tank's inventory
level at the end of that period.
"""
function print_schedule_report(io::IO, products::Vector{ScheduledProduct}, tanks::Vector{Tank},
    result::ScheduleResult, periods)
    if result.status != :optimal
        println(io, "Schedule is INFEASIBLE:")
        for d in result.diagnostics
            println(io, "  - ", d)
        end
        return
    end

    for t in sort(collect(periods))
        println(io, "="^40)
        println(io, "Period $t")
        println(io, "="^40)
        for p in products
            d = demand_at(p, t)
            d == 0 && continue
            recipe = result.recipes[(p.id, t)]
            @printf(io, "\nProduct: %s (%s)\n", p.name, p.id)
            @printf(io, "Demand:  %.2f\n", d)
            _print_recipe_body(io, p.specs, recipe.volumes, recipe.fractions, recipe.resulting_properties, recipe.cost)
        end
        println(io, "\nTank levels at end of period $t:")
        for tank in tanks
            level = result.tank_levels[(tank.id, t)]
            @printf(io, "  %-10s %10.2f  [min=%.2f max=%.2f]\n", tank.id, level, tank.capacity_min, tank.capacity_max)
        end
        println(io)
    end
end

print_schedule_report(products::Vector{ScheduledProduct}, tanks::Vector{Tank}, result::ScheduleResult, periods) =
    print_schedule_report(stdout, products, tanks, result, periods)

function _print_recipe_body(io::IO, specs::Dict{Symbol,PropertySpec}, volumes, fractions, resulting_properties, cost)
    println(io, "\nRecipe:")
    for (cid, vol) in sort(collect(volumes); by=first)
        frac = fractions[cid]
        @printf(io, "  %-10s %10.2f  (%6.2f%%)\n", cid, vol, 100 * frac)
    end
    @printf(io, "\nTotal cost: %.2f\n", cost)

    println(io, "\nResulting quality:")
    for (prop, spec) in sort(collect(specs); by=first)
        val = get(resulting_properties, prop, NaN)
        flag = _spec_flag(val, spec)
        @printf(io, "  %-12s %10.4f  [min=%s max=%s]  %s\n",
            String(prop), val,
            spec.min === nothing ? "-" : @sprintf("%.4f", spec.min),
            spec.max === nothing ? "-" : @sprintf("%.4f", spec.max),
            flag)
    end
end

function _spec_flag(val, spec::PropertySpec)
    tol = 1e-6
    if spec.min !== nothing && val < spec.min - tol
        return "VIOLATED (below min)"
    end
    if spec.max !== nothing && val > spec.max + tol
        return "VIOLATED (above max)"
    end
    near_min = spec.min !== nothing && isapprox(val, spec.min; atol=1e-3, rtol=1e-3)
    near_max = spec.max !== nothing && isapprox(val, spec.max; atol=1e-3, rtol=1e-3)
    (near_min || near_max) ? "OK (binding)" : "OK"
end
