using JuMP, Flux, Gurobi
using Flux: params
using Distributed
using SharedArrays

"""
bound_tightening(DNN::Chain, init_U_bounds::Vector{Float32}, init_L_bounds::Vector{Float32}, verbose::Bool=false)

A single-threaded implementation of optimal tightened constraint bounds L and U for for a trained DNN.
Using these bounds with the create_JuMP_model function reduces solution time for optimization problems.

# Arguments
- `DNN::Chain`: A trained ReLU DNN.
- `init_U_bounds::Vector{Float32}`: Initial upper bounds on the node values of the DNN.
- `init_L_bounds::Vector{Float32}`: Initial lower bounds on the node values of the DNN.
- `verbose::Bool=false`: Controls Gurobi logs.

# Examples
```julia
L_bounds, U_bounds = bound_tightening(DNN, init_U_bounds, init_L_bounds, false)
```
"""

function bound_tightening(DNN::Chain, init_U_bounds::Vector{Float32}, init_L_bounds::Vector{Float32}, verbose::Bool=false)

    K = length(DNN) # NOTE! there are K+1 layers in the nn

    # store the DNN weights and biases
    DNN_params = params(DNN)
    W = [DNN_params[2*i-1] for i in 1:K]
    b = [DNN_params[2*i] for i in 1:K]

    # stores the node count of layer k (starting at layer k=0) at index k+1
    input_node_count = length(DNN_params[1][1, :])
    node_count = [if k == 1 input_node_count else length(DNN_params[2*(k-1)]) end for k in 1:K+1]

    # store the current optimal bounds in the algorithm
    curr_U_bounds = copy(init_U_bounds)
    curr_L_bounds = copy(init_L_bounds)

    model = Model(optimizer_with_attributes(Gurobi.Optimizer, "OutputFlag" => (verbose ? 1 : 0)))

    # keeps track of the current node index starting from layer 1 (out of 0:K)
    outer_index = node_count[1] + 1

    # NOTE! below variables and constraints for all opt problems
    @variable(model, x[k in 0:K, j in 1:node_count[k+1]] >= 0)
    @variable(model, s[k in 1:K-1, j in 1:node_count[k+1]] >= 0)
    @variable(model, z[k in 1:K-1, j in 1:node_count[k+1]], Bin)
    @variable(model, U[k in 0:K, j in 1:node_count[k+1]])
    @variable(model, L[k in 0:K, j in 1:node_count[k+1]])

    # fix values to all U[k,j] and L[k,j] from U_bounds and L_bounds
    index = 1
    for k in 0:K
        for j in 1:node_count[k+1]
            fix(U[k, j], curr_U_bounds[index], force=true)
            fix(L[k, j], curr_L_bounds[index], force=true)
            index += 1
        end
    end

    # input layer (layer 0) node bounds are given beforehand
    for input_node in 1:node_count[1]
        delete_lower_bound(x[0, input_node])
        @constraint(model, L[0, input_node] <= x[0, input_node])
        @constraint(model, x[0, input_node] <= U[0, input_node])
    end

    # deleting lower bound for output nodes
    for output_node in 1:node_count[K+1]
        delete_lower_bound(x[K, output_node])
    end

    # NOTE! below constraints depending on the layer
    for k in 1:K
        # we only want to build ALL of the constraints until the PREVIOUS layer, and then go node by node
        # here we calculate ONLY the constraints until the PREVIOUS layer
        for node_in in 1:node_count[k]
            if k >= 2
                temp_sum = sum(W[k-1][node_in, j] * x[k-1-1, j] for j in 1:node_count[k-1])
                @constraint(model, x[k-1, node_in] <= U[k-1, node_in] * z[k-1, node_in])
                @constraint(model, s[k-1, node_in] <= -L[k-1, node_in] * (1 - z[k-1, node_in]))
                if k <= K - 1
                    @constraint(model, temp_sum + b[k-1][node_in] == x[k-1, node_in] - s[k-1, node_in])
                else # k == K
                    @constraint(model, temp_sum + b[k-1][node_in] == x[k-1, node_in])
                end
            end
        end

        # NOTE! below constraints depending on the node
        for node in 1:node_count[k+1]
            # here we calculate the specific constraints depending on the current node
            temp_sum = sum(W[k][node, j] * x[k-1, j] for j in 1:node_count[k]) # NOTE! prev layer [k]
            if k <= K - 1
                @constraint(model, node_con, temp_sum + b[k][node] == x[k, node] - s[k, node])
                @constraint(model, node_U, x[k, node] <= U[k, node] * z[k, node])
                @constraint(model, node_L, s[k, node] <= -L[k, node] * (1 - z[k, node]))
            elseif k == K # == last value of k
                @constraint(model, node_con, temp_sum + b[k][node] == x[k, node])
                @constraint(model, node_L, L[k, node] <= x[k, node])
                @constraint(model, node_U, x[k, node] <= U[k, node])
            end

            # NOTE! below objective function and optimizing the model depending on obj_function and layer
            for obj_function in 1:2
                if obj_function == 1 && k <= K - 1 # Min, hidden layer
                    @objective(model, Min, x[k, node] - s[k, node])
                elseif obj_function == 2 && k <= K - 1 # Max, hidden layer
                    @objective(model, Max, x[k, node] - s[k, node])
                elseif obj_function == 1 && k == K # Min, last layer
                    @objective(model, Min, x[k, node])
                elseif obj_function == 2 && k == K # Max, last layer
                    @objective(model, Max, x[k, node])
                end

                solve_time = @elapsed optimize!(model)
                solve_time = round(solve_time; sigdigits = 3)
                @assert termination_status(model) == OPTIMAL || termination_status(model) == TIME_LIMIT
                    "Problem (layer $k (from 1:$K), node $node, $(obj_function == 1 ? "L" : "U")-bound) is infeasible."
                optimal = objective_value(model)
                println("Layer $k, node $node, $(obj_function == 1 ? "L" : "U")-bound: solve time $(solve_time)s, optimal value $(optimal)")

                # fix the model variable L or U corresponding to the current node to be the optimal value
                if obj_function == 1 # Min
                    curr_L_bounds[outer_index] = optimal
                    fix(L[k, node], optimal)
                elseif obj_function == 2 # Max
                    curr_U_bounds[outer_index] = optimal
                    fix(U[k, node], optimal)
                end
            end
            outer_index += 1

            # deleting and unregistering the constraints assigned to the current node
            delete(model, node_con)
            delete(model, node_L)
            delete(model, node_U)
            unregister(model, :node_con)
            unregister(model, :node_L)
            unregister(model, :node_U)
        end
    end

    println("Solving optimal constraint bounds single-threaded complete")

    return curr_U_bounds, curr_L_bounds
