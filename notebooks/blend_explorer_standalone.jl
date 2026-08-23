### A Pluto.jl notebook ###
# v1.0.3

using Markdown
using InteractiveUtils

# This Pluto notebook uses @bind for interactivity. When running this notebook outside of Pluto, the following 'mock version' of @bind gives bound variables a default value (instead of an error).
macro bind(def, element)
    #! format: off
    return quote
        local iv = try Base.loaded_modules[Base.PkgId(Base.UUID("6e696c72-6542-2067-7265-42206c756150"), "AbstractPlutoDingetjes")].Bonds.initial_value catch; b -> missing; end
        local el = $(esc(element))
        global $(esc(def)) = Core.applicable(Base.get, el) ? Base.get(el) : iv(el)
        el
    end
    #! format: on
end

# ╔═╡ d124b632-9f39-11f1-8cd1-178076da1c96
begin
	using JuMP
	using HiGHS
	using PlutoUI
end


# ╔═╡ d124b57e-9f39-11f1-8e9b-d7141fc2b3bf
md"""
# DynMIRTO — Blend Explorer (standalone)

A self-contained copy of the blend-optimization logic from
[caxelrud/DynMIRTO](https://github.com/caxelrud/DynMIRTO), inlined here so
this single file has no dependency on the rest of the repo — only
registered packages (JuMP, HiGHS, PlutoUI). That means it can run via
Pluto's built-in "Edit or run this notebook" → Binder button, including
from a phone browser, with no local Julia install.

This mirrors `src/Types.jl`, `src/BlendIndices.jl`, and `src/Optimizer.jl`
in the repo as of when this notebook was last updated — it is not
auto-synced, so re-copy from `src/` if those change. For local
development against the live package, use `notebooks/blend_explorer.jl`
instead.

Move the sliders below to change component economics/availability or
product specs; the optimal blend recipe recomputes live.
"""


# ╔═╡ d124b63c-9f39-11f1-9304-81107af12a8f
begin
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

	struct BlendRecipe
		product_id::String
		volumes::Dict{String,Float64}
		fractions::Dict{String,Float64}
		resulting_properties::Dict{Symbol,Float64}
		cost::Float64
	end
end


# ╔═╡ d124b648-9f39-11f1-81c1-df63f9b5b9cb
begin
	const _INDEX_REGISTRY = Dict{Symbol,NamedTuple{(:to_index, :from_index),Tuple{Function,Function}}}()

	function register_blend_index!(property::Symbol, to_index::Function, from_index::Function)
		_INDEX_REGISTRY[property] = (to_index=to_index, from_index=from_index)
		return nothing
	end

	has_blend_index(property::Symbol) = haskey(_INDEX_REGISTRY, property)

	function to_index_space(property::Symbol, value::Float64)
		has_blend_index(property) ||
			error("No blending index registered for property :$property.")
		_INDEX_REGISTRY[property].to_index(value)
	end

	function from_index_space(property::Symbol, value::Float64)
		has_blend_index(property) ||
			error("No blending index registered for property :$property.")
		_INDEX_REGISTRY[property].from_index(value)
	end

	# RVP: power-law approximation `BI = RVP^1.25`, a commonly cited
	# approximation for RVP's non-linear blending behavior.
	register_blend_index!(:RVP, rvp -> rvp^1.25, bi -> bi^(1 / 1.25))

	# RON / MON: real octane blending indices are refinery- and
	# crude-slate-specific. This exponent is an ILLUSTRATIVE placeholder
	# demonstrating the index mechanism — not a calibrated correlation.
	register_blend_index!(:RON, ron -> ron^1.06, bi -> bi^(1 / 1.06))
	register_blend_index!(:MON, mon -> mon^1.06, bi -> bi^(1 / 1.06))
end


