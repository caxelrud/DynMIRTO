using Random
using JuMP

@testset "DynamicOptimization" begin

    @testset "step_state matches the exact exponential solution" begin
        unit = DynamicUnit("A", 10.0, u -> 2.0 * u; u_min=0.0, u_max=100.0, max_step=10.0)

        # z = f(5) = 10; after dt == tau, decay = exp(-1)
        y1 = step_state(0.0, 5.0, unit, 10.0)
        @test isapprox(y1, 10.0 + (0.0 - 10.0) * exp(-1.0); atol=1e-12)

        # dt = 0 leaves the state unchanged
        @test isapprox(step_state(3.0, 5.0, unit, 0.0), 3.0; atol=1e-12)

        # after many time constants, the state has essentially settled to z
        y_settled = step_state(0.0, 5.0, unit, 50.0 * unit.tau)
        @test isapprox(y_settled, 10.0; atol=1e-9)
    end

    @testset "reconcile: closed-form weighted average and its boundary cases" begin
        unit = DynamicUnit("A", 10.0, u -> 2.0 * u; u_min=0.0, u_max=100.0, max_step=10.0)
        predicted = step_state(0.0, 5.0, unit, 10.0)   # same as y1 above

        # all weight on the model: recovers the prediction exactly
        @test isapprox(reconcile(0.0, 5.0, 999.0, unit, 10.0; w_model=1.0, w_meas=0.0), predicted; atol=1e-9)
        # all weight on the measurement: recovers the measurement exactly
        @test isapprox(reconcile(0.0, 5.0, 999.0, unit, 10.0; w_model=0.0, w_meas=1.0), 999.0; atol=1e-9)
        # equal weights: simple average
        expected = (predicted + 999.0) / 2
        @test isapprox(reconcile(0.0, 5.0, 999.0, unit, 10.0; w_model=1.0, w_meas=1.0), expected; atol=1e-9)
    end

    @testset "successive_lp_optimize: single concave unit matches the calculus optimum" begin
        # f(u) = 40u - 0.5u^2; econ = price*f(u) - cost*u = 2*(40u-0.5u^2) - 10u = 70u - u^2
        # d/du = 70 - 2u = 0  =>  u* = 35, objective* = 70*35 - 35^2 = 1225
        unit = DynamicUnit("A", 5.0, u -> 40.0 * u - 0.5 * u^2; u_min=0.0, u_max=100.0, max_step=100.0)
        econ(u, z) = 2.0 * z["A"] - 10.0 * u["A"]
        no_constraints(model, u, z) = nothing

        u_opt, status = successive_lp_optimize([unit], Dict("A" => 0.0), econ, no_constraints)
        @test status == :optimal
        @test isapprox(u_opt["A"], 35.0; atol=1e-2)

        obj = econ(u_opt, Dict("A" => unit.steady_state_gain(u_opt["A"])))
        @test isapprox(obj, 1225.0; atol=1e-1)
    end

    @testset "successive_lp_optimize: two units, binding budget, matches the Lagrangian optimum" begin
        # f_A(u) = 40u - 0.5u^2, price 2.0, cost 10.0  -> unconstrained optimum at u=35
        # f_B(u) = 30u - 0.3u^2, price 1.5, cost 8.0   -> unconstrained optimum at u=41.11
        # Budget u_A + u_B <= 60 is binding; equal-marginal-value solution (hand-derived
        # via Lagrange multipliers): u_A = 30, u_B = 30, total econ = 1905.
        unit_a = DynamicUnit("A", 5.0, u -> 40.0 * u - 0.5 * u^2; u_min=0.0, u_max=100.0, max_step=100.0)
        unit_b = DynamicUnit("B", 5.0, u -> 30.0 * u - 0.3 * u^2; u_min=0.0, u_max=100.0, max_step=100.0)

        econ(u, z) = (2.0 * z["A"] - 10.0 * u["A"]) + (1.5 * z["B"] - 8.0 * u["B"])
        budget(model, u, z) = @constraint(model, u["A"] + u["B"] <= 60.0)

        u_opt, status = successive_lp_optimize([unit_a, unit_b], Dict("A" => 0.0, "B" => 0.0), econ, budget)
        @test status == :optimal
        @test isapprox(u_opt["A"], 30.0; atol=0.5)
        @test isapprox(u_opt["B"], 30.0; atol=0.5)
        @test u_opt["A"] + u_opt["B"] <= 60.0 + 1e-6

        z_opt = Dict("A" => unit_a.steady_state_gain(u_opt["A"]), "B" => unit_b.steady_state_gain(u_opt["B"]))
        @test isapprox(econ(u_opt, z_opt), 1905.0; atol=2.0)
    end

    @testset "run_real_time_loop: no noise, converges to the constrained optimum under a rate limit" begin
        unit_a = DynamicUnit("A", 5.0, u -> 40.0 * u - 0.5 * u^2; u_min=0.0, u_max=100.0, max_step=5.0)
        unit_b = DynamicUnit("B", 5.0, u -> 30.0 * u - 0.3 * u^2; u_min=0.0, u_max=100.0, max_step=5.0)
        econ(u, z) = (2.0 * z["A"] - 10.0 * u["A"]) + (1.5 * z["B"] - 8.0 * u["B"])
        budget(model, u, z) = @constraint(model, u["A"] + u["B"] <= 60.0)

        history = run_real_time_loop([unit_a, unit_b], econ, budget; n_ticks=30, dt=1.0,
            u_init=Dict("A" => 0.0, "B" => 0.0))

        @test length(history) == 30
        last_tick = history[end]
        @test isapprox(last_tick.u_applied["A"], 30.0; atol=1.0)
        @test isapprox(last_tick.u_applied["B"], 30.0; atol=1.0)
        # with no measurement noise and a model that matches the simulated plant
        # exactly, the reconciled estimate should track the true state closely.
        @test isapprox(last_tick.y_hat["A"], last_tick.y_true["A"]; atol=1e-6)
        @test isapprox(last_tick.y_hat["B"], last_tick.y_true["B"]; atol=1e-6)

        # the rate limit must never be exceeded between consecutive ticks
        prev_u = Dict("A" => 0.0, "B" => 0.0)
        for tick in history
            @test abs(tick.u_applied["A"] - prev_u["A"]) <= unit_a.max_step + 1e-9
            @test abs(tick.u_applied["B"] - prev_u["B"]) <= unit_b.max_step + 1e-9
            prev_u = tick.u_applied
        end
    end

    @testset "run_real_time_loop: with measurement noise, stays reproducibly close to optimum" begin
        unit_a = DynamicUnit("A", 5.0, u -> 40.0 * u - 0.5 * u^2; u_min=0.0, u_max=100.0, max_step=5.0)
        unit_b = DynamicUnit("B", 5.0, u -> 30.0 * u - 0.3 * u^2; u_min=0.0, u_max=100.0, max_step=5.0)
        econ(u, z) = (2.0 * z["A"] - 10.0 * u["A"]) + (1.5 * z["B"] - 8.0 * u["B"])
        budget(model, u, z) = @constraint(model, u["A"] + u["B"] <= 60.0)

        rng = Random.MersenneTwister(1234)
        history = run_real_time_loop([unit_a, unit_b], econ, budget; n_ticks=40, dt=1.0,
            u_init=Dict("A" => 0.0, "B" => 0.0), measurement_noise_std=1.0, rng=rng)

        last_tick = history[end]
        @test isapprox(last_tick.u_applied["A"], 30.0; atol=3.0)
        @test isapprox(last_tick.u_applied["B"], 30.0; atol=3.0)
    end
end
