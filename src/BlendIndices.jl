"""
Registry of blending-index transforms for properties that do not blend
linearly by volume (RON, MON, RVP, ...).

A registered property has a `to_index` function (raw property -> index
space, where volume-weighted averaging is valid) and a `from_index`
inverse (index space -> raw property, for reporting/spec-checking). The
optimizer only ever averages in index space; it converts back to raw
units afterwards.

Register your own with `register_blend_index!` to override or add
properties; call `has_blend_index(prop)` to check what's available.
"""

const _INDEX_REGISTRY = Dict{Symbol,NamedTuple{(:to_index, :from_index),Tuple{Function,Function}}}()

function register_blend_index!(property::Symbol, to_index::Function, from_index::Function)
    _INDEX_REGISTRY[property] = (to_index=to_index, from_index=from_index)
    return nothing
end

has_blend_index(property::Symbol) = haskey(_INDEX_REGISTRY, property)

function to_index_space(property::Symbol, value::Float64)
    has_blend_index(property) ||
        error("No blending index registered for property :$property. " *
              "Register one with `register_blend_index!`, or use blend_rule=:linear for this property.")
    _INDEX_REGISTRY[property].to_index(value)
end

function from_index_space(property::Symbol, value::Float64)
    has_blend_index(property) ||
        error("No blending index registered for property :$property.")
    _INDEX_REGISTRY[property].from_index(value)
end

# --- Default registered indices --------------------------------------------
#
# RVP (Reid Vapor Pressure): a power-law transform `BI = RVP^1.25` is a
# commonly cited approximation for RVP's non-linear blending behavior in
# refinery blending references.
register_blend_index!(:RVP, rvp -> rvp^1.25, bi -> bi^(1 / 1.25))

# RON / MON (octane): real octane blending indices are refinery- and
# crude-slate-specific, fitted from plant data (this is a large part of
# what a production tool like AspenTech GDOT calibrates per site). The
# exponent below is an ILLUSTRATIVE placeholder that demonstrates the
# index mechanism end-to-end (index != raw value, but close to it for
# typical octane ranges) — replace it with a calibrated correlation (or
# re-register the property as :linear) before using this for real
# operational decisions.
register_blend_index!(:RON, ron -> ron^1.06, bi -> bi^(1 / 1.06))
register_blend_index!(:MON, mon -> mon^1.06, bi -> bi^(1 / 1.06))