# ╔═╡ d124b918-9f39-11f1-8ba7-556415e2d130
begin
	function _to_solver_space(rule::Symbol, prop::Symbol, value::Float64)
		rule === :linear && return value
		rule === :index && return to_index_space(prop, value)
		error("Unknown blend_rule :$rule")
	end

	function _from_solver_space(rule::Symbol, prop::Symbol, value::Float64)
		rule === :linear && return value
		rule === :index && return from_index_space(prop, value)
		error("Unknown blend_rule :$rule")
	end

	struct OptimizationResult
		status::Symbol
		recipes::Dict{String,BlendRecipe}
		diagnostics::Vector{String}
	end

	function _prevalidate(components::Vector{Component}, products::Vector{Product}, pairs::Vector{Tuple{String,String}})
		notes = String[]
		comp_by_id = Dict(c.id => c for c in components)

		for p in products
			eligible_ids = [cid for (cid, pid) in pairs if pid == p.id]
			if isempty(eligible_ids)
				push!(notes, "Product $(p.id): no eligible components at all.")
				continue
			end
			total_available = sum(comp_by_id[cid].available for cid in eligible_ids)
			if total_available < p.demand
				push!(notes,
					"Product $(p.id): demand ($(p.demand)) exceeds total available volume " *
					"of eligible components ($(total_available)).")
			end
			total_floor = sum(comp_by_id[cid].min_available for cid in eligible_ids)
			if total_floor > p.demand
				push!(notes,
					"Product $(p.id): sum of component must-use minimums ($(total_floor)) " *
					"exceeds demand ($(p.demand)).")
			end
			for (prop, spec) in p.specs
				vals = [comp_by_id[cid].properties[prop] for cid in eligible_ids if haskey(comp_by_id[cid].properties, prop)]
				isempty(vals) && continue
				lo, hi = extrema(vals)
				if spec.max !== nothing && lo > spec.max
					push!(notes,
						"Product $(p.id), property :$prop: every eligible component " *
						"($(lo)-$(hi)) exceeds the max spec ($(spec.max)); no blend can meet it.")
				end
				if spec.min !== nothing && hi < spec.min
					push!(notes,
						"Product $(p.id), property :$prop: every eligible component " *
						"($(lo)-$(hi)) is below the min spec ($(spec.min)); no blend can meet it.")
				end
			end
		end

		return notes
	end

	function optimize_blend(components::Vector{Component}, products::Vector{Product};
		optimizer=HiGHS.Optimizer)

		isempty(components) && error("optimize_blend: no components given")
		isempty(products) && error("optimize_blend: no products given")

		pairs = Tuple{String,String}[]
		for p in products, c in components
			is_eligible(c, p) && push!(pairs, (c.id, p.id))
		end

		diagnostics = _prevalidate(components, products, pairs)
		if !isempty(diagnostics)
			return OptimizationResult(:infeasible, Dict{String,BlendRecipe}(), diagnostics)
		end

		model = Model(optimizer)
		set_silent(model)

		x = Dict{Tuple{String,String},JuMP.VariableRef}()
		for (cid, pid) in pairs
			x[(cid, pid)] = @variable(model, lower_bound = 0, base_name = "x_$(cid)_$(pid)")
		end

		comp_by_id = Dict(c.id => c for c in components)

		for p in products
			vars = [x[(c.id, p.id)] for c in components if haskey(x, (c.id, p.id))]
			isempty(vars) && continue
			@constraint(model, sum(vars) == p.demand)
		end

		for c in components
			vars = [x[(c.id, p.id)] for p in products if haskey(x, (c.id, p.id))]
			isempty(vars) && continue
			@constraint(model, sum(vars) <= c.available)
			if c.min_available > 0
				@constraint(model, sum(vars) >= c.min_available)
			end
		end

		for p in products, (prop, spec) in p.specs
			vars_vals = Tuple{JuMP.VariableRef,Float64}[]
			for c in components
				haskey(x, (c.id, p.id)) || continue
				haskey(c.properties, prop) ||
					error("Component $(c.id) is eligible for product $(p.id) but has no value for property :$prop")
				val = _to_solver_space(spec.blend_rule, prop, c.properties[prop])
				push!(vars_vals, (x[(c.id, p.id)], val))
			end
			isempty(vars_vals) && continue
			weighted = sum(v * val for (v, val) in vars_vals)
			if spec.min !== nothing
				lo = _to_solver_space(spec.blend_rule, prop, spec.min)
				@constraint(model, weighted >= lo * p.demand)
			end
			if spec.max !== nothing
				hi = _to_solver_space(spec.blend_rule, prop, spec.max)
				@constraint(model, weighted <= hi * p.demand)
			end
		end

		@objective(model, Min, sum(comp_by_id[cid].cost * v for ((cid, _), v) in x))

		optimize!(model)
		status = termination_status(model)

		if status != MOI.OPTIMAL
			note = "Solver returned $(status). This can mean the specs/availability are " *
				"infeasible together, or (rarely) numerical trouble."
			return OptimizationResult(:infeasible, Dict{String,BlendRecipe}(), [note])
		end

		recipes = Dict{String,BlendRecipe}()
		for p in products
			volumes = Dict{String,Float64}()
			for c in components
				haskey(x, (c.id, p.id)) || continue
				v = value(x[(c.id, p.id)])
				v > 1e-9 && (volumes[c.id] = v)
			end
			fractions = Dict(cid => v / p.demand for (cid, v) in volumes)
			cost = sum(comp_by_id[cid].cost * v for (cid, v) in volumes; init=0.0)

			resulting = Dict{Symbol,Float64}()
			all_props = Set{Symbol}()
			for cid in keys(volumes)
				union!(all_props, keys(comp_by_id[cid].properties))
			end
			for prop in all_props
				rule = haskey(p.specs, prop) ? p.specs[prop].blend_rule : :linear
				weighted = sum(_to_solver_space(rule, prop, comp_by_id[cid].properties[prop]) * v
								for (cid, v) in volumes if haskey(comp_by_id[cid].properties, prop); init=0.0)
				resulting[prop] = _from_solver_space(rule, prop, weighted / p.demand)
			end

			recipes[p.id] = BlendRecipe(p.id, volumes, fractions, resulting, cost)
		end

		return OptimizationResult(:optimal, recipes, String[])
	end
end


