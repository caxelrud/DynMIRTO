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

    @testset "cold start: a real deadlock, not a crash" begin
        statics, templates, sources, units, opcost, products = build_scenario()

        # u starts at the unit's u_min (0 by default), so REF's initial
        # availability is 0 and the first tick's blend cannot reach the
        # octane spec using only FILL (RON 80 < 90). This is a genuine
        # limitation of pure shadow-price-driven coordination, discovered
        # by running this scenario (not assumed away): an infeasible blend
        # falls back to a price of exactly 0.0 for every sourced component,
        # so the reformer's economic objective becomes strictly "produce
        # nothing" (any u > 0 only adds cost for zero revenue) -- a
        # self-reinforcing deadlock with no gradient pointing out of it, not
        # a transient it ramps out of. See DESIGN.md section 11.5.
        #
        # This test verifies that behavior precisely (no crash, no silent
        # wrong answer): it should stay pinned at u=0 for the whole run.
        history = run_coordinated_loop(statics, templates, sources, units, opcost, products; n_ticks=20, dt=1.0)

        @test length(history) == 20
        @test all(t -> t.blend_result.status == :infeasible, history)
        @test all(t -> isapprox(t.unit_tick.u_applied[("REFORMER", "u")], 0.0; atol=1e-9), history)
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
