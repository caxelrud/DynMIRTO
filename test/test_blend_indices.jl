@testset "BlendIndices" begin
    @test has_blend_index(:RVP)
    @test has_blend_index(:RON)
    @test !has_blend_index(:sulfur_ppm)

    for prop in (:RVP, :RON, :MON)
        raw = 90.0
        idx = to_index_space(prop, raw)
        @test idx != raw
        @test isapprox(from_index_space(prop, idx), raw; atol=1e-9)
    end

    @test_throws ErrorException to_index_space(:not_registered, 1.0)

    register_blend_index!(:cetane, c -> c^1.1, bi -> bi^(1 / 1.1))
    @test has_blend_index(:cetane)
    @test isapprox(from_index_space(:cetane, to_index_space(:cetane, 45.0)), 45.0; atol=1e-9)
end
