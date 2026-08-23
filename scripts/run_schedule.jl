#!/usr/bin/env julia
# Usage: julia --project=. scripts/run_schedule.jl data/examples/schedule_example.json

using DynMIRTO

function main()
    length(ARGS) == 1 || error("Usage: julia --project=. scripts/run_schedule.jl <schedule.json>")
    components, tanks, products, receipts, periods = load_schedule(ARGS[1])

    result = optimize_schedule(components, tanks, products, receipts, periods)

    if result.status != :optimal
        println("Schedule is INFEASIBLE:")
        for note in result.diagnostics
            println("  - ", note)
        end
        exit(1)
    end

    print_schedule_report(products, tanks, result, periods)
end

main()