# ╔═╡ d124b920-9f39-11f1-bbeb-954feb3f2eed
begin
	base_components = [
		Component("BUT", "Butane", 45.0, 200.0; properties=Dict(:RON=>92.0, :RVP=>52.0, :sulfur_ppm=>0.0, :benzene_pct=>0.0)),
		Component("REF", "Reformate", 58.0, 3000.0; properties=Dict(:RON=>98.0, :RVP=>3.0, :sulfur_ppm=>5.0, :benzene_pct=>1.8)),
		Component("FCC", "FCC Gasoline", 52.0, 3000.0; properties=Dict(:RON=>91.0, :RVP=>5.0, :sulfur_ppm=>300.0, :benzene_pct=>0.5)),
		Component("ALK", "Alkylate", 60.0, 2000.0; properties=Dict(:RON=>96.0, :RVP=>5.0, :sulfur_ppm=>1.0, :benzene_pct=>0.0)),
	]
	base_product = Product("REG", "Regular Unleaded", 1000.0;
		specs=Dict(
			:RON => PropertySpec(; min=87.0, blend_rule=:index),
			:RVP => PropertySpec(; max=9.0, blend_rule=:index),
			:sulfur_ppm => PropertySpec(; max=80.0, blend_rule=:linear),
			:benzene_pct => PropertySpec(; max=1.3, blend_rule=:linear),
		))
end


# ╔═╡ d124b92a-9f39-11f1-8f2a-27cf17b135c0
md"""## Controls"""


# ╔═╡ d124b934-9f39-11f1-8a5c-295ff76a6a83
md"**Reformate cost** (\$ per volume unit)"


# ╔═╡ d124b93e-9f39-11f1-97d1-8d1f81544322
@bind ref_cost Slider(40.0:1.0:80.0; default=58.0, show_value=true)


# ╔═╡ d124b946-9f39-11f1-92b2-6da2010af5bc
md"**FCC gasoline available** (volume units)"


# ╔═╡ d124b946-9f39-11f1-8bfa-fbebb9ecdf62
@bind fcc_available Slider(500.0:100.0:4000.0; default=3000.0, show_value=true)


# ╔═╡ d124b952-9f39-11f1-ba19-a5628d1e3c84
md"**Regular unleaded — minimum RON**"


# ╔═╡ d124b95c-9f39-11f1-912d-87ecf3ebefd5
@bind ron_min Slider(85.0:0.5:95.0; default=87.0, show_value=true)


# ╔═╡ d124b966-9f39-11f1-84bd-afd56a85ef30
md"**Regular unleaded — maximum sulfur (ppm)**"


# ╔═╡ d124b970-9f39-11f1-a20a-435f830683a6
@bind sulfur_max Slider(10.0:5.0:150.0; default=80.0, show_value=true)


# ╔═╡ d124b970-9f39-11f1-bd0b-bf0dc2cc6ef9
begin
	function override_component(c)
		c.id == "REF" && return Component(c.id, c.name, ref_cost, c.available; min_available=c.min_available, properties=c.properties)
		c.id == "FCC" && return Component(c.id, c.name, c.cost, fcc_available; min_available=c.min_available, properties=c.properties)
		return c
	end
	components = override_component.(base_components)
	product = Product(base_product.id, base_product.name, base_product.demand;
		price=base_product.price,
		specs=merge(base_product.specs, Dict(
			:RON => PropertySpec(; min=ron_min, blend_rule=:index),
			:sulfur_ppm => PropertySpec(; max=sulfur_max, blend_rule=:linear),
		)),
		eligible_components=base_product.eligible_components)
	result = optimize_blend(components, [product])
end


# ╔═╡ d124b978-9f39-11f1-b111-39361fe35104
begin
	comp_rows = join([
		"<tr><td>$(c.id)</td><td>$(c.name)</td><td>$(round(c.cost;digits=2))</td><td>$(round(c.available;digits=1))</td>" *
		"<td>$(get(c.properties,:RON,"-"))</td><td>$(get(c.properties,:RVP,"-"))</td>" *
		"<td>$(get(c.properties,:sulfur_ppm,"-"))</td><td>$(get(c.properties,:benzene_pct,"-"))</td></tr>"
		for c in components
	])
	HTML("""
	<h4>Current component slate</h4>
	<table>
	<tr><th>id</th><th>name</th><th>cost</th><th>available</th><th>RON</th><th>RVP</th><th>sulfur_ppm</th><th>benzene_pct</th></tr>
	$comp_rows
	</table>
	""")
end


# ╔═╡ d124bac4-9f39-11f1-9226-ff403a53c52a
if result.status == :optimal
	recipe = result.recipes[product.id]
	bars = join([
		"""<div style="margin:6px 0;">
			<div style="font-family:monospace;font-size:0.9em;">$(cid): $(round(vol; digits=1)) ($(round(100*recipe.fractions[cid]; digits=1))%)</div>
			<div style="background:#e3e3e3;border-radius:3px;overflow:hidden;width:320px;">
				<div style="width:$(100*recipe.fractions[cid])%;background:#4c78a8;height:14px;"></div>
			</div>
		</div>"""
		for (cid, vol) in sort(collect(recipe.volumes); by=first)
	])
	HTML("<h4>Recipe (cost = $(round(recipe.cost; digits=2)))</h4>$bars")