end

"""
bound_tightening_threads(DNN::Chain, init_U_bounds::Vector{Float32}, init_L_bounds::Vector{Float32}, verbose::Bool=false)

A multi-threaded (using Threads) implementation of optimal tightened constraint bounds L and U for for a trained DNN.
Using these bounds with the create_JuMP_model function reduces solution time for optimization problems.

# Arguments
- `DNN::Chain`: A trained ReLU DNN.
- `init_U_bounds::Vector{Float32}`: Initial upper bounds on the node values of the DNN.
- `init_L_bounds::Vector{Float32}`: Initial lower bounds on the node values of the DNN.
- `verbose::Bool=false`: Controls Gurobi logs.

# Examples
```julia
L_bounds_threads, U_bounds_threads = bound_tightening_threads(DNN, init_U_bounds, init_L_bounds, false)
```
"""

function bound_tightening_threads(DNN::Chain, init_U_bounds::Vector{Float32}, init_L_bounds::Vector{Float32}, verbose::Bool=false)

    K = length(DNN) # NOTE! there are K+1 layers in the nn

    # store the DNN weights and biases
    DNN_params = params(DNN)
    W = [DNN_params[2*i-1] for i in 1:K]
    b = [DNN_params[2*i] for i in 1:K]

    # stores the node count of layer k (starting at layer k=0) at index k+1
    input_node_count = length(DNN_params[1][1, :])
    node_count = [if k == 1 input_node_count else length(DNN_params[2*(k-1)]) end for k in 1:K+1]

    # store the current optimal bounds in the algorithm
    curr_U_bounds = copy(init_U_bounds)
    curr_L_bounds = copy(init_L_bounds)

    lock = Threads.ReentrantLock()
    
    for k in 1:K

        Threads.@threads for node in 1:(2*node_count[k+1]) # loop over both obj functions

            ### below variables and constraints in all problems

            model = Model(optimizer_with_attributes(Gurobi.Optimizer, "OutputFlag" => (verbose ? 1 : 0)))

            # keeps track of the current node index starting from layer 1 (out of 0:K)
            prev_layers_node_sum = 0
            for prev_layer in 0:k-1
                prev_layers_node_sum += node_count[prev_layer+1]
            end
            
            # loops nodes twice: 1st time with obj function Min, 2nd time with Max
            curr_node = node
            obj_function = 1
            if node > node_count[k+1]
                curr_node = node - node_count[k+1]
                obj_function = 2
            end
            curr_node_index = prev_layers_node_sum + curr_node

            # NOTE! below variables and constraints for all opt problems
            @variable(model, x[k in 0:K, j in 1:node_count[k+1]] >= 0)
            @variable(model, s[k in 1:K-1, j in 1:node_count[k+1]] >= 0)
            @variable(model, z[k in 1:K-1, j in 1:node_count[k+1]], Bin)
            @variable(model, U[k in 0:K, j in 1:node_count[k+1]])
            @variable(model, L[k in 0:K, j in 1:node_count[k+1]])

            # fix values to all U[k,j] and L[k,j] from U_bounds and L_bounds
            index = 1
            Threads.lock(lock) do
                for k in 0:K
                    for j in 1:node_count[k+1]
                        fix(U[k, j], curr_U_bounds[index], force=true)
                        fix(L[k, j], curr_L_bounds[index], force=true)
                        index += 1
                    end
                end
            end

            # input layer (layer 0) node bounds are given beforehand
            for input_node in 1:node_count[1]
                delete_lower_bound(x[0, input_node])
                @constraint(model, L[0, input_node] <= x[0, input_node])
                @constraint(model, x[0, input_node] <= U[0, input_node])
            end

            # deleting lower bound for output nodes
            for output_node in 1:node_count[K+1]
                delete_lower_bound(x[K, output_node])
            end

            ### below constraints depending on the layer (every constraint up to the previous layer)
            for k_in in 1:k
                for node_in in 1:node_count[k_in]
                    if k_in >= 2
                        temp_sum = sum(W[k_in-1][node_in, j] * x[k_in-1-1, j] for j in 1:node_count[k_in-1])
                        @constraint(model, x[k_in-1, node_in] <= U[k_in-1, node_in] * z[k_in-1, node_in])
                        @constraint(model, s[k_in-1, node_in] <= -L[k_in-1, node_in] * (1 - z[k_in-1, node_in]))
                        if k_in <= K - 1
                            @constraint(model, temp_sum + b[k_in-1][node_in] == x[k_in-1, node_in] - s[k_in-1, node_in])
                        else # k_in == K
                            @constraint(model, temp_sum + b[k_in-1][node_in] == x[k_in-1, node_in])
                        end
                    end
                end
            end

            ### below constraints depending on the node
            temp_sum = sum(W[k][curr_node, j] * x[k-1, j] for j in 1:node_count[k]) # NOTE! prev layer [k]
            if k <= K - 1
                @constraint(model, node_con, temp_sum + b[k][curr_node] == x[k, curr_node] - s[k, curr_node])
                @constraint(model, node_U, x[k, curr_node] <= U[k, curr_node] * z[k, curr_node])
                @constraint(model, node_L, s[k, curr_node] <= -L[k, curr_node] * (1 - z[k, curr_node]))
            elseif k == K # == last value of k
                @constraint(model, node_con, temp_sum + b[k][curr_node] == x[k, curr_node])
                @constraint(model, node_L, L[k, curr_node] <= x[k, curr_node])
                @constraint(model, node_U, x[k, curr_node] <= U[k, curr_node])
            end

            if obj_function == 1 && k <= K - 1 # Min, hidden layer
                @objective(model, Min, x[k, curr_node] - s[k, curr_node])
            elseif obj_function == 2 && k <= K - 1 # Max, hidden layer
                @objective(model, Max, x[k, curr_node] - s[k, curr_node])
            elseif obj_function == 1 && k == K # Min, last layer
                @objective(model, Min, x[k, curr_node])
            elseif obj_function == 2 && k == K # Max, last layer
                @objective(model, Max, x[k, curr_node])
            end

            solve_time = @elapsed optimize!(model)
            solve_time = round(solve_time; sigdigits = 3)
            @assert termination_status(model) == OPTIMAL || termination_status(model) == TIME_LIMIT
                "Problem (layer $k (from 1:$K), node $curr_node, $(obj_function == 1 ? "L" : "U")-bound) is infeasible."
            optimal = objective_value(model)
            println("Thread: $(Threads.threadid()), layer $k, node $curr_node, $(obj_function == 1 ? "L" : "U")-bound: solve time $(solve_time)s, optimal value $(optimal)")

            # fix the model variable L or U corresponding to the current node to be the optimal value
            Threads.lock(lock) do
                if obj_function == 1 # Min
                    curr_L_bounds[curr_node_index] = optimal
                    fix(L[k, curr_node], optimal)
                elseif obj_function == 2 # Max
                    curr_U_bounds[curr_node_index] = optimal
                    fix(U[k, curr_node], optimal)
                end
            end
            
        end

    end

    println("Solving optimal constraint bounds using threads complete")

    return curr_U_bounds, curr_L_bounds
