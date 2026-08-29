using Random

@testset "Coordination" begin

    # Shared scenario for both tests below:
    #   Product REG, demand 100/tick, spec RON >= 90 (linear rule).
    #   FILL: static, cost $40, RON 80 (below spec alone), always plentiful.
    #   REF: sourced from unit "REFORMER" -- cost $0 in the blend (all its
    #        real cost lives in the unit's operating_cost instead, so the
    #        blend-side shadow price purely reflects "value of more volume",
    #        not a mix of two cost concepts), RON 95 (above spec alone).
    #   REFORMER: single input "u" (feed setpoint), single output "rate"
    #        (production), rate(u) = 150*(1-exp(-u/80)), operating cost
    #        $30/unit of feed.
    #
    # Hand-derived equilibrium: since REF is both free and higher-quality
    # than FILL, the blend LP always uses *all* available REF (up to
    # demand=100) and fills the rest with FILL -- so as long as
    # 0 < rate(u) < 100, REF's availability constraint binds and its
    # shadow price equals exactly FILL's cost, $40 (the value of the
    # $40 substitute it displaces), independent of the octane spec.
    # Maximizing 40*rate(u) - 30*u:
    #   d/du = 40*150/80*exp(-u/80) - 30 = 0  =>  exp(-u/80) = 0.4
    #   =>  u* = -80*ln(0.4) = 73.297...,  rate* = 150*(1-0.4) = 90
    # (90 < 100, consistent with the "REF stays scarce" assumption above).

    function build_scenario()
        fill_template = Component("FILL", "Filler", 40.0, 1000.0; properties=Dict(:RON => 80.0))
        ref_template = Component("REF", "Reformate", 0.0, 0.0; properties=Dict(:RON => 95.0))
        reformer = DynamicUnit("REFORMER", 5.0, u -> 150.0 * (1.0 - exp(-u / 80.0));
            u_min=0.0, u_max=300.0, max_step=10.0)
        source = ComponentSource("REF", "REFORMER", "y")
        product = Product("REG", "Regular", 100.0; specs=Dict(:RON => PropertySpec(; min=90.0, blend_rule=:linear)))
        operating_cost = Dict(("REFORMER", "u") => 30.0)
        return [fill_template], [ref_template], [source], [reformer], operating_cost, [product]
    end

    @testset "converges to the hand-derived equilibrium (no noise, warm start)" begin
        statics, templates, sources, units, opcost, products = build_scenario()

        # Warm start (u=50 gives rate(50)=69.7, already enough REF to hit the
        # octane spec: min REF needed is 100*(90-80)/(95-80)=66.67) so every
        # tick is feasible and the "shadow price == $40" invariant holds
        # throughout, not just at the end.
        history = run_coordinated_loop(statics, templates, sources, units, opcost, products;
            n_ticks=40, dt=1.0, u_init=Dict(("REFORMER", "u") => 50.0))

        @test length(history) == 40
        for tick in history
            @test tick.blend_result.status == :optimal
            @test isapprox(tick.blend_result.component_shadow_prices["REF"], 40.0; atol=1e-6)
        end

        last_tick = history[end]
        @test isapprox(last_tick.unit_tick.u_applied[("REFORMER", "u")], 73.297; atol=0.5)
        @test isapprox(last_tick.unit_tick.y_hat[("REFORMER", "y")], 90.0; atol=1.0)

        # every recipe should indeed use all available REF plus just enough FILL
        last_recipe = last_tick.blend_result.recipes["REG"]
        ref_used = get(last_recipe.volumes, "REF", 0.0)
        @test isapprox(ref_used, last_tick.unit_tick.y_hat[("REFORMER", "y")]; atol=1e-6)
    end

    @testset "cold start with no floor_price: a real deadlock, not a crash" begin
        statics, templates, sources, units, opcost, products = build_scenario()

        # u starts at the unit's u_min (0 by default), so REF's initial
        # availability is 0 and the first tick's blend cannot reach the
        # octane spec using only FILL (RON 80 < 90). This is a genuine
        # limitation of pure shadow-price-driven coordination, discovered
        # by running this scenario (not assumed away): with the default
        # floor_price=0.0, an infeasible blend gives every sourced
        # component a price of exactly 0.0, so the reformer's economic
        # objective becomes strictly "produce nothing" (any u > 0 only adds
        # cost for zero revenue) -- a self-reinforcing deadlock with no
        # gradient pointing out of it, not a transient it ramps out of.
        # See DESIGN.md section 11.5. (The next test shows the fix.)
        #
        # This test verifies that behavior precisely (no crash, no silent
        # wrong answer): it should stay pinned at u=0 for the whole run.
        history = run_coordinated_loop(statics, templates, sources, units, opcost, products; n_ticks=20, dt=1.0)

        @test length(history) == 20
        @test all(t -> t.blend_result.status == :infeasible, history)
        @test all(t -> isapprox(t.unit_tick.u_applied[("REFORMER", "u")], 0.0; atol=1e-9), history)
    end

    @testset "cold start with a floor_price: escapes the deadlock" begin
        # Same cold start (u_min=0), but REF's ComponentSource now carries
        # floor_price=35.0 -- used only on infeasible ticks, as a minimum
        # incentive to keep producing instead of a bare 0.0.
        #
        # Hand-derived (checked independently before writing this test):
        # maximizing a *constant* price of 35 against the same operating
        # cost settles at u=62.62, rate=81.43 -- comfortably above the
        # 66.67 threshold needed for the blend to become feasible again.
        # 35 was deliberately chosen *not* to equal the true equilibrium
        # price of 40, to show the mechanism only needs to be "good enough
        # to bootstrap": once feasible, the real shadow price (still $40,
        # by the same displaces-FILL logic as the warm-start test) takes
        # back over and keeps pushing past 81.43 to the true optimum.
        statics, templates, sources0, units, opcost, products = build_scenario()
        sources = [ComponentSource(s.component_id, s.unit_id, s.rate_output_id; floor_price=35.0) for s in sources0]

        history = run_coordinated_loop(statics, templates, sources, units, opcost, products; n_ticks=40, dt=1.0)

        @test length(history) == 40
        @test history[1].blend_result.status == :infeasible
        # once it reaches feasibility, it must never fall back out of it
        first_optimal = findfirst(t -> t.blend_result.status == :optimal, history)
        @test first_optimal !== nothing
        @test all(t -> t.blend_result.status == :optimal, history[first_optimal:end])

        last_tick = history[end]
        @test isapprox(last_tick.unit_tick.u_applied[("REFORMER", "u")], 73.297; atol=0.5)
        @test isapprox(last_tick.unit_tick.y_hat[("REFORMER", "y")], 90.0; atol=1.0)
        @test isapprox(last_tick.blend_result.component_shadow_prices["REF"], 40.0; atol=1e-6)
    end

    @testset "with measurement noise, still settles near the equilibrium" begin
        statics, templates, sources, units, opcost, products = build_scenario()
        rng = Random.MersenneTwister(7)

        history = run_coordinated_loop(statics, templates, sources, units, opcost, products;
            n_ticks=60, dt=1.0, u_init=Dict(("REFORMER", "u") => 50.0),
            measurement_noise_std=1.0, rng=rng)

        last_tick = history[end]
        @test isapprox(last_tick.unit_tick.u_applied[("REFORMER", "u")], 73.297; atol=3.0)
    end
