@testset "Optimizer" begin

    @testset "hand-verifiable single product, linear-only spec" begin
        # A: cost 10, RON 85 (below the 90 spec on its own)
        # B: cost 20, RON 100
        # Demand 100 @ RON >= 90 (linear rule, for an exact hand check).
        # Minimum blend fraction of B to hit RON 90: f solves
        #   85*(1-f) + 100*f = 90  =>  f = 1/3
        # Cost-minimal solution uses exactly that minimum (B is pricier).
        a = Component("A", "Cheap low-octane", 10.0, 1000.0; properties=Dict(:RON => 85.0))
        b = Component("B", "Pricey high-octane", 20.0, 1000.0; properties=Dict(:RON => 100.0))
        p = Product("P", "Test product", 100.0;
            specs=Dict(:RON => PropertySpec(; min=90.0, blend_rule=:linear)))

        result = optimize_blend([a, b], [p])
        @test result.status == :optimal
        recipe = result.recipes["P"]

        @test isapprox(recipe.volumes["B"], 100 / 3; atol=1e-4)
        @test isapprox(recipe.volumes["A"], 200 / 3; atol=1e-4)
        @test isapprox(recipe.cost, 4000 / 3; atol=1e-3)
        @test isapprox(recipe.resulting_properties[:RON], 90.0; atol=1e-6)
    end

    @testset "index-rule spec is respected end to end" begin
        a = Component("A", "Low RON", 10.0, 1000.0; properties=Dict(:RON => 85.0))
        b = Component("B", "High RON", 50.0, 1000.0; properties=Dict(:RON => 100.0))
        p = Product("P", "Test", 100.0;
            specs=Dict(:RON => PropertySpec(; min=92.0, blend_rule=:index)))

        result = optimize_blend([a, b], [p])
        @test result.status == :optimal
        recipe = result.recipes["P"]
        @test recipe.resulting_properties[:RON] >= 92.0 - 1e-6
    end

    @testset "infeasible: demand exceeds availability" begin
        a = Component("A", "Only component", 10.0, 50.0)
        p = Product("P", "Test", 100.0)
        result = optimize_blend([a], [p])
        @test result.status == :infeasible
        @test !isempty(result.diagnostics)
        @test occursin("exceeds total available", result.diagnostics[1])
    end

    @testset "infeasible: no component can meet the spec" begin
        a = Component("A", "Too low", 10.0, 1000.0; properties=Dict(:RON => 80.0))
        p = Product("P", "Test", 100.0;
            specs=Dict(:RON => PropertySpec(; min=90.0, blend_rule=:linear)))
        result = optimize_blend([a], [p])
        @test result.status == :infeasible
        @test any(occursin("below the min spec", d) for d in result.diagnostics)
    end

    @testset "shadow prices match hand-derived LP duality" begin
        # Cheaper AND better-quality component (REF) is scarce (available=70,
        # binding); pricier, worse FILL makes up the rest. Hand-derived: since
        # cost = 50*x_REF + 60*(100-x_REF) = 6000 - 10*x_REF is decreasing in
        # x_REF, the LP pushes x_REF to its cap; at x_REF=70 the RON spec
        # (90.5 >= 90) is already slack, so only availability binds.
        # Relaxing the cap by 1 unit saves exactly $10 (verified independently
        # against raw JuMP before writing this test).
        ref = Component("REF", "Reformate", 50.0, 70.0; properties=Dict(:RON => 95.0))
        fill_ = Component("FILL", "Filler", 60.0, 1000.0; properties=Dict(:RON => 80.0))
        p = Product("P", "Test", 100.0; specs=Dict(:RON => PropertySpec(; min=90.0, blend_rule=:linear)))

        result = optimize_blend([ref, fill_], [p])
        @test result.status == :optimal
        recipe = result.recipes["P"]
        @test isapprox(recipe.volumes["REF"], 70.0; atol=1e-6)
        @test isapprox(recipe.cost, 5300.0; atol=1e-3)
        @test isapprox(result.component_shadow_prices["REF"], 10.0; atol=1e-3)
        @test isapprox(result.component_shadow_prices["FILL"], 0.0; atol=1e-6)  # not binding
        @test isapprox(recipe.spec_shadow_prices[:RON], 0.0; atol=1e-6)  # RON slack (90.5 >= 90)

        # Max-type spec: cheap high-sulfur vs. pricier low-sulfur, sulfur <= 80
        # binds. Hand-derived (and cross-checked against raw JuMP): relaxing
        # the max by 1 ppm saves ~$0.0678 per unit of demand, i.e. ~$6.78 total.
        cheap = Component("LOW", "High sulfur", 40.0, 1000.0; properties=Dict(:sulfur_ppm => 300.0))
        pricey = Component("HIGH", "Low sulfur", 60.0, 1000.0; properties=Dict(:sulfur_ppm => 5.0))
        p2 = Product("P2", "Test", 100.0;
            specs=Dict(:sulfur_ppm => PropertySpec(; max=80.0, blend_rule=:linear)))
        result2 = optimize_blend([cheap, pricey], [p2])
        @test result2.status == :optimal
        @test isapprox(result2.recipes["P2"].spec_shadow_prices[:sulfur_ppm], 6.7797; atol=1e-3)

        # Min-type spec: cheap low-RON vs. pricier high-RON, RON >= 90 binds.
        # Hand-derived (and cross-checked against raw JuMP): tightening the
        # min by 1 RON point costs ~$153.85 total (demand=100).
        low_ron = Component("A", "Low RON", 40.0, 1000.0; properties=Dict(:RON => 85.0))
        high_ron = Component("B", "High RON", 60.0, 1000.0; properties=Dict(:RON => 98.0))
        p3 = Product("P3", "Test", 100.0; specs=Dict(:RON => PropertySpec(; min=90.0, blend_rule=:linear)))
        result3 = optimize_blend([low_ron, high_ron], [p3])
        @test result3.status == :optimal
        @test isapprox(result3.recipes["P3"].spec_shadow_prices[:RON], 153.846; atol=1e-2)
    end

    @testset "multi-product shared component pool" begin
        shared = Component("S", "Shared stock", 10.0, 150.0; properties=Dict(:RON => 95.0))
        cheap = Component("C", "Cheap filler", 5.0, 1000.0; properties=Dict(:RON => 80.0))
        p1 = Product("P1", "Needs octane", 100.0;
            specs=Dict(:RON => PropertySpec(; min=90.0, blend_rule=:linear)))
        p2 = Product("P2", "No spec", 100.0)

        result = optimize_blend([shared, cheap], [p1, p2])
        @test result.status == :optimal
        total_shared_used = sum(get(r.volumes, "S", 0.0) for r in values(result.recipes))
        @test total_shared_used <= 150.0 + 1e-6
        @test result.recipes["P1"].resulting_properties[:RON] >= 90.0 - 1e-6
        # P2 has no spec, so the optimizer should prefer the cheap filler for it.
        @test get(result.recipes["P2"].volumes, "C", 0.0) > get(result.recipes["P2"].volumes, "S", 0.0)
    end
end
