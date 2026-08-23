using JSON3

"""
    load_scenario(path) -> (components::Vector{Component}, products::Vector{Product})

Load a scenario from a JSON file. See `data/examples/regular_unleaded.json`
for the expected shape:

```json
{
  "components": [
    {"id": "REF", "name": "Reformate", "cost": 58.0, "available": 4000,
     "min_available": 0, "properties": {"RON": 98.0, "RVP": 3.0}}
  ],
  "products": [
    {"id": "REG", "name": "Regular Unleaded", "demand": 1000, "price": 0,
     "specs": {"RON": {"min": 87.0, "blend_rule": "index"}},
     "eligible_components": null}
  ]
}
```
"""
function load_scenario(path::AbstractString)
    raw = JSON3.read(read(path, String))
    components = Component[]
    for rc in raw.components
        props = Dict{Symbol,Float64}(Symbol(k) => Float64(v) for (k, v) in pairs(get(rc, :properties, (;))))
        push!(components, Component(
            String(rc.id), String(rc.name), Float64(rc.cost), Float64(rc.available);
            min_available=Float64(get(rc, :min_available, 0.0)),
            properties=props,
        ))
    end

    products = Product[]
    for rp in raw.products
        specs = Dict{Symbol,PropertySpec}()
        for (k, rs) in pairs(get(rp, :specs, (;)))
            specs[Symbol(k)] = PropertySpec(;
                min=_maybe_float(get(rs, :min, nothing)),
                max=_maybe_float(get(rs, :max, nothing)),
                blend_rule=Symbol(get(rs, :blend_rule, "linear")),
            )
        end
        elig = get(rp, :eligible_components, nothing)
        elig_vec = elig === nothing ? nothing : String.(elig)
        push!(products, Product(
            String(rp.id), String(rp.name), Float64(rp.demand);
            price=Float64(get(rp, :price, 0.0)),
            specs=specs,
            eligible_components=elig_vec,
        ))
    end

    return components, products
end

_maybe_float(::Nothing) = nothing
_maybe_float(x) = Float64(x)