end

"""
bound_tightening_workers(DNN::Chain, init_U_bounds::Vector{Float32}, init_L_bounds::Vector{Float32}, verbose::Bool=false)

A multi-threaded (using workers) implementation of optimal tightened constraint bounds L and U for for a trained DNN.
Using these bounds with the create_JuMP_model function reduces solution time for optimization problems.

# Arguments
- `DNN::Chain`: A trained ReLU DNN.
- `init_U_bounds::Vector{Float32}`: Initial upper bounds on the node values of the DNN.
- `init_L_bounds::Vector{Float32}`: Initial lower bounds on the node values of the DNN.
- `verbose::Bool=false`: Controls Gurobi logs.

# Examples
```julia
L_bounds_workers, U_bounds_workers = bound_tightening_workers(DNN, init_U_bounds, init_L_bounds, false)
```
"""

function bound_tightening_workers(DNN::Chain, init_U_bounds::Vector{Float32}, init_L_bounds::Vector{Float32}, verbose::Bool=false)

    K = length(DNN) # NOTE! there are K+1 layers in the nn

    # store the DNN weights and biases
    DNN_params = params(DNN)
    W = [DNN_params[2*i-1] for i in 1:K]
    b = [DNN_params[2*i] for i in 1:K]

    # stores the node count of layer k (starting at layer k=0) at index k+1
    input_node_count = length(DNN_params[1][1, :])
    node_count = [if k == 1 input_node_count else length(DNN_params[2*(k-1)]) end for k in 1:K+1]

    # store the current optimal bounds in the algorithm
    curr_U_bounds = copy(init_U_bounds)
    curr_L_bounds = copy(init_L_bounds)
    
    for k in 1:K

        # Distributed.pmap returns the bounds in order
        L_U_bounds = Distributed.pmap(node -> bound_calculating(K, k, node, W, b, node_count, curr_U_bounds, curr_L_bounds, verbose), 1:(2*node_count[k+1]))

        for node in 1:node_count[k+1]
            prev_layers_node_sum = 0
            for prev_layer in 0:k-1
                prev_layers_node_sum += node_count[prev_layer+1]
            end
            
            # loops nodes twice: 1st time with obj function Min, 2nd time with Max
            curr_node = node
            obj_function = 1
            if node > node_count[k+1]
                curr_node = node - node_count[k+1]
                obj_function = 2
            end
            curr_node_index = prev_layers_node_sum + curr_node

            # L-bounds in 1:node_count[k+1], U-bounds in 1:(node + node_count[k+1])
            curr_L_bounds[curr_node_index] = L_U_bounds[node]
            curr_U_bounds[curr_node_index] = L_U_bounds[node + node_count[k+1]]
        end

    end

    println("Solving optimal constraint bounds using workers complete")

    return curr_U_bounds, curr_L_bounds
