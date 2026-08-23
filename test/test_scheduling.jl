@testset "Scheduling" begin

    @testset "hand-verifiable single tank, single component" begin
        # No blending choice at all (one component, no specs) -- this
        # isolates the inventory-balance bookkeeping from the blend math.
        c = Component("C", "Only stock", 10.0, 0.0)  # available/min_available ignored here
        tank = Tank("T1", "C", 0.0, 1000.0, 300.0)
        p = ScheduledProduct("P", "Test", Dict(1 => 200.0, 2 => 250.0))
        receipts = Dict((("T1", 2)) => 400.0)

        result = optimize_schedule([c], [tank], [p], receipts, 1:2)
        @test result.status == :optimal

        @test isapprox(result.tank_levels[("T1", 1)], 100.0; atol=1e-6)   # 300 - 200
        @test isapprox(result.tank_levels[("T1", 2)], 250.0; atol=1e-6)   # 100 + 400 - 250

        @test isapprox(result.recipes[("P", 1)].volumes["C"], 200.0; atol=1e-6)
        @test isapprox(result.recipes[("P", 2)].volumes["C"], 250.0; atol=1e-6)
        @test isapprox(result.recipes[("P", 1)].cost + result.recipes[("P", 2)].cost, 10.0 * 450.0; atol=1e-3)
    end

    @testset "capacity_min binds exactly" begin
        c = Component("C", "Only stock", 10.0, 0.0)
        tank = Tank("T1", "C", 50.0, 1000.0, 250.0)
        p = ScheduledProduct("P", "Test", Dict(1 => 200.0))

        result = optimize_schedule([c], [tank], [p], Dict{Tuple{String,Int},Float64}(), 1:1)
        @test result.status == :optimal
        @test isapprox(result.tank_levels[("T1", 1)], 50.0; atol=1e-6)
    end

    @testset "infeasible: demand would breach capacity_min" begin
        c = Component("C", "Only stock", 10.0, 0.0)
        tank = Tank("T1", "C", 50.0, 1000.0, 100.0)
        p = ScheduledProduct("P", "Test", Dict(1 => 100.0))  # would need inv to hit 0 < capacity_min

        result = optimize_schedule([c], [tank], [p], Dict{Tuple{String,Int},Float64}(), 1:1)
        @test result.status == :infeasible
        @test !isempty(result.diagnostics)
    end

    @testset "reuses v1 blending-index machinery across periods" begin
        low = Component("LOW", "Low RON", 10.0, 0.0; properties=Dict(:RON => 85.0))
        high = Component("HIGH", "High RON", 50.0, 0.0; properties=Dict(:RON => 100.0))
        tank_low = Tank("TL", "LOW", 0.0, 10_000.0, 10_000.0)
        tank_high = Tank("TH", "HIGH", 0.0, 10_000.0, 50.0)  # scarce; refilled in period 2

        p = ScheduledProduct("P", "Test", Dict(1 => 100.0, 2 => 100.0);
            specs=Dict(:RON => PropertySpec(; min=92.0, blend_rule=:index)))
        receipts = Dict(("TH", 2) => 500.0)

        result = optimize_schedule([low, high], [tank_low, tank_high], [p], receipts, 1:2)
        @test result.status == :optimal
        @test result.recipes[("P", 1)].resulting_properties[:RON] >= 92.0 - 1e-6
        @test result.recipes[("P", 2)].resulting_properties[:RON] >= 92.0 - 1e-6
        # Period 1 is starved of HIGH (only 50 available), so it can use at
        # most 50 units of it -- period 2 has plenty after the receipt.
        @test result.recipes[("P", 1)].volumes["HIGH"] <= 50.0 + 1e-6
    end
end
