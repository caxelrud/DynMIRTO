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

# ╔═╡ d339a9be-41e1-4dde-9047-ef8c2adff67a
begin
	import Pkg
	Pkg.activate(joinpath(@__DIR__, ".notebook_env"))
	Pkg.develop(path=joinpath(@__DIR__, ".."))
	Pkg.add(["PlutoUI"])
	using DynMIRTO
	using PlutoUI
	using Random
end

# ╔═╡ de1d5493-ff84-4e63-9933-cd4c1dec360c
md"""
# DynMIRTO — Coordination Explorer (v1 ↔ v3)

Interactive view of the real-time loop that connects v1 (blend
optimization) to v3 (dynamic unit optimization) — the "missing link"
GDOT's own materials describe (see DESIGN.md section 11).

Every tick, a `DynamicUnit` ("REFORMER") sets its own feed rate by
maximizing revenue against its operating cost, where the revenue term is
v1's *live* shadow price for the component it produces (REF). Move the
sliders below to change the starting point, the economics, or the spec,
and the whole real-time run re-solves.

In particular, try dragging **initial feed (u_init)** down to `0` with
**floor_price** left at `0` — that's a true cold start, and it never
recovers (DESIGN.md section 11.5): every tick's blend is infeasible, REF
gets a shadow price of exactly zero, and the reformer has no incentive
to ever produce. Then raise **floor_price** to `35` or so and watch the
same cold start escape the deadlock instead.

Uses the `DynMIRTO` package straight from `src/` (via `Pkg.develop`), so
it always reflects the current code.
"""

# ╔═╡ d0b51226-e0f7-4b60-b19b-e24679ad91f7
md"""## Controls"""

# ╔═╡ 42157564-cb4d-4cb8-be9b-23bd23eec10a
md"**Initial feed setpoint, u_init** (0 = a true cold start)"

# ╔═╡ ff916aaf-019b-4fbf-8e76-4affb2884b35
@bind u_init Slider(0.0:5.0:100.0; default=50.0, show_value=true)

# ╔═╡ 8ab85299-1762-477e-8015-73f916c2dc1a
md"**Reformer operating cost** (\$ per unit of feed)"

# ╔═╡ 67d9c5da-909b-4bc3-9656-baf8d5a86b5a
@bind op_cost Slider(10.0:5.0:60.0; default=30.0, show_value=true)

# ╔═╡ 8f94e91b-617c-4d12-bd36-0778395c9750
md"**REF's floor_price** (used only on ticks where the blend is infeasible)"

# ╔═╡ 16ae2453-9eff-4c65-ba43-9a14711ee0d9
@bind floor_price Slider(0.0:2.5:40.0; default=0.0, show_value=true)

# ╔═╡ 8516e51d-21c0-40dd-8a41-bbb0e848506c
md"**Regular unleaded — minimum RON**"

# ╔═╡ 653572d0-ed02-480b-a1a3-e9dfe324123b
@bind ron_min Slider(85.0:0.5:95.0; default=90.0, show_value=true)

# ╔═╡ 43945210-1705-4c74-a215-14edbcb3cfd9
md"**Number of ticks to simulate**"

# ╔═╡ 4ad90a76-cbde-4ec4-a5af-1827f13fcaba
@bind n_ticks Slider(10:5:60; default=30, show_value=true)

# ╔═╡ 95808cb4-8095-4126-96a8-e5fe611850bf
md"**Measurement noise** (std dev on the reformer's sensor)"

# ╔═╡ 69c41a5e-d79f-474f-93e6-0b712e12d2b7
@bind noise_std Slider(0.0:0.5:5.0; default=0.0, show_value=true)

# ╔═╡ 81bfe22c-804a-49fd-8c01-6d016c3c5023
begin
	fill_template = Component("FILL", "Filler", 40.0, 1000.0; properties=Dict(:RON => 80.0))
	ref_template = Component("REF", "Reformate", 0.0, 0.0; properties=Dict(:RON => 95.0))
	reformer = DynamicUnit("REFORMER", 5.0, u -> 150.0 * (1.0 - exp(-u / 80.0));
		u_min=0.0, u_max=300.0, max_step=10.0)
	source = ComponentSource("REF", "REFORMER", "y"; floor_price=floor_price)
	product = Product("REG", "Regular", 100.0; specs=Dict(:RON => PropertySpec(; min=ron_min, blend_rule=:linear)))
	operating_cost = Dict(("REFORMER", "u") => op_cost)
	rng = Random.MersenneTwister(42)

	history = run_coordinated_loop([fill_template], [ref_template], [source], [reformer], operating_cost, [product];
		n_ticks=n_ticks, dt=1.0, u_init=Dict(("REFORMER", "u") => u_init),
		measurement_noise_std=noise_std, rng=rng)
end

# ╔═╡ 2ed1b66b-9bc6-4d0b-9200-47f0e0f32e01
md"""
## Hand-derived long-run equilibrium

As long as REF stays scarcer than demand (`0 < rate(u) < 100`), the blend
always uses all available REF, so its shadow price holds at exactly
\$40 (the cost of the FILL it displaces) regardless of the octane spec —
see DESIGN.md section 11.3. That reduces the reformer's own problem to
maximizing `40 * rate(u) - c*u`, with `rate(u) = 150*(1-e^(-u/80))`.

At the current operating cost, c = \$$(op_cost)/unit, that analytical
optimum is **u\* ≈ $(round(-80 * log(op_cost / 75); digits=3))**,
**rate\* ≈ $(round(150 * (1 - op_cost / 75); digits=3))** — note: this
figure isn't recomputed inside a code fence (Markdown.jl renders those
literally, not interpolated — worth knowing if you ever add one of your
own to this notebook).

Compare this to where `u` and `y_hat` actually converge below (recomputed
live from the operating-cost slider above).
"""

