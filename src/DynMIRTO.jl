module DynMIRTO

export Component, Product, PropertySpec, BlendRecipe, is_eligible
export register_blend_index!, has_blend_index, to_index_space, from_index_space
export optimize_blend, OptimizationResult
export load_scenario
export print_report

include("Types.jl")
include("BlendIndices.jl")
include("Optimizer.jl")
include("ScenarioIO.jl")
include("Report.jl")

end # module DynMIRTO
