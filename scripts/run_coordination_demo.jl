#!/usr/bin/env julia
# Usage: julia --project=. scripts/run_coordination_demo.jl
#
# Demonstrates connecting v3 (real-time dynamic optimization) to v1
# (blend optimization) -- the "missing link" GDOT's own materials
# describe. See DESIGN.md section 11.
#
# Scenario: a blend (REG, demand 100/tick, spec RON >= 90) draws from a
# static filler (FILL: $40/unit, RON 80, always plentiful) and a
# reformer-sourced component (REF: $0 blend-side cost, RON 95) whose
# *volume* is set in real time by a DynamicUnit ("REFORMER") maximizing
# revenue (v1's live shadow price for REF) against its own operating
# cost ($30/unit of feed).
#
# Hand-derived equilibrium (checked in test/test_coordination.jl):
# because REF is both free and higher-quality than FILL, the blend
# always uses all available REF, so REF's shadow price stays pinned at
# exactly $40 (the cost of the FILL it displaces) the whole time --
# watch the "REF shadow price" column hold at 40.00 from tick 1, while
# the reformer's feed setpoint (u) and production (y_hat) climb toward
# the analytical optimum (u*=73.30, rate*=90.0).

using DynMIRTO

fill_template = Component("FILL", "Filler", 40.0, 1000.0; properties=Dict(:RON => 80.0))
ref_template = Component("REF", "Reformate", 0.0, 0.0; properties=Dict(:RON => 95.0))
reformer = DynamicUnit("REFORMER", 5.0, u -> 150.0 * (1.0 - exp(-u / 80.0));
    u_min=0.0, u_max=300.0, max_step=10.0)
source = ComponentSource("REF", "REFORMER", "y")
product = Product("REG", "Regular", 100.0; specs=Dict(:RON => PropertySpec(; min=90.0, blend_rule=:linear)))
operating_cost = Dict(("REFORMER", "u") => 30.0)

# Warm start (u=50): the reformer is already producing enough REF (rate
# 69.7) to hit the octane spec on tick 1, so every tick is feasible from
# the start. See DESIGN.md section 11.5 for what happens from a true cold
# start (u=0) instead -- a real deadlock, not a transient.
history = run_coordinated_loop([fill_template], [ref_template], [source], [reformer], operating_cost, [product];
    n_ticks=25, dt=1.0, u_init=Dict(("REFORMER", "u") => 50.0))

println("tick  status      REF shadow price   u (feed)   y_hat (rate)   blend cost")
println("-"^75)
for t in history
    price = get(t.blend_result.component_shadow_prices, "REF", NaN)
    cost = t.blend_result.status == :optimal ? t.blend_result.recipes["REG"].cost : NaN
    println(
        rpad(t.tick, 6), rpad(t.blend_result.status, 12),
        rpad(round(price; digits=2), 19),
        rpad(round(t.unit_tick.u_applied[("REFORMER", "u")]; digits=2), 11),
        rpad(round(t.unit_tick.y_hat[("REFORMER", "y")]; digits=2), 15),
        round(cost; digits=2),
    )
end
