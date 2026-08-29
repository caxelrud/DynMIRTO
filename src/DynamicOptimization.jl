"""
Simplified, scoped-down version of GDOT's actual technical core, per
US patent 2010/0274368 A1 ("Method and system for dynamic optimisation
of industrial processes", inventor Henrik Terndrup, now assigned to
AspenTech Corporation): Wiener-Hammerstein-style unit models (a
nonlinear steady-state gain reached via linear dynamics), real-time
data reconciliation against noisy measurements, and repeated
re-optimization via successive linear programming (SLP) as new
measurements arrive. See DESIGN.md section 10 for the full model and
its deliberate scope cuts vs. the real technology (first-order dynamics
only, two-source reconciliation, etc.) -- this is not v1/v2's gasoline
blend model.

Units are multivariable: each has one or more named inputs and one or
more named outputs, related by a general nonlinear steady-state map
(the patent's general LTI/multivariable model class -- v1 of this
module supported only one input and one output per unit; see DESIGN.md
section 10.6 for why and how that changed). Every `Dict` keyed by
variable uses a `(unit_id, variable_id)` tuple, e.g. `u[("COL1", "reflux")]`.
"""

using JuMP
using HiGHS
using Random

struct DynamicUnit
    id::String
    input_ids::Vector{String}
    output_ids::Vector{String}
    tau::Dict{String,Float64}                # time constant per output id
    steady_state_gain::Function              # F(u::Dict{String,Float64}) -> Dict{String,Float64}
    u_min::Dict{String,Float64}               # per input id
    u_max::Dict{String,Float64}
    max_step::Dict{String,Float64}            # real rate-of-change limit per input id

    function DynamicUnit(id::String, input_ids::Vector{String}, output_ids::Vector{String},
        tau::Dict{String,Float64}, steady_state_gain::Function;
        u_min::Dict{String,Float64}=Dict(i => -Inf for i in input_ids),
        u_max::Dict{String,Float64}=Dict(i => Inf for i in input_ids),
        max_step::Dict{String,Float64}=Dict(i => Inf for i in input_ids))

        isempty(input_ids) && error("DynamicUnit $id: needs at least one input")
        isempty(output_ids) && error("DynamicUnit $id: needs at least one output")
        all(oid -> haskey(tau, oid), output_ids) ||
            error("DynamicUnit $id: tau must have an entry for every output id")
        all(t -> t > 0, values(tau)) || error("DynamicUnit $id: all tau values must be > 0")
        all(iid -> haskey(u_min, iid) && haskey(u_max, iid) && haskey(max_step, iid), input_ids) ||
            error("DynamicUnit $id: u_min/u_max/max_step must have an entry for every input id")
        all(iid -> u_min[iid] <= u_max[iid], input_ids) ||
            error("DynamicUnit $id: u_min must be <= u_max for every input")
        all(s -> s > 0, values(max_step)) || error("DynamicUnit $id: all max_step values must be > 0")

        new(id, input_ids, output_ids, tau, steady_state_gain, u_min, u_max, max_step)
    end
end

"""
    DynamicUnit(id, tau, steady_state_gain; u_min=-Inf, u_max=Inf, max_step=Inf)

Convenience constructor for the common single-input/single-output case:
one input named `"u"`, one output named `"y"`. Equivalent to the general
constructor with `input_ids=["u"], output_ids=["y"]` and a scalar gain
function wrapped to the `Dict`-based interface.
"""
function DynamicUnit(id::String, tau::Float64, steady_state_gain::Function;
    u_min::Float64=-Inf, u_max::Float64=Inf, max_step::Float64=Inf)
    DynamicUnit(id, ["u"], ["y"], Dict("y" => tau), u -> Dict("y" => steady_state_gain(u["u"]));
        u_min=Dict("u" => u_min), u_max=Dict("u" => u_max), max_step=Dict("u" => max_step))
end

"""
    step_state(y, u, unit, dt)

Exact discrete-time update of one unit's outputs, each following its own
first-order lag `tau_j*dy_j/dt = F_j(u) - y_j` for constant inputs `u`
held over an interval of length `dt`: `z_j + (y_j-z_j)*exp(-dt/tau_j)`
where `z = F(u)`. `y` and `u` are keyed by the unit's own output/input
ids (not `(unit_id, ...)` tuples -- this operates on one unit at a time).
"""
function step_state(y::Dict{String,Float64}, u::Dict{String,Float64}, unit::DynamicUnit, dt::Float64)
    z = unit.steady_state_gain(u)
    return Dict(oid => z[oid] + (y[oid] - z[oid]) * exp(-dt / unit.tau[oid]) for oid in unit.output_ids)
end