else
	diag_items = join(["<li>$d</li>" for d in result.diagnostics])
	HTML("<h4 style=\"color:#b00;\">Infeasible</h4><ul>$diag_items</ul>")
end


# ╔═╡ d124bace-9f39-11f1-be71-3dc3d0b6047c
if result.status == :optimal
	recipe2 = result.recipes[product.id]
	spec_rows = join([
		"<tr><td>$(prop)</td><td>$(round(get(recipe2.resulting_properties, prop, NaN); digits=3))</td>" *
		"<td>$(spec.min === nothing ? "-" : spec.min)</td><td>$(spec.max === nothing ? "-" : spec.max)</td></tr>"
		for (prop, spec) in sort(collect(product.specs); by=first)
	])
	HTML("""
	<h4>Resulting quality vs. spec</h4>
	<table>
	<tr><th>Property</th><th>Value</th><th>Min</th><th>Max</th></tr>
	$spec_rows
	</table>
	""")
else
	HTML("<h4>Resulting quality vs. spec</h4><p>Scenario is infeasible with the current sliders — see diagnostics above.</p>")
end


# ╔═╡ 00000000-0000-0000-0000-000000000001
PLUTO_PROJECT_TOML_CONTENTS = """
[deps]
HiGHS = "87dc4568-4c63-4d18-b0c0-bb2238e4078b"
JuMP = "4076af6c-e467-56ae-b986-b466b2749572"
PlutoUI = "7f904dfe-b85e-4ff6-b463-dae2292396a8"

[compat]
HiGHS = "~1.24.1"
JuMP = "~1.31.2"
PlutoUI = "~0.7.83"
"""