# ╔═╡ 10fbe5a6-f0b9-4833-83dc-1b02f7894e82
let
	u_max = 300.0
	rate_scale = 150.0
	rows = join([
		begin
			optimal = t.blend_result.status == :optimal
			bg = optimal ? "#f7f7f7" : "#f8d7d5"
			u_val = t.unit_tick.u_applied[("REFORMER", "u")]
			y_val = t.unit_tick.y_hat[("REFORMER", "y")]
			u_frac = clamp(u_val / u_max, 0.0, 1.0)
			y_frac = clamp(y_val / rate_scale, 0.0, 1.0)
			"""<tr style="background:$bg;">
				<td>$(t.tick)</td>
				<td>
					<div style="font-family:monospace;font-size:0.8em;">u=$(round(u_val; digits=1))</div>
					<div style="background:#e3e3e3;border-radius:3px;overflow:hidden;width:150px;">
						<div style="width:$(max(100 * u_frac, 2))%;background:#4c78a8;height:10px;"></div>
					</div>
				</td>
				<td>
					<div style="font-family:monospace;font-size:0.8em;">rate=$(round(y_val; digits=1))</div>
					<div style="background:#e3e3e3;border-radius:3px;overflow:hidden;width:150px;">
						<div style="width:$(max(100 * y_frac, 2))%;background:#54a24b;height:10px;"></div>
					</div>
				</td>
			</tr>"""
		end
		for t in history
	])
	HTML("""
	<h4>Feed setpoint (u) and production rate (y_hat) over time</h4>
	<p style="font-size:0.85em;color:#666;">Pink row = that tick's blend was infeasible (REF's price falls back to floor_price).</p>
	<table>
	<tr><th>tick</th><th>u (feed)</th><th>y_hat (rate)</th></tr>
	$rows
	</table>
	""")
end

# ╔═╡ 28107f35-94b7-4abc-be11-d49e64da7364
let
	rows = join([
		begin
			optimal = t.blend_result.status == :optimal
			price = optimal ? get(t.blend_result.component_shadow_prices, "REF", NaN) : floor_price
			price_label = optimal ? "$(round(price; digits=2))" : "$(round(price; digits=2)) (floor)"
			cost = optimal ? string(round(t.blend_result.recipes["REG"].cost; digits=2)) : "-"
			bg = optimal ? "#f7f7f7" : "#f8d7d5"
			"<tr style=\"background:$bg;\"><td>$(t.tick)</td><td>$(t.blend_result.status)</td><td>$price_label</td><td>$cost</td></tr>"
		end
		for t in history
	])
	HTML("""
	<h4>REF shadow price and blend cost over time</h4>
	<table>
	<tr><th>tick</th><th>status</th><th>REF price</th><th>blend cost</th></tr>
	$rows
	</table>
	""")
end

# ╔═╡ 165782eb-24af-4ccd-9b8e-89083b3f267f
begin
	io = IOBuffer()
	println(io, "tick  status      REF price   u (feed)   y_hat (rate)   blend cost")
	println(io, "-"^68)
	for t in history
		optimal = t.blend_result.status == :optimal
		price = optimal ? t.blend_result.component_shadow_prices["REF"] : floor_price
		label = optimal ? string(round(price; digits=2)) : "$(round(price; digits=2)) (floor)"
		cost = optimal ? t.blend_result.recipes["REG"].cost : NaN
		println(io,
			rpad(t.tick, 6), rpad(t.blend_result.status, 12), rpad(label, 12),
			rpad(round(t.unit_tick.u_applied[("REFORMER", "u")]; digits=2), 11),
			rpad(round(t.unit_tick.y_hat[("REFORMER", "y")]; digits=2), 15),
			isnan(cost) ? "-" : round(cost; digits=2),
		)
	end
	Text(String(take!(io)))
end

# ╔═╡ Cell order:
# ╠═de1d5493-ff84-4e63-9933-cd4c1dec360c
# ╠═d339a9be-41e1-4dde-9047-ef8c2adff67a
# ╠═d0b51226-e0f7-4b60-b19b-e24679ad91f7
# ╠═42157564-cb4d-4cb8-be9b-23bd23eec10a
# ╠═ff916aaf-019b-4fbf-8e76-4affb2884b35
# ╠═8ab85299-1762-477e-8015-73f916c2dc1a
# ╠═67d9c5da-909b-4bc3-9656-baf8d5a86b5a
# ╠═8f94e91b-617c-4d12-bd36-0778395c9750
# ╠═16ae2453-9eff-4c65-ba43-9a14711ee0d9
# ╠═8516e51d-21c0-40dd-8a41-bbb0e848506c
# ╠═653572d0-ed02-480b-a1a3-e9dfe324123b
# ╠═43945210-1705-4c74-a215-14edbcb3cfd9
# ╠═4ad90a76-cbde-4ec4-a5af-1827f13fcaba
# ╠═95808cb4-8095-4126-96a8-e5fe611850bf
# ╠═69c41a5e-d79f-474f-93e6-0b712e12d2b7
# ╠═81bfe22c-804a-49fd-8c01-6d016c3c5023
# ╠═2ed1b66b-9bc6-4d0b-9200-47f0e0f32e01
# ╠═10fbe5a6-f0b9-4833-83dc-1b02f7894e82
# ╠═28107f35-94b7-4abc-be11-d49e64da7364
# ╠═165782eb-24af-4ccd-9b8e-89083b3f267f
