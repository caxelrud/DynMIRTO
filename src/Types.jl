"""
Per-property spec on a product: acceptable [min, max] range (either bound
may be `nothing` for one-sided specs) and the blending rule to use when
combining components for that property.

`blend_rule` is `:linear` (volume-weighted average is physically correct,
e.g. sulfur, density, benzene) or `:index` (must be converted through a
registered blending index before it blends linearly — e.g. RON, RVP; see
`BlendIndices.jl`).
"""
struct PropertySpec
    min::Union{Float64,Nothing}
    max::Union{Float64,Nothing}
    blend_rule::Symbol

    function PropertySpec(; min=nothing, max=nothing, blend_rule::Symbol=:linear)
        blend_rule in (:linear, :index) ||
            error("blend_rule must be :linear or :index, got :$blend_rule")
        min === nothing || max === nothing || min <= max ||
            error("PropertySpec min ($min) must be <= max ($max)")
        new(min, max, blend_rule)
    end
end

"""
A blendstock available to the optimizer: its cost, how much of it is on
hand, and its quality properties.

`min_available` is a *must-use floor* (e.g. a tank that has to be cleared
this period), not a typical constraint — it defaults to 0.
"""
struct Component
    id::String
    name::String
    cost::Float64
    available::Float64
    min_available::Float64
    properties::Dict{Symbol,Float64}

    function Component(id, name, cost, available; min_available=0.0, properties=Dict{Symbol,Float64}())
        available >= min_available ||
            error("Component $id: available ($available) must be >= min_available ($min_available)")
        new(id, name, Float64(cost), Float64(available), Float64(min_available), properties)
    end
end

"""
A blend header / finished-product target: how much to produce and the
specs it must meet. `eligible_components` restricts which components may
feed this product; `nothing` means all components in the scenario are
eligible.
"""
struct Product
    id::String
    name::String
    demand::Float64
    price::Float64
    specs::Dict{Symbol,PropertySpec}
    eligible_components::Union{Vector{String},Nothing}

    function Product(id, name, demand; price=0.0, specs=Dict{Symbol,PropertySpec}(), eligible_components=nothing)
        demand >= 0 || error("Product $id: demand must be >= 0")
        new(id, name, Float64(demand), Float64(price), specs, eligible_components)
    end
end

is_eligible(c::Component, p::Product) =
    p.eligible_components === nothing || c.id in p.eligible_components

"""
Result of solving one product's blend: the recipe (volumes/fractions),
the resulting quality (in real, non-index units), and its cost.
"""
struct BlendRecipe
    product_id::String
    volumes::Dict{String,Float64}
    fractions::Dict{String,Float64}
    resulting_properties::Dict{Symbol,Float64}
    cost::Float64
end