end

"""
bound_calculating(
    K::Int64, 
    k::Int64, 
    node::Int64, 
    W::Vector{Matrix{Float32}}, 
    b::Vector{Vector{Float32}}, 
    node_count::Vector{Int64}, 
    curr_U_bounds::Vector{Float32}, 
    curr_L_bounds::Vector{Float32}, 
    verbose::Bool=false
    )

An inner function to bound_tightening_workers that handles solving bounds in available
workers. This function is used with Distributed.pmap() to get all bounds in one list.

# Arguments
- `K::Int64`: same as length(DNN). There are K+1 layers in the DNN.
- `k::Int64`: Current layer from 1:K layers.
- `node::Int64`: Current node in the layer. This value is from 1 to twice the amount of nodes, such that the first repetition calculates L-bounds and the second U-bounds.
- `W::Vector{Matrix{Float32}}`: The weight matrices of the DNN
- `b::Vector{Vector{Float32}}`: The bias vectors of the DNN
- `node_count::Vector{Int64}`: Stores the amount of nodes in each layer.
- `curr_U_bounds::Vector{Float32}`: Current optimal upper bounds.
- `curr_L_bounds::Vector{Float32}`: Current optimal lower bounds.
- `verbose::Bool=false`: Controls Gurobi logs.

# Examples
```julia
L_U_bounds = Distributed.pmap(node -> bound_calculating(K, k, node, W, b, node_count, curr_U_bounds, curr_L_bounds, verbose), 1:(2*4))
```
"""

