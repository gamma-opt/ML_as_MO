module ML_as_MO

# current_dir =  @__DIR__
# cd(current_dir)

# using Pkg
# Pkg.activate(".")
# Pkg.instantiate()

using MLDatasets, CUDA, FileIO, ImageShow 
using MLJBase # for conf matrix
using Plots, Images
using Statistics
using Random
using Flux
using Flux: params, train!, mse, flatten, onehotbatch
using JuMP
using JuMP: Model, value
using Gurobi
using EvoTrees
using CSV
using DataFrames
using StatsBase
using MLJ

# include("JuMP_model.jl")
# include("MNIST.jl")
# include("bound_tightening.jl")

# include.(filter(contains(r".jl$"), readdir(current_dir*"/decision_trees/"; join=true)))

include("JuMP_model.jl")
include("bound_tightening.jl")

export create_JuMP_model,
    evaluate!

export bound_tightening,
    bound_tightening_threads
    bound_tightening_workers
    bound_calculating

end # module