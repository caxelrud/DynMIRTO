#!/usr/bin/env julia
# Usage: julia --project=. scripts/run_dynamic_demo.jl
#
# Demonstrates the v3 real-time dynamic optimization loop: two process
# units with concave (diminishing-returns) steady-state yield curves,
# sharing a binding utility/energy budget. See DESIGN.md section 10.
#
# The analytical constrained optimum here (hand-derived via Lagrange
# multipliers, and checked in test/test_dynamic_optimization.jl) is
# u_A = u_B = 30, for a combined economic value of 1905/tick once
# settled. Watch the "u_applied" columns ramp toward 30 under each
# unit's rate limit, and "u_target" jump there almost immediately
# (the steady-state target doesn't depend on the slow dynamics, only
# on the economics).

using DynMIRTO
using JuMP
using Random

unit_a = DynamicUnit("A", 5.0, u -> 40.0 * u - 0.5 * u^2; u_min=0.0, u_max=100.0, max_step=5.0)
unit_b = DynamicUnit("B", 5.0, u -> 30.0 * u - 0.3 * u^2; u_min=0.0, u_max=100.0, max_step=5.0)

econ(u, z) = (2.0 * z["A"] - 10.0 * u["A"]) + (1.5 * z["B"] - 8.0 * u["B"])
budget(model, u, z) = @constraint(model, u["A"] + u["B"] <= 60.0)

rng = Random.MersenneTwister(2024)
history = run_real_time_loop([unit_a, unit_b], econ, budget;
    n_ticks=25, dt=1.0,
    u_init=Dict("A" => 0.0, "B" => 0.0),
    measurement_noise_std=1.0, rng=rng)

print_realtime_report(history)
