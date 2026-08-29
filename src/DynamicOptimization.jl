"""
Simplified, scoped-down version of GDOT's actual technical core, per
US patent 2010/0274368 A1 ("Method and system for dynamic optimisation
of industrial processes", inventor Henrik Terndrup, now assigned to
AspenTech Corporation): Wiener-Hammerstein-style unit models (a
nonlinear steady-state gain reached via linear dynamics), real-time
data reconciliation against noisy measurements, and repeated
re-optimization via successive linear programming (SLP) as new
measurements arrive. See DESIGN.md section 10 for the full model and
its deliberate scope cuts vs. the real technology (single-input/
single-output units, first-order dynamics only, two-source
reconciliation, etc.) -- this is not v1/v2's gasoline blend model.
"""

using JuMP
using HiGHS
using Random

struct DynamicUnit
    id::String
    tau::Float64
    steady_state_gain::Function
    u_min::Float64
    u_max::Float64
    max_step::Float64

    function DynamicUnit(id, tau, steady_state_gain::Function; u_min=-Inf, u_max=Inf, max_step=Inf)
        tau > 0 || error("DynamicUnit $id: tau must be > 0")
        u_min <= u_max || error("DynamicUnit $id: u_min ($u_min) must be <= u_max ($u_max)")
        max_step > 0 || error("DynamicUnit $id: max_step must be > 0")
        new(id, Float64(tau), steady_state_gain, Float64(u_min), Float64(u_max), Float64(max_step))
    end
end

"""
    step_state(y, u, unit, dt)

Exact discrete-time update of the first-order lag `tau*dy/dt = f(u) - y`
for constant `u` held over an interval of length `dt`: `z + (y-z)*exp(-dt/tau)`
where `z = f(u)`.
"""
function step_state(y::Float64, u::Float64, unit::DynamicUnit, dt::Float64)
    z = unit.steady_state_gain(u)
    decay = exp(-dt / unit.tau)
    return z + (y - z) * decay
end

"""
    reconcile(y_hat_prev, u_applied, y_measured, unit, dt; w_model=1.0, w_meas=1.0)

Simplified real-time data reconciliation for one unit: blend the
dynamic model's one-step-ahead prediction (from the previous reconciled
estimate and the input that was actually applied) with a new noisy
measurement, weighted by `w_model`/`w_meas`. This is the closed-form
minimizer of `w_model*(y-predicted)^2 + w_meas*(y-y_measured)^2`.
"""
function reconcile(y_hat_prev::Float64, u_applied::Float64, y_measured::Float64, unit::DynamicUnit, dt::Float64;
    w_model::Float64=1.0, w_meas::Float64=1.0)
    predicted = step_state(y_hat_prev, u_applied, unit, dt)
    return (w_model * predicted + w_meas * y_measured) / (w_model + w_meas)
end

function _finite_diff_derivative(f::Function, x::Float64; h::Float64=1e-4)
    (f(x + h) - f(x - h)) / (2h)
end

"""
Build and solve one linearized LP: each unit's gain is linearized
around `u0` and restricted to a box of half-width `trust[unit.id]`
(further clipped to the unit's real `[u_min, u_max]`).
"""
function _linearize_and_solve(units::Vector{DynamicUnit}, u0::Dict{String,Float64}, trust::Dict{String,Float64},
    econ::Function, constraints::Function; optimizer=HiGHS.Optimizer)

    model = Model(optimizer)
    set_silent(model)

    u = Dict{String,JuMP.VariableRef}()
    for unit in units
        lo = max(unit.u_min, u0[unit.id] - trust[unit.id])
        hi = min(unit.u_max, u0[unit.id] + trust[unit.id])
        u[unit.id] = @variable(model, lower_bound = lo, upper_bound = hi, base_name = "u_$(unit.id)")
    end

    z = Dict{String,Any}()
    for unit in units
        f0 = unit.steady_state_gain(u0[unit.id])
        slope = _finite_diff_derivative(unit.steady_state_gain, u0[unit.id])
        z[unit.id] = f0 + slope * (u[unit.id] - u0[unit.id])
    end

    constraints(model, u, z)
    @objective(model, Max, econ(u, z))

    optimize!(model)
    termination_status(model) == MOI.OPTIMAL || return (u0, :infeasible)

    return (Dict(id => value(v) for (id, v) in u), :optimal)