# ╔═╡ 00000000-0000-0000-0000-000000000002
PLUTO_MANIFEST_TOML_CONTENTS = """
# This file is machine-generated - editing it directly is not advised

julia_version = "1.12.7"
manifest_format = "2.0"
project_hash = "41434f7bac3f1fe733a8cc19e2916512631bd149"

[[deps.AbstractPlutoDingetjes]]
git-tree-sha1 = "6c3913f4e9bdf6ba3c08041a446fb1332716cbc2"
uuid = "6e696c72-6542-2067-7265-42206c756150"
version = "1.4.0"

[[deps.ArgTools]]
uuid = "0dad84c5-d112-42e6-8d28-ef12dabb789f"
version = "1.1.2"

[[deps.Artifacts]]
uuid = "56f22d72-fd6d-98f1-02f0-08ddc0907c33"
version = "1.11.0"

[[deps.Base64]]
uuid = "2a0f44e3-6c83-55bd-87e4-b1978d98bd5f"
version = "1.11.0"

[[deps.Bzip2_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "1b96ea4a01afe0ea4090c5c8039690672dd13f2e"
uuid = "6e34b625-4abd-537c-b88f-471c36dfa7a0"
version = "1.0.9+0"

[[deps.CodecBzip2]]
deps = ["Bzip2_jll", "TranscodingStreams"]
git-tree-sha1 = "84990fa864b7f2b4901901ca12736e45ee79068c"
uuid = "523fee87-0ab8-5b00-afb7-3ecf72e48cfd"
version = "0.8.5"

[[deps.CodecZlib]]
deps = ["TranscodingStreams", "Zlib_jll"]
git-tree-sha1 = "970758a3d591a2a5c2a907c53f2e2f8c1b1d3537"
uuid = "944b1d66-785c-5afd-91f1-9de20f533193"
version = "0.7.9"

[[deps.ColorTypes]]
deps = ["FixedPointNumbers", "Random"]
git-tree-sha1 = "67e11ee83a43eb71ddc950302c53bf33f0690dfe"
uuid = "3da002f7-5984-5a60-b8a6-cbb66c0b333f"
version = "0.12.1"
weakdeps = ["StyledStrings"]

    [deps.ColorTypes.extensions]
    StyledStringsExt = "StyledStrings"

[[deps.CommonSubexpressions]]
deps = ["MacroTools"]
git-tree-sha1 = "cda2cfaebb4be89c9084adaca7dd7333369715c5"
uuid = "bbf7d656-a473-5ed7-a52c-81e309532950"
version = "0.3.1"

[[deps.CompilerSupportLibraries_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "e66e0078-7015-5450-92f7-15fbd957f2ae"
version = "1.3.1+2"

[[deps.Dates]]
deps = ["Printf"]
uuid = "ade2ca70-3891-5945-98fb-dc099432e06a"
version = "1.11.0"

[[deps.DiffResults]]
deps = ["StaticArraysCore"]
git-tree-sha1 = "782dd5f4561f5d267313f23853baaaa4c52ea621"
uuid = "163ba53b-c6d8-5494-b064-1a9d43ac40c5"
version = "1.1.0"

[[deps.DiffRules]]
deps = ["IrrationalConstants", "LogExpFunctions", "NaNMath", "Random", "SpecialFunctions"]
git-tree-sha1 = "79a2aca180a85c690c58a020d47b426954b590f8"
uuid = "b552c78f-8df3-52c6-915a-8e097449b14b"
version = "1.16.0"

[[deps.DocStringExtensions]]
git-tree-sha1 = "7442a5dfe1ebb773c29cc2962a8980f47221d76c"
uuid = "ffbed154-4ef7-542d-bbb7-c09d3a79fcae"
version = "0.9.5"

[[deps.Downloads]]
deps = ["ArgTools", "FileWatching", "LibCURL", "NetworkOptions"]
uuid = "f43a241f-c20a-4ad4-852c-f6b1247861c6"
version = "1.7.0"

[[deps.FileWatching]]
uuid = "7b1f6079-737a-58dc-b8bc-7a2ca5c1b5ee"
version = "1.11.0"

[[deps.FixedPointNumbers]]
deps = ["Random", "Statistics"]
git-tree-sha1 = "59af96b98217c6ef4ae0dfe065ac7c20831d1a84"
uuid = "53c48c17-4a7d-5ca2-90c5-79b7896eea93"
version = "0.8.6"

[[deps.ForwardDiff]]
deps = ["CommonSubexpressions", "DiffResults", "DiffRules", "LinearAlgebra", "LogExpFunctions", "NaNMath", "Preferences", "Printf", "Random", "SpecialFunctions"]
git-tree-sha1 = "1b86cca764a61dcac4fef4c5e16e378e5ed6953c"
uuid = "f6369f11-7733-5829-9624-2563aa707210"
version = "1.4.5"

    [deps.ForwardDiff.extensions]
    ForwardDiffStaticArraysExt = "StaticArrays"

    [deps.ForwardDiff.weakdeps]
    StaticArrays = "90137ffa-7385-5640-81b9-e52037218182"

[[deps.HiGHS]]
deps = ["HiGHS_jll", "LinearAlgebra", "MathOptIIS", "MathOptInterface", "OpenBLAS32_jll", "PrecompileTools", "SparseArrays"]
git-tree-sha1 = "01a5241985559c08a5baadbcebd6d87daaf84a84"
uuid = "87dc4568-4c63-4d18-b0c0-bb2238e4078b"
version = "1.24.1"

[[deps.HiGHS_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "JLLWrappers", "Libdl", "Zlib_jll", "libblastrampoline_jll"]
git-tree-sha1 = "2d9747b79d17c4320fe48048a3a768fe6d6d82de"
uuid = "8fd58aa0-07eb-5a78-9b36-339c94fd15ea"
version = "1.15.1+1"

[[deps.Hyperscript]]
deps = ["Test"]
git-tree-sha1 = "179267cfa5e712760cd43dcae385d7ea90cc25a4"
uuid = "47d2ed2b-36de-50cf-bf87-49c2cf4b8b91"
version = "0.0.5"

[[deps.HypertextLiteral]]
deps = ["Tricks"]
git-tree-sha1 = "d1a86724f81bcd184a38fd284ce183ec067d71a0"
uuid = "ac1192a8-f4b3-4bfe-ba22-af5b92cd3ab2"
version = "1.0.0"

[[deps.IOCapture]]
deps = ["Logging", "Random"]
git-tree-sha1 = "0ee181ec08df7d7c911901ea38baf16f755114dc"
uuid = "b5f81e59-6552-4d32-b1f0-c071b021bf89"
version = "1.0.0"

[[deps.InteractiveUtils]]
deps = ["Markdown"]
uuid = "b77e0a4c-d291-57a0-90e8-8db25a27a240"
version = "1.11.0"

[[deps.IrrationalConstants]]
git-tree-sha1 = "b2d91fe939cae05960e760110b328288867b5758"
uuid = "92d709cd-6900-40b7-9082-c6be49f344b6"
version = "0.2.6"

[[deps.JLLWrappers]]
deps = ["Artifacts", "Preferences"]
git-tree-sha1 = "7204148362dafe5fe6a273f855b8ccbe4df8173e"
uuid = "692b3bcd-3c85-4b1f-b108-f13ce0eb3210"
version = "1.8.0"

[[deps.JSON]]
deps = ["Dates", "Logging", "Parsers", "PrecompileTools", "StructUtils", "UUIDs", "Unicode"]
git-tree-sha1 = "c7345ab1a7ca4dc8a02c9f6510da0d9857bbe513"
uuid = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"
version = "1.7.1"

    [deps.JSON.extensions]
    JSONArrowExt = ["ArrowTypes"]

    [deps.JSON.weakdeps]
    ArrowTypes = "31f734f8-188a-4ce0-8406-c8a06bd891cd"

[[deps.JuMP]]
deps = ["LinearAlgebra", "MacroTools", "MathOptInterface", "MutableArithmetics", "OrderedCollections", "PrecompileTools", "Printf", "SparseArrays"]
git-tree-sha1 = "4f27b21df3b47e8c08a83ead049afb621b2f5b3c"
uuid = "4076af6c-e467-56ae-b986-b466b2749572"
version = "1.31.2"

    [deps.JuMP.extensions]
    JuMPDimensionalDataExt = "DimensionalData"

    [deps.JuMP.weakdeps]
    DimensionalData = "0703355e-b756-11e9-17c0-8b28908087d0"

[[deps.JuliaSyntaxHighlighting]]
deps = ["StyledStrings"]
uuid = "ac6e5ff7-fb65-4e79-a425-ec3bc9c03011"
version = "1.12.0"

[[deps.LibCURL]]
deps = ["LibCURL_jll", "MozillaCACerts_jll"]
uuid = "b27032c2-a3e7-50c8-80cd-2d36dbcbfd21"
version = "0.6.4"

[[deps.LibCURL_jll]]
deps = ["Artifacts", "LibSSH2_jll", "Libdl", "OpenSSL_jll", "Zlib_jll", "nghttp2_jll"]
uuid = "deac9b47-8bc7-5906-a0fe-35ac56dc84c0"
version = "8.15.0+0"

[[deps.LibSSH2_jll]]
deps = ["Artifacts", "Libdl", "OpenSSL_jll"]
uuid = "29816b5a-b9ab-546f-933c-edad1886dfa8"
version = "1.11.3+1"

[[deps.Libdl]]
uuid = "8f399da3-3557-5675-b5ff-fb832c97cbdb"
version = "1.11.0"

[[deps.LinearAlgebra]]
deps = ["Libdl", "OpenBLAS_jll", "libblastrampoline_jll"]
uuid = "37e2e46d-f89d-539d-b4ee-838fcccc9c8e"
version = "1.12.0"

[[deps.LogExpFunctions]]
deps = ["DocStringExtensions", "IrrationalConstants", "LinearAlgebra"]
git-tree-sha1 = "bba2d9aa057d8f126415de240573e86a8f39d2a1"
uuid = "2ab3a3ac-af41-5b50-aa03-7779005ae688"
version = "1.0.1"

    [deps.LogExpFunctions.extensions]
    LogExpFunctionsChainRulesCoreExt = "ChainRulesCore"
    LogExpFunctionsChangesOfVariablesExt = "ChangesOfVariables"
    LogExpFunctionsInverseFunctionsExt = "InverseFunctions"

    [deps.LogExpFunctions.weakdeps]
    ChainRulesCore = "d360d2e6-b24c-11e9-a2a3-2a2ae2dbcce4"
    ChangesOfVariables = "9e997f8a-9a97-42d5-a9f1-ce6bfc15e2c0"
    InverseFunctions = "3587e190-3f89-42d0-90ee-14403ec27112"

[[deps.Logging]]
uuid = "56ddb016-857b-54e1-b83d-db4d58db5568"
version = "1.11.0"

[[deps.MIMEs]]
git-tree-sha1 = "c64d943587f7187e751162b3b84445bbbd79f691"
uuid = "6c6e2e6c-3030-632d-7369-2d6c69616d65"
version = "1.1.0"

[[deps.MacroTools]]
git-tree-sha1 = "1e0228a030642014fe5cfe68c2c0a818f9e3f522"
uuid = "1914dd2f-81c6-5fcd-8719-6d5c9610ff09"
version = "0.5.16"

[[deps.Markdown]]
deps = ["Base64", "JuliaSyntaxHighlighting", "StyledStrings"]
uuid = "d6f4376e-aef5-505a-96c1-9c027394607a"
version = "1.11.0"

[[deps.MathOptIIS]]
deps = ["MathOptInterface"]
git-tree-sha1 = "3b3d69130d8ab8c39d5fa4d30e20a8e6428c9d37"
uuid = "8c4f8055-bd93-4160-a86b-a0c04941dbff"
version = "0.2.0"

[[deps.MathOptInterface]]
deps = ["CodecBzip2", "CodecZlib", "ForwardDiff", "JSON", "LinearAlgebra", "MutableArithmetics", "NaNMath", "OrderedCollections", "PrecompileTools", "Printf", "SparseArrays", "SpecialFunctions", "Test"]
git-tree-sha1 = "f1ccd9ffcb8577e207deb9aaebeb3f961de70380"
uuid = "b8f27783-ece8-5eb3-8dc8-9495eed66fee"
version = "1.52.0"

    [deps.MathOptInterface.extensions]
    MathOptInterfaceBenchmarkToolsExt = "BenchmarkTools"
    MathOptInterfaceCliqueTreesExt = "CliqueTrees"

    [deps.MathOptInterface.weakdeps]
    BenchmarkTools = "6e4b80f9-dd63-53aa-95a3-0cdb28fa8baf"
    CliqueTrees = "60701a23-6482-424a-84db-faee86b9b1f8"

[[deps.MozillaCACerts_jll]]
uuid = "14a3606d-f60d-562e-9121-12d972cd8159"
version = "2025.11.4"

[[deps.MutableArithmetics]]
deps = ["LinearAlgebra", "SparseArrays", "Test"]
git-tree-sha1 = "dc5b2c4c111c46bc79ac4405eeb563523b39c004"
uuid = "d8a4904e-b15c-11e9-3269-09a3773c0cb0"
version = "1.8.0"

[[deps.NaNMath]]
deps = ["OpenLibm_jll"]
git-tree-sha1 = "dbd2e8cd2c1c27f0b584f6661b4309609c5a685e"
uuid = "77ba4419-2d1f-58cd-9bb1-8ffee604a2e3"
version = "1.1.4"

[[deps.NetworkOptions]]
uuid = "ca575930-c2e3-43a9-ace4-1e988b2c1908"
version = "1.3.0"

[[deps.OpenBLAS32_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "JLLWrappers", "Libdl", "libblastrampoline_jll"]
git-tree-sha1 = "30870d0f2dc0b2dba76b10df1c58c7f018413e56"
uuid = "656ef2d0-ae68-5445-9ca0-591084a874a2"
version = "0.3.34+0"

[[deps.OpenBLAS_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "Libdl"]
uuid = "4536629a-c528-5b80-bd46-f80d51c5b363"
version = "0.3.29+0"

[[deps.OpenLibm_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "05823500-19ac-5b8b-9628-191a04bc5112"
version = "0.8.7+0"

[[deps.OpenSSL_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "458c3c95-2e84-50aa-8efc-19380b2a3a95"
version = "3.5.6+0"

[[deps.OpenSpecFun_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "JLLWrappers", "Libdl"]
git-tree-sha1 = "1346c9208249809840c91b26703912dff463d335"
uuid = "efe28fd5-8261-553b-a9e1-b2916fc3738e"
version = "0.5.6+0"

[[deps.OrderedCollections]]
git-tree-sha1 = "05f45c2e0de6259db764adbfd2f1dc6d3f8de13c"
uuid = "bac558e1-5e72-5ebc-8fee-abe8a469f55d"
version = "2.0.1"

[[deps.Parsers]]
deps = ["Dates", "PrecompileTools", "UUIDs"]
git-tree-sha1 = "3de8f5e6e90ebfa8d6d1f86997d6cdcd6a912ff3"
uuid = "69de0a69-1ddd-5017-9359-2bf0b02dc9f0"
version = "2.8.7"

[[deps.PlutoUI]]
deps = ["AbstractPlutoDingetjes", "Base64", "ColorTypes", "Dates", "Downloads", "FixedPointNumbers", "Hyperscript", "HypertextLiteral", "IOCapture", "InteractiveUtils", "Logging", "MIMEs", "Markdown", "Random", "Reexport", "URIs", "UUIDs"]
git-tree-sha1 = "e189d0623e7ce9c37389bac17e80aac3b0302e75"
uuid = "7f904dfe-b85e-4ff6-b463-dae2292396a8"
version = "0.7.83"

[[deps.PrecompileTools]]
deps = ["Preferences"]
git-tree-sha1 = "edbeefc7a4889f528644251bdb5fc9ab5348bc2c"
uuid = "aea7be01-6a6a-4083-8856-8a6e6704d82a"
version = "1.3.4"

[[deps.Preferences]]
deps = ["TOML"]
git-tree-sha1 = "8b770b60760d4451834fe79dd483e318eee709c4"
uuid = "21216c6a-2e73-6563-6e65-726566657250"
version = "1.5.2"

[[deps.Printf]]
deps = ["Unicode"]
uuid = "de0858da-6303-5e67-8744-51eddeeeb8d7"
version = "1.11.0"

[[deps.Random]]
deps = ["SHA"]
uuid = "9a3f8284-a2c9-5f02-9a11-845980a1fd5c"
version = "1.11.0"

[[deps.Reexport]]
git-tree-sha1 = "45e428421666073eab6f2da5c9d310d99bb12f9b"
uuid = "189a3867-3050-52da-a836-e630ba90ab69"
version = "1.2.2"

[[deps.SHA]]
uuid = "ea8e919c-243c-51af-8825-aaa63cd721ce"
version = "0.7.0"

[[deps.Serialization]]
uuid = "9e88b42a-f829-5b0c-bbe9-9e923198166b"
version = "1.11.0"

[[deps.SparseArrays]]
deps = ["Libdl", "LinearAlgebra", "Random", "Serialization", "SuiteSparse_jll"]
uuid = "2f01184e-e22b-5df5-ae63-d93ebab69eaf"
version = "1.12.0"

[[deps.SpecialFunctions]]
deps = ["IrrationalConstants", "LogExpFunctions", "OpenLibm_jll", "OpenSpecFun_jll"]
git-tree-sha1 = "429071b23f4c9a13fb6582f807cc2ef454082408"
uuid = "276daf66-3868-5448-9aa4-cd146d93841b"
version = "2.9.0"

    [deps.SpecialFunctions.extensions]
    SpecialFunctionsChainRulesCoreExt = "ChainRulesCore"

    [deps.SpecialFunctions.weakdeps]
    ChainRulesCore = "d360d2e6-b24c-11e9-a2a3-2a2ae2dbcce4"

[[deps.StaticArraysCore]]
git-tree-sha1 = "6ab403037779dae8c514bad259f32a447262455a"
uuid = "1e83bf80-4336-4d27-bf5d-d5a4f845583c"
version = "1.4.4"

[[deps.Statistics]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "ae3bb1eb3bba077cd276bc5cfc337cc65c3075c0"
uuid = "10745b16-79ce-11e8-11f9-7d13ad32a3b2"
version = "1.11.1"
weakdeps = ["SparseArrays"]

    [deps.Statistics.extensions]
    SparseArraysExt = ["SparseArrays"]

[[deps.StructUtils]]
deps = ["Dates", "UUIDs"]
git-tree-sha1 = "2d0fc55c61321ba245c47be599570d11bac50303"
uuid = "ec057cc2-7a8d-4b58-b3b3-92acb9f63b42"
version = "2.8.5"

    [deps.StructUtils.extensions]
    StructUtilsMeasurementsExt = ["Measurements"]
    StructUtilsStaticArraysCoreExt = ["StaticArraysCore"]
    StructUtilsTablesExt = ["Tables"]

    [deps.StructUtils.weakdeps]
    Measurements = "eff96d63-e80a-5855-80a2-b1b0885c5ab7"
    StaticArraysCore = "1e83bf80-4336-4d27-bf5d-d5a4f845583c"
    Tables = "bd369af6-aec1-5ad0-b16a-f7cc5008161c"

[[deps.StyledStrings]]
uuid = "f489334b-da3d-4c2e-b8f0-e476e12c162b"
version = "1.11.0"

[[deps.SuiteSparse_jll]]
deps = ["Artifacts", "Libdl", "libblastrampoline_jll"]
uuid = "bea87d4a-7f5b-5778-9afe-8cc45184846c"
version = "7.8.3+2"

[[deps.TOML]]
deps = ["Dates"]
uuid = "fa267f1f-6049-4f14-aa54-33bafae1ed76"
version = "1.0.3"

[[deps.Test]]
deps = ["InteractiveUtils", "Logging", "Random", "Serialization"]
uuid = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
version = "1.11.0"

[[deps.TranscodingStreams]]
git-tree-sha1 = "0c45878dcfdcfa8480052b6ab162cdd138781742"
uuid = "3bb67fe8-82b1-5028-8e26-92a6c54297fa"
version = "0.11.3"

[[deps.Tricks]]
git-tree-sha1 = "311349fd1c93a31f783f977a71e8b062a57d4101"
uuid = "410a4b4d-49e4-4fbc-ab6d-cb71b17b3775"
version = "0.1.13"

[[deps.URIs]]
git-tree-sha1 = "908fec9df6c5de98548ead82a468c95ccf6cd263"
uuid = "5c2747f8-b7ea-4ff2-ba2e-563bfd36b1d4"
version = "1.7.0"

[[deps.UUIDs]]
deps = ["Random", "SHA"]
uuid = "cf7118a7-6976-5b1a-9a39-7adc72f591a4"
version = "1.11.0"

[[deps.Unicode]]
uuid = "4ec0a83e-493e-50e2-b9ac-8f72acf5a8f5"
version = "1.11.0"

[[deps.Zlib_jll]]
deps = ["Libdl"]
uuid = "83775a58-1f1d-513f-b197-d71354ab007a"
version = "1.3.1+2"

[[deps.libblastrampoline_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "8e850b90-86db-534c-a0d3-1478176c7d93"
version = "5.15.0+0"

[[deps.nghttp2_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "8e850ede-7688-5339-a07c-302acd2aaf8d"
version = "1.64.0+1"
"""

