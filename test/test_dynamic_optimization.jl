using Random
using JuMP

@testset "DynamicOptimization" begin

    @testset "step_state matches the exact exponential solution" begin
        unit = DynamicUnit("A", 10.0, u -> 2.0 * u; u_min=0.0, u_max=100.0, max_step=10.0)

        # z = f(5) = 10; after dt == tau, decay = exp(-1)
        y1 = step_state(Dict("y" => 0.0), Dict("u" => 5.0), unit, 10.0)
        @test isapprox(y1["y"], 10.0 + (0.0 - 10.0) * exp(-1.0); atol=1e-12)

        # dt = 0 leaves the state unchanged
        @test isapprox(step_state(Dict("y" => 3.0), Dict("u" => 5.0), unit, 0.0)["y"], 3.0; atol=1e-12)

        # after many time constants, the state has essentially settled to z
        y_settled = step_state(Dict("y" => 0.0), Dict("u" => 5.0), unit, 50.0 * unit.tau["y"])
        @test isapprox(y_settled["y"], 10.0; atol=1e-9)
    end

    @testset "reconcile: closed-form weighted average and its boundary cases" begin
        unit = DynamicUnit("A", 10.0, u -> 2.0 * u; u_min=0.0, u_max=100.0, max_step=10.0)
        predicted = step_state(Dict("y" => 0.0), Dict("u" => 5.0), unit, 10.0)["y"]

        r(w_model, w_meas) = reconcile(Dict("y" => 0.0), Dict("u" => 5.0), Dict("y" => 999.0), unit, 10.0;
            w_model=w_model, w_meas=w_meas)["y"]

        # all weight on the model: recovers the prediction exactly
        @test isapprox(r(1.0, 0.0), predicted; atol=1e-9)
        # all weight on the measurement: recovers the measurement exactly
        @test isapprox(r(0.0, 1.0), 999.0; atol=1e-9)
        # equal weights: simple average
        @test isapprox(r(1.0, 1.0), (predicted + 999.0) / 2; atol=1e-9)
    end

    @testset "successive_lp_optimize: single concave unit matches the calculus optimum" begin
        # f(u) = 40u - 0.5u^2; econ = price*f(u) - cost*u = 2*(40u-0.5u^2) - 10u = 70u - u^2
        # d/du = 70 - 2u = 0  =>  u* = 35, objective* = 70*35 - 35^2 = 1225
        unit = DynamicUnit("A", 5.0, u -> 40.0 * u - 0.5 * u^2; u_min=0.0, u_max=100.0, max_step=100.0)
        econ(u, z) = 2.0 * z[("A", "y")] - 10.0 * u[("A", "u")]
        no_constraints(model, u, z) = nothing

        u_opt, status = successive_lp_optimize([unit], Dict(("A", "u") => 0.0), econ, no_constraints)
        @test status == :optimal
        @test isapprox(u_opt[("A", "u")], 35.0; atol=1e-2)

        obj = econ(u_opt, Dict(("A", "y") => unit.steady_state_gain(Dict("u" => u_opt[("A", "u")]))["y"]))
        @test isapprox(obj, 1225.0; atol=1e-1)
    end

    @testset "successive_lp_optimize: two units, binding budget, matches the Lagrangian optimum" begin
        # f_A(u) = 40u - 0.5u^2, price 2.0, cost 10.0  -> unconstrained optimum at u=35
        # f_B(u) = 30u - 0.3u^2, price 1.5, cost 8.0   -> unconstrained optimum at u=41.11
        # Budget u_A + u_B <= 60 is binding; equal-marginal-value solution (hand-derived
        # via Lagrange multipliers): u_A = 30, u_B = 30, total econ = 1905.
        unit_a = DynamicUnit("A", 5.0, u -> 40.0 * u - 0.5 * u^2; u_min=0.0, u_max=100.0, max_step=100.0)
        unit_b = DynamicUnit("B", 5.0, u -> 30.0 * u - 0.3 * u^2; u_min=0.0, u_max=100.0, max_step=100.0)

        econ(u, z) = (2.0 * z[("A", "y")] - 10.0 * u[("A", "u")]) + (1.5 * z[("B", "y")] - 8.0 * u[("B", "u")])
        budget(model, u, z) = @constraint(model, u[("A", "u")] + u[("B", "u")] <= 60.0)

        u_opt, status = successive_lp_optimize([unit_a, unit_b],
            Dict(("A", "u") => 0.0, ("B", "u") => 0.0), econ, budget)
        @test status == :optimal
        @test isapprox(u_opt[("A", "u")], 30.0; atol=0.5)
        @test isapprox(u_opt[("B", "u")], 30.0; atol=0.5)
        @test u_opt[("A", "u")] + u_opt[("B", "u")] <= 60.0 + 1e-6

        z_opt = Dict(
            ("A", "y") => unit_a.steady_state_gain(Dict("u" => u_opt[("A", "u")]))["y"],
            ("B", "y") => unit_b.steady_state_gain(Dict("u" => u_opt[("B", "u")]))["y"],
        )
        @test isapprox(econ(u_opt, z_opt), 1905.0; atol=2.0)
    end

    @testset "successive_lp_optimize: a genuinely multivariable unit matches the coupled optimum" begin
        # A 2-input/2-output unit ("reflux"/"duty" -> "top"/"bottoms") with
        # real cross-coupling: each output depends on *both* inputs.
        #   top      = 50*reflux + 5*duty  - 0.5*reflux^2
        #   bottoms  = 40*duty   + 8*reflux - 0.4*duty^2
        # econ = price_top*top - cost_reflux*reflux + price_bot*bottoms - cost_duty*duty
        #      = 2*top - 10*reflux + 1.5*bottoms - 6*duty
        #
        # Hand-derived (calculus) optimum, solving d(econ)/d(reflux) = 0 and
        # d(econ)/d(duty) = 0 -- each equation includes the *other* input's
        # cross-derivative (5 and 8 respectively), which a Jacobian that
        # only captured each output's "own" partial derivative would miss:
        #   d/d(reflux): 2*(50-reflux) + 1.5*8 - 10 = 0  =>  reflux* = 51
        #   d/d(duty):   1.5*(40-0.8*duty) + 2*5 - 6 = 0 =>  duty* = 64/1.2 = 53.3333...
        # Getting a *wrong* answer (reflux=45, duty=45) would mean the
        # off-diagonal Jacobian terms (5 and 8) were dropped.
        gain(u) = Dict(
            "top" => 50.0 * u["reflux"] + 5.0 * u["duty"] - 0.5 * u["reflux"]^2,
            "bottoms" => 40.0 * u["duty"] + 8.0 * u["reflux"] - 0.4 * u["duty"]^2,
        )
        unit = DynamicUnit("COL", ["reflux", "duty"], ["top", "bottoms"],
            Dict("top" => 8.0, "bottoms" => 6.0), gain;
            u_min=Dict("reflux" => 0.0, "duty" => 0.0),
            u_max=Dict("reflux" => 100.0, "duty" => 100.0),
            max_step=Dict("reflux" => 20.0, "duty" => 20.0))

        econ(u, z) = 2.0 * z[("COL", "top")] - 10.0 * u[("COL", "reflux")] +
                     1.5 * z[("COL", "bottoms")] - 6.0 * u[("COL", "duty")]
        no_constraints(model, u, z) = nothing

        u_opt, status = successive_lp_optimize([unit],
            Dict(("COL", "reflux") => 0.0, ("COL", "duty") => 0.0), econ, no_constraints)
        @test status == :optimal
        @test isapprox(u_opt[("COL", "reflux")], 51.0; atol=0.5)
        @test isapprox(u_opt[("COL", "duty")], 64.0 / 1.2; atol=0.5)
        # a diagonal-only (wrong) Jacobian would have converged near (45, 45) instead
        @test !isapprox(u_opt[("COL", "reflux")], 45.0; atol=1.0)
        @test !isapprox(u_opt[("COL", "duty")], 45.0; atol=1.0)

        z_opt = gain(Dict("reflux" => u_opt[("COL", "reflux")], "duty" => u_opt[("COL", "duty")]))
        expected_obj = 2.0 * (50.0 * 51.0 + 5.0 * (64.0 / 1.2) - 0.5 * 51.0^2) - 10.0 * 51.0 +
                       1.5 * (40.0 * (64.0 / 1.2) + 8.0 * 51.0 - 0.4 * (64.0 / 1.2)^2) - 6.0 * (64.0 / 1.2)
        @test isapprox(econ(u_opt, Dict(("COL", "top") => z_opt["top"], ("COL", "bottoms") => z_opt["bottoms"])),
            expected_obj; atol=5.0)
    end

    @testset "run_real_time_loop: no noise, converges to the constrained optimum under a rate limit" begin
        unit_a = DynamicUnit("A", 5.0, u -> 40.0 * u - 0.5 * u^2; u_min=0.0, u_max=100.0, max_step=5.0)
        unit_b = DynamicUnit("B", 5.0, u -> 30.0 * u - 0.3 * u^2; u_min=0.0, u_max=100.0, max_step=5.0)
        econ(u, z) = (2.0 * z[("A", "y")] - 10.0 * u[("A", "u")]) + (1.5 * z[("B", "y")] - 8.0 * u[("B", "u")])
        budget(model, u, z) = @constraint(model, u[("A", "u")] + u[("B", "u")] <= 60.0)

        history = run_real_time_loop([unit_a, unit_b], econ, budget; n_ticks=30, dt=1.0,
            u_init=Dict(("A", "u") => 0.0, ("B", "u") => 0.0))

        @test length(history) == 30
        last_tick = history[end]
        @test isapprox(last_tick.u_applied[("A", "u")], 30.0; atol=1.0)
        @test isapprox(last_tick.u_applied[("B", "u")], 30.0; atol=1.0)
        # with no measurement noise and a model that matches the simulated plant
        # exactly, the reconciled estimate should track the true state closely.
        @test isapprox(last_tick.y_hat[("A", "y")], last_tick.y_true[("A", "y")]; atol=1e-6)
        @test isapprox(last_tick.y_hat[("B", "y")], last_tick.y_true[("B", "y")]; atol=1e-6)

        # the rate limit must never be exceeded between consecutive ticks
        prev_u = Dict(("A", "u") => 0.0, ("B", "u") => 0.0)
        for tick in history
            @test abs(tick.u_applied[("A", "u")] - prev_u[("A", "u")]) <= unit_a.max_step["u"] + 1e-9
            @test abs(tick.u_applied[("B", "u")] - prev_u[("B", "u")]) <= unit_b.max_step["u"] + 1e-9
            prev_u = tick.u_applied
        end
    end

    @testset "run_real_time_loop: multivariable unit converges alongside single-input units" begin
        unit_a = DynamicUnit("A", 5.0, u -> 40.0 * u - 0.5 * u^2; u_min=0.0, u_max=100.0, max_step=5.0)
        gain(u) = Dict(
            "top" => 50.0 * u["reflux"] + 5.0 * u["duty"] - 0.5 * u["reflux"]^2,
            "bottoms" => 40.0 * u["duty"] + 8.0 * u["reflux"] - 0.4 * u["duty"]^2,
        )
        unit_col = DynamicUnit("COL", ["reflux", "duty"], ["top", "bottoms"],
            Dict("top" => 8.0, "bottoms" => 6.0), gain;
            u_min=Dict("reflux" => 0.0, "duty" => 0.0),
            u_max=Dict("reflux" => 100.0, "duty" => 100.0),
            max_step=Dict("reflux" => 5.0, "duty" => 5.0))

        econ(u, z) = (2.0 * z[("A", "y")] - 10.0 * u[("A", "u")]) +
                     (2.0 * z[("COL", "top")] - 10.0 * u[("COL", "reflux")] +
                      1.5 * z[("COL", "bottoms")] - 6.0 * u[("COL", "duty")])
        no_constraints(model, u, z) = nothing

        history = run_real_time_loop([unit_a, unit_col], econ, no_constraints; n_ticks=40, dt=1.0,
            u_init=Dict(("A", "u") => 0.0, ("COL", "reflux") => 0.0, ("COL", "duty") => 0.0))

        last_tick = history[end]
        @test isapprox(last_tick.u_applied[("A", "u")], 35.0; atol=1.0)
        @test isapprox(last_tick.u_applied[("COL", "reflux")], 51.0; atol=1.0)
        @test isapprox(last_tick.u_applied[("COL", "duty")], 64.0 / 1.2; atol=1.0)
    end

    @testset "run_real_time_loop: with measurement noise, stays reproducibly close to optimum" begin
        unit_a = DynamicUnit("A", 5.0, u -> 40.0 * u - 0.5 * u^2; u_min=0.0, u_max=100.0, max_step=5.0)
        unit_b = DynamicUnit("B", 5.0, u -> 30.0 * u - 0.3 * u^2; u_min=0.0, u_max=100.0, max_step=5.0)
        econ(u, z) = (2.0 * z[("A", "y")] - 10.0 * u[("A", "u")]) + (1.5 * z[("B", "y")] - 8.0 * u[("B", "u")])
        budget(model, u, z) = @constraint(model, u[("A", "u")] + u[("B", "u")] <= 60.0)

        rng = Random.MersenneTwister(1234)
        history = run_real_time_loop([unit_a, unit_b], econ, budget; n_ticks=40, dt=1.0,
            u_init=Dict(("A", "u") => 0.0, ("B", "u") => 0.0), measurement_noise_std=1.0, rng=rng)

        last_tick = history[end]
        @test isapprox(last_tick.u_applied[("A", "u")], 30.0; atol=3.0)
        @test isapprox(last_tick.u_applied[("B", "u")], 30.0; atol=3.0)
    end
end
