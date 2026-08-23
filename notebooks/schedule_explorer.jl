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

# ╔═╡ 228a24d8-9f4b-11f1-9a7c-158d8b909a88
begin
	import Pkg
	Pkg.activate(joinpath(@__DIR__, ".notebook_env"))
	Pkg.develop(path=joinpath(@__DIR__, ".."))
	Pkg.add(["PlutoUI"])
	using DynMIRTO
	using PlutoUI
end


# ╔═╡ 228a23e8-9f4b-11f1-a039-713fc9cb9789
md"""
# DynMIRTO — Schedule Explorer

Interactive view of the v2 multi-period scheduler: tanks whose inventory
evolves over a horizon via scheduled receipts and blending draws, planned
against per-period demand.

Move the sliders below to change demand, the size of each scheduled
receipt, the octane spec, or how much butane the tank can hold — the whole
horizon re-solves and the tank-level grid and per-period recipes update
live.

Uses the `DynMIRTO` package straight from `src/` (via `Pkg.develop`), so
it always reflects the current code.
"""


# ╔═╡ 228a2530-9f4b-11f1-9afa-0df0fc717ef6
begin
	base_components, base_tanks, base_products, base_receipts, base_periods =
		load_schedule(joinpath(@__DIR__, "..", "data", "examples", "schedule_example.json"))
	base_product = only(base_products)
end


# ╔═╡ 228a2546-9f4b-11f1-a995-bf799a24790e
md"""## Controls"""


# ╔═╡ 228a2562-9f4b-11f1-9561-4314e255a43e
md"**Demand per period** (same target every period)"


# ╔═╡ 228a2562-9f4b-11f1-8e4c-e9bcfcc39f99
@bind demand_level Slider(300.0:25.0:900.0; default=500.0, show_value=true)


# ╔═╡ 228a256e-9f4b-11f1-a29c-1795f95bdf81
md"**Regular unleaded — minimum RON**"


# ╔═╡ 228a256e-9f4b-11f1-8b5a-2d41978a10e6
@bind ron_min Slider(85.0:0.5:95.0; default=87.0, show_value=true)


# ╔═╡ 228a2582-9f4b-11f1-9cf0-cfbd659c61c2
md"**Reformate receipt** at T-REF, period 3 (volume units)"


# ╔═╡ 228a258c-9f4b-11f1-b1e4-619c48588af1
@bind receipt_ref Slider(0.0:100.0:3000.0; default=1500.0, show_value=true)


# ╔═╡ 228a258c-9f4b-11f1-9bc2-4f450dc7b4c5
md"**FCC receipt** at T-FCC, period 2 (volume units)"


# ╔═╡ 228a2594-9f4b-11f1-9409-2db2b5310a7c
@bind receipt_fcc Slider(0.0:100.0:2000.0; default=800.0, show_value=true)


# ╔═╡ 228a25a0-9f4b-11f1-9370-2f23938f545c
md"**Alkylate receipt** at T-ALK, period 3 (volume units)"


# ╔═╡ 228a25a0-9f4b-11f1-ac6d-87572d19704b
@bind receipt_alk Slider(0.0:100.0:2000.0; default=600.0, show_value=true)


# ╔═╡ 228a25a0-9f4b-11f1-9181-152876923b51
md"**T-BUT tank capacity** (max volume it can hold)"


# ╔═╡ 228a25c8-9f4b-11f1-80bb-15f14cc167ac
@bind but_capacity_max Slider(100.0:50.0:1000.0; default=400.0, show_value=true)


# ╔═╡ 228a25e6-9f4b-11f1-97a4-2b4aa94321b4
begin
	function override_tank(tank)
		tank.id == "T-BUT" && return Tank(tank.id, tank.component_id, tank.capacity_min,
			but_capacity_max, min(tank.initial_inventory, but_capacity_max))
		return tank
	end
	tanks = override_tank.(base_tanks)

	receipts = Dict{Tuple{String,Int},Float64}(
		("T-REF", 3) => receipt_ref,
		("T-FCC", 2) => receipt_fcc,
		("T-ALK", 3) => receipt_alk,
	)

	demand = Dict(t => demand_level for t in base_periods)
	product = ScheduledProduct(base_product.id, base_product.name, demand;
		price=base_product.price,
		specs=merge(base_product.specs, Dict(
			:RON => PropertySpec(; min=ron_min, blend_rule=:index),
		)),
		eligible_components=base_product.eligible_components)

	result = optimize_schedule(base_components, tanks, [product], receipts, base_periods)
end


