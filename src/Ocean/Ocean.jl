module Ocean

export AbstractOceanCoupling,
    Uncoupled, Coupled, AdvectionTerm, NonLinearAdvectionTerm

abstract type AbstractOceanCoupling end
struct Uncoupled <: AbstractOceanCoupling end
struct Coupled <: AbstractOceanCoupling end

abstract type AdvectionTerm end
struct NonLinearAdvectionTerm <: AdvectionTerm end

function ocean_init_state! end
function ocean_init_aux! end

function coriolis_parameter end
function kinematic_stress end
function surface_flux end

include("OceanBC.jl")

include("HydrostaticBoussinesq/HydrostaticBoussinesqModel.jl")
include("ShallowWater/ShallowWaterModel.jl")
include("SplitExplicit/SplitExplicitModel.jl")
include("OceanProblems/SimpleBoxProblem.jl")


end