"""
    reconcile(y_hat_prev, u_applied, y_measured, unit, dt; w_model=1.0, w_meas=1.0)

Simplified real-time data reconciliation for one unit's outputs: blend
the dynamic model's one-step-ahead prediction (from the previous
reconciled estimate and the input that was actually applied) with new
noisy measurements, weighted by `w_model`/`w_meas`. This is the
closed-form minimizer of `w_model*(y-predicted)^2 + w_meas*(y-y_measured)^2`,
applied independently per output.
"""
function reconcile(y_hat_prev::Dict{String,Float64}, u_applied::Dict{String,Float64},
    y_measured::Dict{String,Float64}, unit::DynamicUnit, dt::Float64;
    w_model::Float64=1.0, w_meas::Float64=1.0)
    predicted = step_state(y_hat_prev, u_applied, unit, dt)
    return Dict(oid => (w_model * predicted[oid] + w_meas * y_measured[oid]) / (w_model + w_meas)
                 for oid in unit.output_ids)
end

"""
Finite-difference Jacobian of `F` at `u0`: `J[(oid,iid)]` is
`∂F_oid/∂u_iid`, needed because a unit's outputs can depend on *all* of
its inputs, not just a matching one -- unlike the single-input case, a
single derivative isn't enough to linearize `F`.
"""
function _finite_diff_jacobian(F::Function, u0::Dict{String,Float64},
    input_ids::Vector{String}, output_ids::Vector{String}; h::Float64=1e-4)
    J = Dict{Tuple{String,String},Float64}()
    for iid in input_ids
        u_plus = copy(u0)
        u_plus[iid] += h
        u_minus = copy(u0)
        u_minus[iid] -= h
        f_plus = F(u_plus)
        f_minus = F(u_minus)
        for oid in output_ids
            J[(oid, iid)] = (f_plus[oid] - f_minus[oid]) / (2h)
        end
    end
    return J
end

_local_slice(d::Dict{Tuple{String,String},Float64}, unit_id::String, var_ids::Vector{String}) =
    Dict(vid => d[(unit_id, vid)] for vid in var_ids)

"""
Build and solve one linearized LP: each unit's steady-state map is
linearized around `u0` (via its Jacobian) and each input is restricted
to a box of half-width `trust[(unit.id, input_id)]` (further clipped to
the unit's real `[u_min, u_max]` for that input).
"""
function _linearize_and_solve(units::Vector{DynamicUnit}, u0::Dict{Tuple{String,String},Float64},
    trust::Dict{Tuple{String,String},Float64}, econ::Function, constraints::Function;
    optimizer=HiGHS.Optimizer)

    model = Model(optimizer)
    set_silent(model)

    u = Dict{Tuple{String,String},JuMP.VariableRef}()
    for unit in units, iid in unit.input_ids
        key = (unit.id, iid)
        lo = max(unit.u_min[iid], u0[key] - trust[key])
        hi = min(unit.u_max[iid], u0[key] + trust[key])
        u[key] = @variable(model, lower_bound = lo, upper_bound = hi, base_name = "u_$(unit.id)_$(iid)")
    end

    z = Dict{Tuple{String,String},Any}()
    for unit in units
        u0_local = _local_slice(u0, unit.id, unit.input_ids)
        f0 = unit.steady_state_gain(u0_local)
        J = _finite_diff_jacobian(unit.steady_state_gain, u0_local, unit.input_ids, unit.output_ids)
        for oid in unit.output_ids
            z[(unit.id, oid)] = f0[oid] +
                sum(J[(oid, iid)] * (u[(unit.id, iid)] - u0_local[iid]) for iid in unit.input_ids)
        end
    end

    constraints(model, u, z)
    @objective(model, Max, econ(u, z))

    optimize!(model)
    termination_status(model) == MOI.OPTIMAL || return (u0, :infeasible)

    return (Dict(k => value(v) for (k, v) in u), :optimal)
end

function _true_objective(units::Vector{DynamicUnit}, u::Dict{Tuple{String,String},Float64}, econ::Function)
    z = Dict{Tuple{String,String},Float64}()
    for unit in units
        f0 = unit.steady_state_gain(_local_slice(u, unit.id, unit.input_ids))
        for oid in unit.output_ids
            z[(unit.id, oid)] = f0[oid]
        end
    end
    return econ(u, z)
end