function bound_calculating(
    K::Int64, 
    k::Int64, 
    node::Int64, 
    W::Vector{Matrix{Float32}}, 
    b::Vector{Vector{Float32}}, 
    node_count::Vector{Int64}, 
    curr_U_bounds::Vector{Float32}, 
    curr_L_bounds::Vector{Float32}, 
    verbose::Bool=false
    )

    model = Model(optimizer_with_attributes(Gurobi.Optimizer, "OutputFlag" => (verbose ? 1 : 0), "Threads" => 1))

    # keeps track of the current node index starting from layer 1 (out of 0:K)
    prev_layers_node_sum = 0
    for prev_layer in 0:k-1
        prev_layers_node_sum += node_count[prev_layer+1]
    end
    
    # loops nodes twice: 1st time with obj function Min, 2nd time with Max
    curr_node = node
    obj_function = 1
    if node > node_count[k+1]
        curr_node = node - node_count[k+1]
        obj_function = 2
    end

    # NOTE! below variables and constraints for all opt problems
    @variable(model, x[k in 0:K, j in 1:node_count[k+1]] >= 0)
    @variable(model, s[k in 1:K-1, j in 1:node_count[k+1]] >= 0)
    @variable(model, z[k in 1:K-1, j in 1:node_count[k+1]], Bin)
    @variable(model, U[k in 0:K, j in 1:node_count[k+1]])
    @variable(model, L[k in 0:K, j in 1:node_count[k+1]])

    # fix values to all U[k,j] and L[k,j] from U_bounds and L_bounds
    index = 1
    for k in 0:K
        for j in 1:node_count[k+1]
            fix(U[k, j], curr_U_bounds[index], force=true)
            fix(L[k, j], curr_L_bounds[index], force=true)
            index += 1
        end
    end

    # input layer (layer 0) node bounds are given beforehand
    for input_node in 1:node_count[1]
        delete_lower_bound(x[0, input_node])
        @constraint(model, L[0, input_node] <= x[0, input_node])
        @constraint(model, x[0, input_node] <= U[0, input_node])
    end

    # deleting lower bound for output nodes
    for output_node in 1:node_count[K+1]
        delete_lower_bound(x[K, output_node])
    end

    ### below constraints depending on the layer (every constraint up to the previous layer)
    for k_in in 1:k
        for node_in in 1:node_count[k_in]
            if k_in >= 2
                temp_sum = sum(W[k_in-1][node_in, j] * x[k_in-1-1, j] for j in 1:node_count[k_in-1])
                @constraint(model, x[k_in-1, node_in] <= U[k_in-1, node_in] * z[k_in-1, node_in])
                @constraint(model, s[k_in-1, node_in] <= -L[k_in-1, node_in] * (1 - z[k_in-1, node_in]))
                if k_in <= K - 1
                    @constraint(model, temp_sum + b[k_in-1][node_in] == x[k_in-1, node_in] - s[k_in-1, node_in])
                else # k_in == K
                    @constraint(model, temp_sum + b[k_in-1][node_in] == x[k_in-1, node_in])
                end
            end
        end
    end

    ### below constraints depending on the node
    temp_sum = sum(W[k][curr_node, j] * x[k-1, j] for j in 1:node_count[k]) # NOTE! prev layer [k]
    if k <= K - 1
        @constraint(model, node_con, temp_sum + b[k][curr_node] == x[k, curr_node] - s[k, curr_node])
        @constraint(model, node_U, x[k, curr_node] <= U[k, curr_node] * z[k, curr_node])
        @constraint(model, node_L, s[k, curr_node] <= -L[k, curr_node] * (1 - z[k, curr_node]))
    elseif k == K # == last value of k
        @constraint(model, node_con, temp_sum + b[k][curr_node] == x[k, curr_node])
        @constraint(model, node_L, L[k, curr_node] <= x[k, curr_node])
        @constraint(model, node_U, x[k, curr_node] <= U[k, curr_node])
    end

    if obj_function == 1 && k <= K - 1 # Min, hidden layer
        @objective(model, Min, x[k, curr_node] - s[k, curr_node])
    elseif obj_function == 2 && k <= K - 1 # Max, hidden layer
        @objective(model, Max, x[k, curr_node] - s[k, curr_node])
    elseif obj_function == 1 && k == K # Min, last layer
        @objective(model, Min, x[k, curr_node])
    elseif obj_function == 2 && k == K # Max, last layer
        @objective(model, Max, x[k, curr_node])
    end

    solve_time = @elapsed optimize!(model)
    solve_time = round(solve_time; sigdigits = 3)
    @assert termination_status(model) == OPTIMAL || termination_status(model) == TIME_LIMIT
        "Problem (layer $k (from 1:$K), node $curr_node, $(obj_function == 1 ? "L" : "U")-bound) is infeasible."
    optimal = objective_value(model)
    println("Worker: $(myid()), layer $k, node $curr_node, $(obj_function == 1 ? "L" : "U")-bound: solve time $(solve_time)s, optimal value $(optimal)")

    return optimal
