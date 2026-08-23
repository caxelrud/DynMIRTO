#!/usr/bin/env julia
# Usage: julia --project=. scripts/run_scenario.jl data/examples/regular_unleaded.json

using DynMIRTO

function main()
    length(ARGS) == 1 || error("Usage: julia --project=. scripts/run_scenario.jl <scenario.json>")
    components, products = load_scenario(ARGS[1])

    result = optimize_blend(components, products)

    if result.status != :optimal
        println("Scenario is INFEASIBLE:")
        for note in result.diagnostics
            println("  - ", note)
        end
        exit(1)
    end

    for p in products
        print_report(p, result.recipes[p.id])
        println()
    end
end

main()