"""
    successive_lp_optimize(units, u_start, econ, constraints; max_iters=50, tol=1e-6, optimizer=HiGHS.Optimizer)
        -> (u_target::Dict{Tuple{String,String},Float64}, status::Symbol)

Find the steady-state economic optimum via successive linear
programming: repeatedly linearize each unit's nonlinear steady-state map
around the current point (via its Jacobian) and solve the resulting LP
within a trust region (initialized from each input's `max_step`). A
candidate step is accepted only if it improves the *true*
(non-linearized) objective; otherwise the trust region shrinks and the
step is retried from the same point.

`econ(u, z)` and `constraints(model, u, z)` are user-supplied: `econ`
must be a plain function of `u`/`z` `Dict{Tuple{String,String},<:Any}`s
that works identically whether they hold JuMP expressions or plain
`Float64`s; `constraints` adds `@constraint(model, ...)` calls. Keys are
`(unit_id, input_id)` for `u` and `(unit_id, output_id)` for `z`.
"""
function successive_lp_optimize(units::Vector{DynamicUnit}, u_start::Dict{Tuple{String,String},Float64},
    econ::Function, constraints::Function;
    max_iters::Int=50, tol::Float64=1e-6, optimizer=HiGHS.Optimizer)

    u0 = copy(u_start)
    trust = Dict((unit.id, iid) => unit.max_step[iid] for unit in units for iid in unit.input_ids)
    obj0 = _true_objective(units, u0, econ)

    for _ in 1:max_iters
        u1, status = _linearize_and_solve(units, u0, trust, econ, constraints; optimizer)
        status == :optimal || return (u0, :infeasible)

        obj1 = _true_objective(units, u1, econ)
        if obj1 > obj0 + 1e-9
            # Require *strict* improvement, not just "no worse": a large
            # trust region can otherwise jump between equally-good corners
            # forever without ever shrinking down to the true (interior,
            # non-vertex) optimum of a concave objective.
            delta = maximum(abs(u1[k] - u0[k]) for k in keys(u0))
            u0, obj0 = u1, obj1
            delta < tol && break
        else
            for k in keys(trust)
                trust[k] *= 0.5
            end
            maximum(values(trust)) < 1e-10 && break
        end
    end

    return (u0, :optimal)
end

"""
One tick of a solved closed real-time loop: the true (hidden) state,
the noisy measurement, the reconciled estimate, the input actually
applied, and the steady-state target the optimizer was aiming for.
Keys are `(unit_id, output_id)` for the `y_*` fields and
`(unit_id, input_id)` for the `u_*` fields.
"""
struct RealTimeTick
    tick::Int
    y_true::Dict{Tuple{String,String},Float64}
    y_measured::Dict{Tuple{String,String},Float64}
    y_hat::Dict{Tuple{String,String},Float64}
    u_applied::Dict{Tuple{String,String},Float64}
    u_target::Dict{Tuple{String,String},Float64}
end

"""
    run_real_time_loop(units, econ, constraints; n_ticks, dt=1.0, u_init=nothing, y_init=nothing,
                        measurement_noise_std=0.0, rng=Random.default_rng()) -> Vector{RealTimeTick}

Simulate the closed real-time loop for `n_ticks` control cycles: each
tick, the (simulated) true plant evolves under the previously applied
input, noisy measurements are taken, data reconciliation blends them
with the model's prediction, `successive_lp_optimize` re-solves for the
steady-state target from the current applied input, and each applied
input moves toward its target by at most that input's `max_step` (a
real rate-of-change limit, kept separate from the optimizer's own
internal trust region -- see DESIGN.md section 10.2).
"""
function run_real_time_loop(units::Vector{DynamicUnit}, econ::Function, constraints::Function;
    n_ticks::Int, dt::Float64=1.0,
    u_init::Union{Dict{Tuple{String,String},Float64},Nothing}=nothing,
    y_init::Union{Dict{Tuple{String,String},Float64},Nothing}=nothing,
    measurement_noise_std::Float64=0.0, rng::Random.AbstractRNG=Random.default_rng())

    u_applied = u_init === nothing ?
        Dict((unit.id, iid) => unit.u_min[iid] for unit in units for iid in unit.input_ids) : copy(u_init)

    max_step_by_key = Dict((unit.id, iid) => unit.max_step[iid] for unit in units for iid in unit.input_ids)

    y_true = if y_init === nothing
        result = Dict{Tuple{String,String},Float64}()
        for unit in units
            f0 = unit.steady_state_gain(_local_slice(u_applied, unit.id, unit.input_ids))
            for oid in unit.output_ids
                result[(unit.id, oid)] = f0[oid]
            end
        end
        result
    else
        copy(y_init)
    end
    y_hat = copy(y_true)

    history = RealTimeTick[]
    for tick in 1:n_ticks
        y_true_new = Dict{Tuple{String,String},Float64}()
        y_hat_new = Dict{Tuple{String,String},Float64}()
        y_measured = Dict{Tuple{String,String},Float64}()

        for unit in units
            u_local = _local_slice(u_applied, unit.id, unit.input_ids)
            stepped = step_state(_local_slice(y_true, unit.id, unit.output_ids), u_local, unit, dt)
            for oid in unit.output_ids
                y_true_new[(unit.id, oid)] = stepped[oid]
                y_measured[(unit.id, oid)] = stepped[oid] + measurement_noise_std * randn(rng)
            end

            reconciled = reconcile(_local_slice(y_hat, unit.id, unit.output_ids), u_local,
                _local_slice(y_measured, unit.id, unit.output_ids), unit, dt)
            for oid in unit.output_ids
                y_hat_new[(unit.id, oid)] = reconciled[oid]
            end
        end
        y_true, y_hat = y_true_new, y_hat_new

        u_target, _status = successive_lp_optimize(units, u_applied, econ, constraints)

        u_applied = Dict(
            k => clamp(u_target[k], u_applied[k] - max_step_by_key[k], u_applied[k] + max_step_by_key[k])
            for k in keys(u_applied)
        )

        push!(history, RealTimeTick(tick, y_true, y_measured, y_hat, u_applied, u_target))
    end

    return history
end