end

_true_objective(units::Vector{DynamicUnit}, u::Dict{String,Float64}, econ::Function) =
    econ(u, Dict(unit.id => unit.steady_state_gain(u[unit.id]) for unit in units))

"""
    successive_lp_optimize(units, u_start, econ, constraints; max_iters=50, tol=1e-6, optimizer=HiGHS.Optimizer)
        -> (u_target::Dict{String,Float64}, status::Symbol)

Find the steady-state economic optimum via successive linear
programming: repeatedly linearize each unit's nonlinear steady-state
gain around the current point and solve the resulting LP within a
trust region (initialized from each unit's `max_step`). A candidate
step is accepted only if it improves the *true* (non-linearized)
objective; otherwise the trust region shrinks and the step is retried
from the same point.

`econ(u, z)` and `constraints(model, u, z)` are user-supplied: `econ`
must be a plain function of `u`/`z` `Dict`s that works identically
whether they hold JuMP expressions or plain `Float64`s; `constraints`
adds `@constraint(model, ...)` calls.
"""
function successive_lp_optimize(units::Vector{DynamicUnit}, u_start::Dict{String,Float64},
    econ::Function, constraints::Function;
    max_iters::Int=50, tol::Float64=1e-6, optimizer=HiGHS.Optimizer)

    u0 = copy(u_start)
    trust = Dict(unit.id => unit.max_step for unit in units)
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
            delta = maximum(abs(u1[id] - u0[id]) for id in keys(u0))
            u0, obj0 = u1, obj1
            delta < tol && break
        else
            for id in keys(trust)
                trust[id] *= 0.5
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
"""
struct RealTimeTick
    tick::Int
    y_true::Dict{String,Float64}
    y_measured::Dict{String,Float64}
    y_hat::Dict{String,Float64}
    u_applied::Dict{String,Float64}
    u_target::Dict{String,Float64}
end

"""
    run_real_time_loop(units, econ, constraints; n_ticks, dt=1.0, u_init=nothing, y_init=nothing,
                        measurement_noise_std=0.0, rng=Random.default_rng()) -> Vector{RealTimeTick}

Simulate the closed real-time loop for `n_ticks` control cycles: each
tick, the (simulated) true plant evolves under the previously applied
input, a noisy measurement is taken, data reconciliation blends it with
the model's prediction, `successive_lp_optimize` re-solves for the
steady-state target from the current applied input, and the applied
input moves toward that target by at most each unit's `max_step` (a
real rate-of-change limit, kept separate from the optimizer's own
internal trust region -- see DESIGN.md section 10.2).
"""
function run_real_time_loop(units::Vector{DynamicUnit}, econ::Function, constraints::Function;
    n_ticks::Int, dt::Float64=1.0,
    u_init::Union{Dict{String,Float64},Nothing}=nothing,
    y_init::Union{Dict{String,Float64},Nothing}=nothing,
    measurement_noise_std::Float64=0.0, rng::Random.AbstractRNG=Random.default_rng())

    u_applied = u_init === nothing ? Dict(unit.id => unit.u_min for unit in units) : copy(u_init)
    y_true = y_init === nothing ? Dict(unit.id => unit.steady_state_gain(u_applied[unit.id]) for unit in units) : copy(y_init)
    y_hat = copy(y_true)

    history = RealTimeTick[]
    for tick in 1:n_ticks
        y_true = Dict(unit.id => step_state(y_true[unit.id], u_applied[unit.id], unit, dt) for unit in units)
        y_measured = Dict(id => y_true[id] + measurement_noise_std * randn(rng) for id in keys(y_true))
        y_hat = Dict(unit.id => reconcile(y_hat[unit.id], u_applied[unit.id], y_measured[unit.id], unit, dt)
                      for unit in units)

        u_target, _status = successive_lp_optimize(units, u_applied, econ, constraints)

        u_applied = Dict(
            unit.id => clamp(u_target[unit.id], u_applied[unit.id] - unit.max_step, u_applied[unit.id] + unit.max_step)
            for unit in units
        )

        push!(history, RealTimeTick(tick, y_true, y_measured, y_hat, u_applied, u_target))
    end

    return history
end
