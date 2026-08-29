#!/usr/bin/env julia
# Usage: julia --project=. scripts/run_dynamic_demo.jl
#
# Demonstrates the v3 real-time dynamic optimization loop with a mix of
# single-input/single-output units and one genuinely multivariable unit.
# See DESIGN.md section 10 (and 10.6 for the multivariable extension).
#
# Units A and B: concave (diminishing-returns) steady-state yield curves,
# sharing a binding utility/energy budget. The analytical constrained
# optimum here (hand-derived via Lagrange multipliers, and checked in
# test/test_dynamic_optimization.jl) is u_A = u_B = 30.
#
# Unit COL: a toy 2-input/2-output "distillation column" -- reflux and
# reboiler duty both affect *both* outputs (top and bottoms purity), with
# real cross-coupling (adjusting duty alone shifts top purity too, and
# vice versa). The analytical unconstrained optimum (also hand-derived
# and checked in the test suite) is reflux=51, duty=53.33 -- getting
# this right requires the linearization to use the full Jacobian
# (all 4 partial derivatives), not just each output's "own" derivative.
#
# Watch "target" jump to each analytical optimum almost immediately (it
# only depends on the economics, not the slow dynamics), while "applied"
# ramps there under each input's own rate limit, and y_hat climbs toward
# the true steady-state outputs as the dynamics settle.

using DynMIRTO
using JuMP
using Random

unit_a = DynamicUnit("A", 5.0, u -> 40.0 * u - 0.5 * u^2; u_min=0.0, u_max=100.0, max_step=5.0)
unit_b = DynamicUnit("B", 5.0, u -> 30.0 * u - 0.3 * u^2; u_min=0.0, u_max=100.0, max_step=5.0)

col_gain(u) = Dict(
    "top" => 50.0 * u["reflux"] + 5.0 * u["duty"] - 0.5 * u["reflux"]^2,
    "bottoms" => 40.0 * u["duty"] + 8.0 * u["reflux"] - 0.4 * u["duty"]^2,
)
unit_col = DynamicUnit("COL", ["reflux", "duty"], ["top", "bottoms"],
    Dict("top" => 8.0, "bottoms" => 6.0), col_gain;
    u_min=Dict("reflux" => 0.0, "duty" => 0.0),
    u_max=Dict("reflux" => 100.0, "duty" => 100.0),
    max_step=Dict("reflux" => 5.0, "duty" => 5.0))

units = [unit_a, unit_b, unit_col]

function econ(u, z)
    (2.0 * z[("A", "y")] - 10.0 * u[("A", "u")]) +
    (1.5 * z[("B", "y")] - 8.0 * u[("B", "u")]) +
    (2.0 * z[("COL", "top")] - 10.0 * u[("COL", "reflux")]) +
    (1.5 * z[("COL", "bottoms")] - 6.0 * u[("COL", "duty")])
end

budget(model, u, z) = @constraint(model, u[("A", "u")] + u[("B", "u")] <= 60.0)

rng = Random.MersenneTwister(2024)
history = run_real_time_loop(units, econ, budget;
    n_ticks=25, dt=1.0,
    u_init=Dict((u.id, i) => 0.0 for u in units for i in u.input_ids),
    measurement_noise_std=1.0, rng=rng)

print_realtime_report(history)
