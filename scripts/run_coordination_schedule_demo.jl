#!/usr/bin/env julia
# Usage: julia --project=. scripts/run_coordination_schedule_demo.jl
#
# Demonstrates extending v3 <-> v1 coordination (run_coordination_demo.jl)
# to v2 (tanks/multi-period scheduling) instead of v1's single-period
# blend. See DESIGN.md section 11.6.
#
# Part 1 is the same reformer/REF/FILL scenario as run_coordination_demo.jl,
# but REF now lives in a Tank sourced via TankSource instead of a flat
# Component.available -- with both tanks wide open (huge capacity), the
# result is identical to v1's: REF's shadow price pins at $40 (the FILL
# it displaces) from tick 1, while the reformer's feed setpoint and
# production climb to the same hand-derived optimum (u*=73.30, rate*=90.0).
# This is the cross-validation: the Tank-based path reproduces v1's own
# numbers exactly (see test/test_coordination.jl).
#
# Part 2 shows the genuinely new capability v2's coordination adds over
# v1's: real cross-tick state. A tank here actually accumulates a surplus
# when its unit produces faster than demand draws it down -- something
# v1's coordination has no way to represent at all (it re-derives
# "availability" from scratch, with no memory, every tick).

using DynMIRTO

println("=== Part 1: cross-validating against v1's hand-derived equilibrium ===\n")

fill = Component("FILL", "Filler", 40.0, 1000.0; properties=Dict(:RON => 80.0))
ref = Component("REF", "Reformate", 0.0, 0.0; properties=Dict(:RON => 95.0))
tank_fill = Tank("TFILL", "FILL", 0.0, 1_000_000.0, 1_000_000.0)
tank_ref = Tank("TREF", "REF", 0.0, 1_000_000.0, 0.0)
n_ticks = 25
demand = Dict(t => 100.0 for t in 1:n_ticks)
product = ScheduledProduct("REG", "Regular", demand;
    specs=Dict(:RON => PropertySpec(; min=90.0, blend_rule=:linear)))
reformer = DynamicUnit("REFORMER", 5.0, u -> 150.0 * (1.0 - exp(-u / 80.0));
    u_min=0.0, u_max=300.0, max_step=10.0)
source = TankSource("TREF", "REFORMER", "y")
operating_cost = Dict(("REFORMER", "u") => 30.0)

history = run_coordinated_schedule_loop([fill, ref], [tank_fill, tank_ref], [source], [reformer], operating_cost, [product];
    n_ticks=n_ticks, dt=1.0, u_init=Dict(("REFORMER", "u") => 50.0))

println("tick  status      TREF shadow price   TREF level   u (feed)   y_hat (rate)")
println("-"^76)
for t in history
    price = get(t.schedule_result.tank_shadow_prices, ("TREF", t.tick), NaN)
    level = get(t.schedule_result.tank_levels, ("TREF", t.tick), NaN)
    println(
        rpad(t.tick, 6), rpad(t.schedule_result.status, 12),
        rpad(round(price; digits=2), 20),
        rpad(round(level; digits=2), 13),
        rpad(round(t.unit_tick.u_applied[("REFORMER", "u")]; digits=2), 11),
        round(t.unit_tick.y_hat[("REFORMER", "y")]; digits=2),
    )
end

println("\n=== Part 2: genuine cross-tick tank accumulation ===\n")
println("A unit producing a flat 50/tick against a flat 30/tick demand, alone")
println("in its tank: the surplus (20/tick) has nowhere to go but build up --")
println("v1's coordination has no way to represent this at all.\n")

ref2 = Component("REF", "Reformate", 0.0, 0.0; properties=Dict(:RON => 90.0))
tank2 = Tank("TREF", "REF", 0.0, 1_000_000.0, 0.0)
demand2 = Dict(t => 30.0 for t in 1:5)
product2 = ScheduledProduct("REG", "Regular", demand2)
pump = DynamicUnit("PUMP", 0.01, u -> 50.0; u_min=0.0, u_max=0.0, max_step=1.0)
source2 = TankSource("TREF", "PUMP", "y")

history2 = run_coordinated_schedule_loop([ref2], [tank2], [source2], [pump],
    Dict{Tuple{String,String},Float64}(), [product2]; n_ticks=5, dt=1.0)

println("tick  status      receipt (y_hat)   demand   TREF level")
println("-"^54)
for t in history2
    level = get(t.schedule_result.tank_levels, ("TREF", t.tick), NaN)
    println(
        rpad(t.tick, 6), rpad(t.schedule_result.status, 12),
        rpad(round(t.unit_tick.y_hat[("PUMP", "y")]; digits=2), 18),
        rpad(demand2[t.tick], 9),
        round(level; digits=2),
    )
end