end





# this implementation uses 2 workers, first solving for all L bounds and 2nd for all U bounds
# in a layer. This procedure is repeated layer by layer until we reach the output layer.

function solve_optimal_bounds_2workers(DNN::Chain, init_U_bounds::Vector{Float32}, init_L_bounds::Vector{Float32}, verbose::Bool=false)

    K = length(DNN) # NOTE! there are K+1 layers in the nn

    # store the DNN weights and biases
    DNN_params = params(DNN)
    W = [DNN_params[2*i-1] for i in 1:K]
    b = [DNN_params[2*i] for i in 1:K]

    # stores the node count of layer k (starting at layer k=0) at index k+1
    input_node_count = length(DNN_params[1][1, :])
    node_count = [if k == 1 input_node_count else length(DNN_params[2*(k-1)]) end for k in 1:K+1]

    # store the current optimal bounds in the algorithm
    curr_U_bounds = copy(init_U_bounds)
    curr_L_bounds = copy(init_L_bounds)

    # copy bounds to shared array
    shared_U_bounds = SharedArray(curr_U_bounds)
    shared_L_bounds = SharedArray(curr_L_bounds)
    
    for k in 1:K

        @sync @distributed for obj_function in 1:2 # 2 workers at each layer with an in-place model each

            # @sync @distributed for node in 1:(2*node_count[k+1]) # loop over both obj functions

                ### below variables and constraints in all problems

                model = Model(optimizer_with_attributes(Gurobi.Optimizer, "OutputFlag" => (verbose ? 1 : 0), "Threads" => 4))

                # NOTE! below variables and constraints for all opt problems
                @variable(model, x[k in 0:K, j in 1:node_count[k+1]] >= 0)
                @variable(model, s[k in 1:K-1, j in 1:node_count[k+1]] >= 0)
                @variable(model, z[k in 1:K-1, j in 1:node_count[k+1]], Bin)
                @variable(model, U[k in 0:K, j in 1:node_count[k+1]])
                @variable(model, L[k in 0:K, j in 1:node_count[k+1]])

                # fix values to all U[k,j] and L[k,j] from U_bounds and L_bounds
                index = 1
                for k in 0:K
                    for j in 1:node_count[k+1]
                        fix(U[k, j], shared_U_bounds[index], force=true)
                        fix(L[k, j], shared_L_bounds[index], force=true)
                        index += 1
                    end
                end

                # input layer (layer 0) node bounds are given beforehand
                for input_node in 1:node_count[1]
                    delete_lower_bound(x[0, input_node])
                    @constraint(model, L[0, input_node] <= x[0, input_node])
                    @constraint(model, x[0, input_node] <= U[0, input_node])
                end

                # deleting lower bound for output nodes
                for output_node in 1:node_count[K+1]
                    delete_lower_bound(x[K, output_node])
                end

                ### below constraints depending on the layer (every constraint up to the previous layer)
                for k_in in 1:k
                    for node_in in 1:node_count[k_in]
                        if k_in >= 2
                            temp_sum = sum(W[k_in-1][node_in, j] * x[k_in-1-1, j] for j in 1:node_count[k_in-1])
                            @constraint(model, x[k_in-1, node_in] <= U[k_in-1, node_in] * z[k_in-1, node_in])
                            @constraint(model, s[k_in-1, node_in] <= -L[k_in-1, node_in] * (1 - z[k_in-1, node_in]))
                            if k_in <= K - 1
                                @constraint(model, temp_sum + b[k_in-1][node_in] == x[k_in-1, node_in] - s[k_in-1, node_in])
                            else # k_in == K
                                @constraint(model, temp_sum + b[k_in-1][node_in] == x[k_in-1, node_in])
                            end
                        end
                    end
                end

                for node in 1:node_count[k+1]

                    prev_layers_node_sum = 0
                    for prev_layer in 0:k-1
                        prev_layers_node_sum += node_count[prev_layer+1]
                    end
                    curr_node_index = prev_layers_node_sum + node

                    ### below constraints depending on the node
                    temp_sum = sum(W[k][node, j] * x[k-1, j] for j in 1:node_count[k]) # NOTE! prev layer [k]
                    if k <= K - 1
                        @constraint(model, node_con, temp_sum + b[k][node] == x[k, node] - s[k, node])
                        @constraint(model, node_U, x[k, node] <= U[k, node] * z[k, node])
                        @constraint(model, node_L, s[k, node] <= -L[k, node] * (1 - z[k, node]))
                    elseif k == K # == last value of k
                        @constraint(model, node_con, temp_sum + b[k][node] == x[k, node])
                        @constraint(model, node_L, L[k, node] <= x[k, node])
                        @constraint(model, node_U, x[k, node] <= U[k, node])
                    end

                    if obj_function == 1 && k <= K - 1 # Min, hidden layer
                        @objective(model, Min, x[k, node] - s[k, node])
                    elseif obj_function == 2 && k <= K - 1 # Max, hidden layer
                        @objective(model, Max, x[k, node] - s[k, node])
                    elseif obj_function == 1 && k == K # Min, last layer
                        @objective(model, Min, x[k, node])
                    elseif obj_function == 2 && k == K # Max, last layer
                        @objective(model, Max, x[k, node])
                    end

                    solve_time = @elapsed optimize!(model)
                    solve_time = round(solve_time; sigdigits = 3)
                    @assert termination_status(model) == OPTIMAL || termination_status(model) == TIME_LIMIT
                        "Problem (layer $k (from 1:$K), node $node, $(obj_function == 1 ? "L" : "U")-bound) is infeasible."
                    println("Solve time (layer $k, node $node, $(obj_function == 1 ? "L" : "U")-bound): $(solve_time)s")
                    optimal = objective_value(model)
                    println("thread: ", myid(), ", node: ", node, ", optimal value: ", optimal)

                    # fix the model variable L or U corresponding to the current node to be the optimal value
                    if obj_function == 1 # Min
                        shared_L_bounds[curr_node_index] = optimal
                        # fix(L[k, curr_node], optimal)
                    elseif obj_function == 2 # Max
                        shared_U_bounds[curr_node_index] = optimal
                        # fix(U[k, curr_node], optimal)
                    end

                    delete(model, node_con)
                    delete(model, node_L)
                    delete(model, node_U)
                    unregister(model, :node_con)
                    unregister(model, :node_L)
                    unregister(model, :node_U)

                end
                
            # end
        end


    end

    println("Solving optimal constraint bounds complete")

    curr_U_bounds = collect(shared_U_bounds)
    curr_L_bounds = collect(shared_L_bounds)

    return curr_U_bounds, curr_L_bounds
end