# ╔═╡ Cell order:
# ╠═d124b57e-9f39-11f1-8e9b-d7141fc2b3bf
# ╠═d124b632-9f39-11f1-8cd1-178076da1c96
# ╠═d124b63c-9f39-11f1-9304-81107af12a8f
# ╠═d124b648-9f39-11f1-81c1-df63f9b5b9cb
# ╠═d124b918-9f39-11f1-8ba7-556415e2d130
# ╠═d124b920-9f39-11f1-bbeb-954feb3f2eed
# ╠═d124b92a-9f39-11f1-8f2a-27cf17b135c0
# ╠═d124b934-9f39-11f1-8a5c-295ff76a6a83
# ╠═d124b93e-9f39-11f1-97d1-8d1f81544322
# ╠═d124b946-9f39-11f1-92b2-6da2010af5bc
# ╠═d124b946-9f39-11f1-8bfa-fbebb9ecdf62
# ╠═d124b952-9f39-11f1-ba19-a5628d1e3c84
# ╠═d124b95c-9f39-11f1-912d-87ecf3ebefd5
# ╠═d124b966-9f39-11f1-84bd-afd56a85ef30
# ╠═d124b970-9f39-11f1-a20a-435f830683a6
# ╠═d124b970-9f39-11f1-bd0b-bf0dc2cc6ef9
# ╠═d124b978-9f39-11f1-b111-39361fe35104
# ╠═d124bac4-9f39-11f1-9226-ff403a53c52a
# ╠═d124bace-9f39-11f1-be71-3dc3d0b6047c
# ╟─00000000-0000-0000-0000-000000000001
# ╟─00000000-0000-0000-0000-000000000002
