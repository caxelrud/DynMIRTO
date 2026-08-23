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
    components = _parse_components(raw.components)

    products = Product[]
    for rp in raw.products
        specs = _parse_specs(get(rp, :specs, (;)))
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

"""
    load_schedule(path) -> (components, tanks, products, receipts, periods)

Load a multi-period scheduling scenario from a JSON file. See
`data/examples/schedule_example.json` for the expected shape:

```json
{
  "periods": 4,
  "components": [ ... same shape as load_scenario ... ],
  "tanks": [
    {"id": "T1", "component_id": "REF", "capacity_min": 0,
     "capacity_max": 5000, "initial_inventory": 2000}
  ],
  "receipts": [
    {"tank_id": "T1", "period": 3, "volume": 1000}
  ],
  "products": [
    {"id": "REG", "name": "Regular Unleaded", "specs": {...},
     "demand": {"1": 500, "2": 500, "3": 500, "4": 500}}
  ]
}
```
"""
function load_schedule(path::AbstractString)
    raw = JSON3.read(read(path, String))
    components = _parse_components(raw.components)

    tanks = [
        Tank(String(rt.id), String(rt.component_id), Float64(rt.capacity_min),
            Float64(rt.capacity_max), Float64(rt.initial_inventory))
        for rt in raw.tanks
    ]

    receipts = Dict{Tuple{String,Int},Float64}()
    for rr in get(raw, :receipts, [])
        receipts[(String(rr.tank_id), Int(rr.period))] = Float64(rr.volume)
    end

    products = ScheduledProduct[]
    for rp in raw.products
        specs = _parse_specs(get(rp, :specs, (;)))
        elig = get(rp, :eligible_components, nothing)
        elig_vec = elig === nothing ? nothing : String.(elig)
        demand = Dict{Int,Float64}(parse(Int, String(k)) => Float64(v) for (k, v) in pairs(rp.demand))
        push!(products, ScheduledProduct(
            String(rp.id), String(rp.name), demand;
            price=Float64(get(rp, :price, 0.0)),
            specs=specs,
            eligible_components=elig_vec,
        ))
    end

    periods = 1:Int(raw.periods)

    return components, tanks, products, receipts, periods
end

function _parse_components(raw_components)
    components = Component[]
    for rc in raw_components
        props = Dict{Symbol,Float64}(Symbol(k) => Float64(v) for (k, v) in pairs(get(rc, :properties, (;))))
        push!(components, Component(
            String(rc.id), String(rc.name), Float64(rc.cost), Float64(get(rc, :available, 0.0));
            min_available=Float64(get(rc, :min_available, 0.0)),
            properties=props,
        ))
    end
    return components
end

function _parse_specs(raw_specs)
    specs = Dict{Symbol,PropertySpec}()
    for (k, rs) in pairs(raw_specs)
        specs[Symbol(k)] = PropertySpec(;
            min=_maybe_float(get(rs, :min, nothing)),
            max=_maybe_float(get(rs, :max, nothing)),
            blend_rule=Symbol(get(rs, :blend_rule, "linear")),
        )
    end
    return specs
end

_maybe_float(::Nothing) = nothing
_maybe_float(x) = Float64(x)