end

@testset "Coordination (v2: tanks)" begin

    # Same reformer/REF/FILL economics as the v1 coordination tests above,
    # but REF now lives in a Tank sourced via TankSource instead of being a
    # flat Component.available -- both FILL and REF get wide-open tanks
    # (huge capacity, huge/zero initial inventory as appropriate) so only
    # the receipt/inventory-balance mechanics are actually exercised, not
    # capacity limits. Demand is a flat 100/tick for every tick in the run,
    # keyed 1:n_ticks since each real-time tick *is* one v2 period here.
    # Hand-derived expectation: identical to the v1 test above, since a
    # tank that never accumulates a surplus (REF stays strictly scarcer
    # than the 100/tick demand throughout) reduces to exactly v1's flat
    # per-tick availability model -- confirmed against v1's own $40/
    # u*=73.297/rate*=90.0 figures by running both side by side before
    # writing this test (see DESIGN.md section 11.6).
    function build_tank_scenario(n_ticks; floor_price=0.0)
        fill = Component("FILL", "Filler", 40.0, 1000.0; properties=Dict(:RON => 80.0))
        ref = Component("REF", "Reformate", 0.0, 0.0; properties=Dict(:RON => 95.0))
        tank_fill = Tank("TFILL", "FILL", 0.0, 1_000_000.0, 1_000_000.0)
        tank_ref = Tank("TREF", "REF", 0.0, 1_000_000.0, 0.0)
        demand = Dict(t => 100.0 for t in 1:n_ticks)
        product = ScheduledProduct("REG", "Regular", demand;
            specs=Dict(:RON => PropertySpec(; min=90.0, blend_rule=:linear)))
        reformer = DynamicUnit("REFORMER", 5.0, u -> 150.0 * (1.0 - exp(-u / 80.0));
            u_min=0.0, u_max=300.0, max_step=10.0)
        source = TankSource("TREF", "REFORMER", "y"; floor_price=floor_price)
        opcost = Dict(("REFORMER", "u") => 30.0)
        return [fill, ref], [tank_fill, tank_ref], [source], [reformer], opcost, [product]
    end

    @testset "cross-validates against v1's hand-derived equilibrium (warm start)" begin
        components, tanks, sources, units, opcost, products = build_tank_scenario(40)

        history = run_coordinated_schedule_loop(components, tanks, sources, units, opcost, products;
            n_ticks=40, dt=1.0, u_init=Dict(("REFORMER", "u") => 50.0))

        @test length(history) == 40
        for t in history
            @test t.schedule_result.status == :optimal
            @test isapprox(t.schedule_result.tank_shadow_prices[("TREF", t.tick)], 40.0; atol=1e-6)
            # REF stays strictly scarcer than demand every tick, so it never
            # accumulates a carry-over surplus in the tank.
            @test isapprox(t.schedule_result.tank_levels[("TREF", t.tick)], 0.0; atol=1e-6)
        end

        last_tick = history[end]
        @test isapprox(last_tick.unit_tick.u_applied[("REFORMER", "u")], 73.297; atol=0.5)
        @test isapprox(last_tick.unit_tick.y_hat[("REFORMER", "y")], 90.0; atol=1.0)
    end

    @testset "cold start with no floor_price: the same deadlock as v1" begin
        components, tanks, sources, units, opcost, products = build_tank_scenario(20)

        history = run_coordinated_schedule_loop(components, tanks, sources, units, opcost, products;
            n_ticks=20, dt=1.0)

        @test length(history) == 20
        @test all(t -> t.schedule_result.status == :infeasible, history)
        @test all(t -> isapprox(t.unit_tick.u_applied[("REFORMER", "u")], 0.0; atol=1e-9), history)
    end

    @testset "cold start with a floor_price: escapes the deadlock" begin
        components, tanks, sources, units, opcost, products = build_tank_scenario(30; floor_price=35.0)

        history = run_coordinated_schedule_loop(components, tanks, sources, units, opcost, products;
            n_ticks=30, dt=1.0)

        @test history[1].schedule_result.status == :infeasible
        first_optimal = findfirst(t -> t.schedule_result.status == :optimal, history)
        @test first_optimal !== nothing
        @test all(t -> t.schedule_result.status == :optimal, history[first_optimal:end])

        last_tick = history[end]
        @test isapprox(last_tick.unit_tick.u_applied[("REFORMER", "u")], 73.297; atol=0.5)
        @test isapprox(last_tick.schedule_result.tank_shadow_prices[("TREF", last_tick.tick)], 40.0; atol=1e-6)
    end

    @testset "genuine cross-tick accumulation: a fixed-rate source builds up a buffer" begin
        # Unlike v1's coordination (memoryless between ticks), a tank here
        # really does carry inventory forward. To verify that mechanic in
        # isolation from any shadow-price economics, this unit's
        # steady-state gain ignores its input entirely (a constant rate),
        # so successive_lp_optimize has nothing to optimize and u stays
        # put -- what's under test is purely the tank bookkeeping.
        #
        # tau=0.01 with dt=1.0 means each tick's dynamics settle to the
        # steady-state gain for all practical purposes (exp(-1/0.01)~0),
        # so y_hat is the constant 50.0 from tick 1. With demand a flat
        # 30/tick and a single component/tank (no FILL alternative to draw
        # from), the tank should accumulate a surplus of exactly 20/tick,
        # starting from initial_inventory=0: 20, 40, 60, 80, 100.
        ref = Component("REF", "Reformate", 0.0, 0.0; properties=Dict(:RON => 90.0))
        tank = Tank("TREF", "REF", 0.0, 1_000_000.0, 0.0)
        demand = Dict(t => 30.0 for t in 1:5)
        product = ScheduledProduct("REG", "Regular", demand)
        pump = DynamicUnit("PUMP", 0.01, u -> 50.0; u_min=0.0, u_max=0.0, max_step=1.0)
        source = TankSource("TREF", "PUMP", "y")

        history = run_coordinated_schedule_loop([ref], [tank], [source], [pump],
            Dict{Tuple{String,String},Float64}(), [product]; n_ticks=5, dt=1.0)

        @test length(history) == 5
        expected_levels = [20.0, 40.0, 60.0, 80.0, 100.0]
        for (t, expected) in zip(history, expected_levels)
            @test t.schedule_result.status == :optimal
            @test isapprox(t.unit_tick.y_hat[("PUMP", "y")], 50.0; atol=1e-6)
            @test isapprox(t.schedule_result.tank_levels[("TREF", t.tick)], expected; atol=1e-6)
        end
    end
end
