using Printf

"""
    print_report(io, product, recipe)

Pretty-print a solved recipe: component volumes/fractions, resulting
quality vs. spec, and total cost.
"""
function print_report(io::IO, product::Product, recipe::BlendRecipe)
    @printf(io, "Product: %s (%s)\n", product.name, product.id)
    @printf(io, "Demand:  %.2f\n", product.demand)
    println(io, "\nRecipe:")
    for (cid, vol) in sort(collect(recipe.volumes); by=first)
        frac = recipe.fractions[cid]
        @printf(io, "  %-10s %10.2f  (%6.2f%%)\n", cid, vol, 100 * frac)
    end
    @printf(io, "\nTotal cost: %.2f\n", recipe.cost)

    println(io, "\nResulting quality:")
    for (prop, spec) in sort(collect(product.specs); by=first)
        val = get(recipe.resulting_properties, prop, NaN)
        flag = _spec_flag(val, spec)
        @printf(io, "  %-12s %10.4f  [min=%s max=%s]  %s\n",
            String(prop), val,
            spec.min === nothing ? "-" : @sprintf("%.4f", spec.min),
            spec.max === nothing ? "-" : @sprintf("%.4f", spec.max),
            flag)
    end
end

print_report(product::Product, recipe::BlendRecipe) = print_report(stdout, product, recipe)

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
