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

# ╔═╡ 3ce35b18-9f34-11f1-a020-593bb331cbb0
begin
	import Pkg
	Pkg.activate(joinpath(@__DIR__, ".notebook_env"))
	Pkg.develop(path=joinpath(@__DIR__, ".."))
	Pkg.add(["PlutoUI"])
	using DynMIRTO
	using PlutoUI
end


# ╔═╡ 3ce358ca-9f34-11f1-9aa7-29e2d6433192
md"""
# DynMIRTO — Interactive Blend Explorer

Move the sliders below to change component economics/availability or
product specs, and the optimal blend recipe recomputes live.

This notebook uses the `DynMIRTO` package from this repo directly (via
`Pkg.develop`), so it always reflects the current state of `src/`.
"""


# ╔═╡ 3ce35b2c-9f34-11f1-a310-9312825131d0
begin
	base_components, base_products = load_scenario(joinpath(@__DIR__, "..", "data", "examples", "regular_unleaded.json"))
	base_product = only(base_products)
end


# ╔═╡ 3ce35b36-9f34-11f1-ae87-830765a6dff9
md"""## Controls"""


# ╔═╡ 3ce35b40-9f34-11f1-8128-e7b440b8307a
md"**Reformate cost** (\$ per volume unit)"


# ╔═╡ 3ce35b40-9f34-11f1-b974-d53df08783df
@bind ref_cost Slider(40.0:1.0:80.0; default=58.0, show_value=true)


# ╔═╡ 3ce35b54-9f34-11f1-9aea-4dc71b2baf99
md"**FCC gasoline available** (volume units)"


# ╔═╡ 3ce35b5e-9f34-11f1-b515-b14d5657a26d
@bind fcc_available Slider(500.0:100.0:4000.0; default=3000.0, show_value=true)


# ╔═╡ 3ce35b5e-9f34-11f1-b510-c118a482b483
md"**Regular unleaded — minimum RON**"


# ╔═╡ 3ce35b68-9f34-11f1-a363-cd76af79c7a8
@bind ron_min Slider(85.0:0.5:95.0; default=87.0, show_value=true)


# ╔═╡ 3ce35b72-9f34-11f1-bff0-a353b2284369
md"**Regular unleaded — maximum sulfur (ppm)**"


# ╔═╡ 3ce35b7c-9f34-11f1-8a97-911608fd9f28
@bind sulfur_max Slider(10.0:5.0:150.0; default=80.0, show_value=true)


# ╔═╡ 3ce35b86-9f34-11f1-ae59-db32e6907b05
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


# ╔═╡ 3ce35b92-9f34-11f1-9997-13159350b3bf
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


# ╔═╡ 3ce35bfe-9f34-11f1-8a1f-7792231c89ea
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


# ╔═╡ 3ce35c08-9f34-11f1-b7b5-fd1cf47e3d19
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


# ╔═╡ 3ce35c12-9f34-11f1-b413-3b3c78e154f8
begin
	io = IOBuffer()
	if result.status == :optimal
		print_report(io, product, result.recipes[product.id])
	else
		println(io, "Infeasible:")
		for d in result.diagnostics
			println(io, "  - ", d)
		end
	end
	Text(String(take!(io)))
end


# ╔═╡ Cell order:
# ╠═3ce358ca-9f34-11f1-9aa7-29e2d6433192
# ╠═3ce35b18-9f34-11f1-a020-593bb331cbb0
# ╠═3ce35b2c-9f34-11f1-a310-9312825131d0
# ╠═3ce35b36-9f34-11f1-ae87-830765a6dff9
# ╠═3ce35b40-9f34-11f1-8128-e7b440b8307a
# ╠═3ce35b40-9f34-11f1-b974-d53df08783df
# ╠═3ce35b54-9f34-11f1-9aea-4dc71b2baf99
# ╠═3ce35b5e-9f34-11f1-b515-b14d5657a26d
# ╠═3ce35b5e-9f34-11f1-b510-c118a482b483
# ╠═3ce35b68-9f34-11f1-a363-cd76af79c7a8
# ╠═3ce35b72-9f34-11f1-bff0-a353b2284369
# ╠═3ce35b7c-9f34-11f1-8a97-911608fd9f28
# ╠═3ce35b86-9f34-11f1-ae59-db32e6907b05
# ╠═3ce35b92-9f34-11f1-9997-13159350b3bf
# ╠═3ce35bfe-9f34-11f1-8a1f-7792231c89ea
# ╠═3ce35c08-9f34-11f1-b7b5-fd1cf47e3d19
# ╠═3ce35c12-9f34-11f1-b413-3b3c78e154f8
