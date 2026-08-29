#!/usr/bin/env julia
# Usage: julia --project=. scripts/run_coordination_coldstart_demo.jl
#
# Same scenario as run_coordination_demo.jl, but started cold (u=0, the
# reformer's actual minimum) instead of warm-started. See DESIGN.md
# section 11.5.
#
# Without a floor_price, this never recovers: an infeasible blend gives
# every sourced component a price of exactly $0, so the reformer's
# economic objective becomes strictly "produce nothing" -- a permanent
# deadlock, not a slow transient (see test/test_coordination.jl's
# "cold start with no floor_price" test).
#
# With ComponentSource's floor_price=35.0 (deliberately *not* the true
# equilibrium price of $40, to show it only needs to be "good enough to
# bootstrap"), the reformer has a real incentive to produce even while
# the blend can't yet be solved. Watch: tick 1 is infeasible; once
# production crosses ~66.67 the blend becomes feasible and the real
# shadow price ($40, the same as the warm-start demo) takes back over,
# pushing production on to the true optimum (u*=73.30, rate*=90.0).

using DynMIRTO

fill_template = Component("FILL", "Filler", 40.0, 1000.0; properties=Dict(:RON => 80.0))
ref_template = Component("REF", "Reformate", 0.0, 0.0; properties=Dict(:RON => 95.0))
reformer = DynamicUnit("REFORMER", 5.0, u -> 150.0 * (1.0 - exp(-u / 80.0));
    u_min=0.0, u_max=300.0, max_step=10.0)
source = ComponentSource("REF", "REFORMER", "y"; floor_price=35.0)
product = Product("REG", "Regular", 100.0; specs=Dict(:RON => PropertySpec(; min=90.0, blend_rule=:linear)))
operating_cost = Dict(("REFORMER", "u") => 30.0)

history = run_coordinated_loop([fill_template], [ref_template], [source], [reformer], operating_cost, [product];
    n_ticks=25, dt=1.0)  # no u_init: starts at u_min=0, the true cold start

println("tick  status      REF price   u (feed)   y_hat (rate)   blend cost")
println("-"^68)
for t in history
    price = t.blend_result.status == :optimal ? t.blend_result.component_shadow_prices["REF"] : source.floor_price
    label = t.blend_result.status == :optimal ? string(round(price; digits=2)) : "$(round(price; digits=2)) (floor)"
    cost = t.blend_result.status == :optimal ? t.blend_result.recipes["REG"].cost : NaN
    println(
        rpad(t.tick, 6), rpad(t.blend_result.status, 12), rpad(label, 12),
        rpad(round(t.unit_tick.u_applied[("REFORMER", "u")]; digits=2), 11),
        rpad(round(t.unit_tick.y_hat[("REFORMER", "y")]; digits=2), 15),
        isnan(cost) ? "-" : round(cost; digits=2),
    )
end