# ╔═╡ 228a25e6-9f4b-11f1-a8f7-252b78379143
let
	if result.status == :optimal
		periods_sorted = sort(collect(base_periods))
		header_cells = join(["<th>period $t</th>" for t in periods_sorted])
		rows = join([
			begin
				cells = join([
					begin
						level = result.tank_levels[(tank.id, t)]
						frac = tank.capacity_max > 0 ? level / tank.capacity_max : 0.0
						near_floor = isapprox(level, tank.capacity_min; atol=1e-2) || level <= tank.capacity_min + 1e-6
						cell_bg = near_floor ? "#f8d7d5" : "#f7f7f7"
						bar_bg = near_floor ? "#c0392b" : "#4c78a8"
						"""<td style="background:$cell_bg;">
							<div style="font-family:monospace;font-size:0.85em;">$(round(level; digits=1))</div>
							<div style="background:#e3e3e3;border-radius:3px;overflow:hidden;width:80px;min-width:80px;">
								<div style="width:$(max(100*frac, 3))%;background:$bar_bg;height:10px;"></div>
							</div>
						</td>"""
					end
					for t in periods_sorted
				])
				"<tr><td><b>$(tank.id)</b><br><span style=\"font-size:0.8em;color:#666;\">max $(round(tank.capacity_max;digits=0)), floor $(round(tank.capacity_min;digits=0))</span></td>$cells</tr>"
			end
			for tank in tanks
		])
		HTML("""
		<h4>Tank levels at end of each period</h4>
		<p style="font-size:0.85em;color:#666;">Pink = at or near its floor (capacity_min).</p>
		<table>
		<tr><th>tank</th>$header_cells</tr>
		$rows
		</table>
		""")
	else
		diag_items = join(["<li>$d</li>" for d in result.diagnostics])
		HTML("<h4 style=\"color:#b00;\">Infeasible</h4><ul>$diag_items</ul>")
	end
end


# ╔═╡ 228a25f0-9f4b-11f1-bbc6-13518995c595
let
	if result.status == :optimal
		periods_sorted = sort(collect(base_periods))
		comp_ids = sort([c.id for c in base_components])
		header_cells = join(["<th>$(cid)</th>" for cid in comp_ids]) * "<th>RON</th><th>cost</th>"
		rows = join([
			begin
				recipe = result.recipes[(product.id, t)]
				vol_cells = join(["<td>$(round(get(recipe.volumes, cid, 0.0); digits=1))</td>" for cid in comp_ids])
				ron = round(get(recipe.resulting_properties, :RON, NaN); digits=2)
				"<tr><td><b>period $t</b></td>$vol_cells<td>$ron</td><td>$(round(recipe.cost; digits=2))</td></tr>"
			end
			for t in periods_sorted
		])
		HTML("""
		<h4>Per-period recipe (product: $(product.name))</h4>
		<table>
		<tr><th>period</th>$header_cells</tr>
		$rows
		</table>
		""")
	else
		HTML("<h4>Per-period recipe</h4><p>Scenario is infeasible with the current sliders — see diagnostics above.</p>")
	end
end


# ╔═╡ 228a25fa-9f4b-11f1-8ad6-2da4009e9295
begin
	io = IOBuffer()
	print_schedule_report(io, [product], tanks, result, base_periods)
	Text(String(take!(io)))
end


# ╔═╡ Cell order:
# ╠═228a23e8-9f4b-11f1-a039-713fc9cb9789
# ╠═228a24d8-9f4b-11f1-9a7c-158d8b909a88
# ╠═228a2530-9f4b-11f1-9afa-0df0fc717ef6
# ╠═228a2546-9f4b-11f1-a995-bf799a24790e
# ╠═228a2562-9f4b-11f1-9561-4314e255a43e
# ╠═228a2562-9f4b-11f1-8e4c-e9bcfcc39f99
# ╠═228a256e-9f4b-11f1-a29c-1795f95bdf81
# ╠═228a256e-9f4b-11f1-8b5a-2d41978a10e6
# ╠═228a2582-9f4b-11f1-9cf0-cfbd659c61c2
# ╠═228a258c-9f4b-11f1-b1e4-619c48588af1
# ╠═228a258c-9f4b-11f1-9bc2-4f450dc7b4c5
# ╠═228a2594-9f4b-11f1-9409-2db2b5310a7c
# ╠═228a25a0-9f4b-11f1-9370-2f23938f545c
# ╠═228a25a0-9f4b-11f1-ac6d-87572d19704b
# ╠═228a25a0-9f4b-11f1-9181-152876923b51
# ╠═228a25c8-9f4b-11f1-80bb-15f14cc167ac
# ╠═228a25e6-9f4b-11f1-97a4-2b4aa94321b4
# ╠═228a25e6-9f4b-11f1-a8f7-252b78379143
# ╠═228a25f0-9f4b-11f1-bbc6-13518995c595
# ╠═228a25fa-9f4b-11f1-8ad6-2da4009e9295
