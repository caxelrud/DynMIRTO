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
