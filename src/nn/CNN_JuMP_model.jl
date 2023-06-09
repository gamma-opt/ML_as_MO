#### CONVOLUTIONAL DNNS INTO MILP ###

using Flux, JuMP, Gurobi
using Flux: params
using Random
# Chain: :layers
# Dense: :weight, :bias, :σ
# Conv: :σ, :weight, :bias, :stride, :pad, :dilation, :groups
# MaxPool: :k, :pad, :stride
# MeanPool: :k, :pad, :stride
Random.seed!(42)
DNN = Chain(
    Conv((2,1), 2 => 3, relu, bias = rand32(3)),
    Conv((1,2), 3 => 2, identity, bias = rand32(2)),
)

# Conv((a,b), c => d, relu) gives parameters[1] in form a×b×c×d matrix
p = params(DNN)
p[1]
# p[3]
# Array order a×b×c×d: a×b image shape, c color channels (RGB 3, grayscale 1, etc.), d image count
# 3×3×1×1 Array{Float32, 4}
data = Float32[0.1 0.2 0.3; 0.4 0.5 0.6; 0.7 0.8 0.9;;; 0.11 0.22 0.33; 0.44 0.55 0.66; 0.77 0.88 0.99;;;;]
data = Float32[0.1 0.2 0.3; 0.4 0.5 0.6; 0.7 0.8 0.9;;;;]
data = Float32[0.1 0.2 0.3 0.4; 0.4 0.5 0.6 0.6; 0.7 0.8 0.9 0.9; 0.7 0.8 0.9 0.9;;;;]

data = Float32[0.1 0.2; 0.3 0.4;;; 0.5 0.6; 0.7 0.8;;;;]
# data = Float32[1 0 0; 0 1 0; 0 0 1;;;;]
data = rand32(10, 10, 3, 1)
DNN(data)



input_size = (size(data)[3], size(data)[1], size(data)[2])

# function create_CNN_model(DNN::Chain, input_size::Tuple{Int64, Int64}, verbose::Bool=false)

K = length(DNN) # NOTE! there are K+1 layers in the nn
layers = DNN.layers

# store the DNN weights (filters for Conv layers) and biases
DNN_params = Flux.params(DNN)
W = [DNN_params[2*i-1] for i in 1:K]
b = [DNN_params[2*i] for i in 1:K]

function next_sub_img_size(img::Tuple{Int64, Int64}, filter::Tuple{Int64, Int64})
    new_height = img[1] - filter[1] + 1
    new_width = img[2] - filter[2] + 1
    return (new_height, new_width)
end

# store the filter shapes in each layer 1:K
filter_sizes = [size(W[k][:,:,1,1]) for k in 1:K]

# tuples of layer shapes 
sub_img_sizes = Array{Tuple{Int64, Int64}}(undef, K+1)
for k in 1:K+1
    if k == 1
        sub_img_sizes[k] = (input_size[2], input_size[3])
    else 
        sub_img_sizes[k] = next_sub_img_size(sub_img_sizes[k-1], filter_sizes[k-1]) 
    end
end

# stores tuples (img index, img h, img w), such that each convoluted subimage pixel can be accesses
DNN_nodes = Array{Tuple{Int64, Int64, Int64}}(undef, K+1)
for k in 1:K+1
    if k == 1
        DNN_nodes[k] = input_size
    else 
        DNN_nodes[k] = (size(W[k-1])[4], next_sub_img_size(sub_img_sizes[k-1], (size(W[k-1])[1], size(W[k-1])[2]))...)
    end
end

# model = Model(optimizer_with_attributes(Gurobi.Optimizer, "OutputFlag" => (verbose ? 1 : 0)))
model = Model(optimizer_with_attributes(Gurobi.Optimizer))

# variables x correspond to convolutional layer pixel values: x[k, i, h, w] -> layer, sub img index, img row, img col
@variable(model, x[k in 0:K, i in 1:DNN_nodes[k+1][1], h in 1:DNN_nodes[k+1][2], w in 1:DNN_nodes[k+1][3]] >= 0)
if K > 1 # s and z variables only to hidden layers, i.e., when K > 1
    @variable(model, s[k in 1:K-1, i in 1:DNN_nodes[k+1][1], h in 1:DNN_nodes[k+1][2], w in 1:DNN_nodes[k+1][3]] >= 0)
    @variable(model, z[k in 1:K-1, i in 1:DNN_nodes[k+1][1], h in 1:DNN_nodes[k+1][2], w in 1:DNN_nodes[k+1][3]], Bin)
end
# variables L and U: lower and upper bounds for pixel values (= hidden node values) in the CNN
@variable(model, L[k in 0:K, i in 1:DNN_nodes[k+1][1], h in 1:DNN_nodes[k+1][2], w in 1:DNN_nodes[k+1][3]] == -1000)
@variable(model, U[k in 0:K, i in 1:DNN_nodes[k+1][1], h in 1:DNN_nodes[k+1][2], w in 1:DNN_nodes[k+1][3]] == 1000)


# delete lower bound and fix L and U bounds to input nodes
for i in 1:DNN_nodes[1][1]
    for h in 1:DNN_nodes[1][2]
        for w in 1:DNN_nodes[1][3]
            delete_lower_bound(x[0, i, h, w])
            @constraint(model, L[0, i, h, w] <= x[0, i, h, w])
            @constraint(model, x[0, i, h, w] <= U[0, i, h, w])
        end
    end
end

# delete lower bound and fix L and U bounds to output nodes
for i in 1:DNN_nodes[K+1][1]
    for h in 1:DNN_nodes[K+1][2]
        for w in 1:DNN_nodes[K+1][3]
            delete_lower_bound(x[K, i, h, w])
            @constraint(model, L[K, i, h, w] <= x[K, i, h, w])
            @constraint(model, x[K, i, h, w] <= U[K, i, h, w])
        end
    end
end

# loop through layers
for k in 1:K
    curr_sub_img_size = sub_img_sizes[k+1] # index k+1 becasue sub_img_sizes contains input size
    curr_filter_size = filter_sizes[k]
    W_rev = reverse(W[k], dims=(1, 2)) # curr layer weights (filters) (rows and columns inverted)

    # loop through number of filters for this (sub)image
    for filter in 1:DNN_nodes[k+1][1]

        # loop through each (sub)image index (i,j) where we place the filter ((1,1) is top left pixel)
        for h in 1:curr_sub_img_size[1]

            # loop through image columns
            for w in 1:curr_sub_img_size[2]
                var_expression_count = DNN_nodes[k][1] * reduce(*, curr_filter_size)
                var_expression = Array{AffExpr}(undef, var_expression_count)
                index = 1

                # loop through each (sub)image in the layer
                for i in 1:DNN_nodes[k][1]

                    # here equation for the variable x[k,i,h,w]

                    W_vec = vec(W_rev[:,:,i,filter])
                    x_vec = vec([x[k-1,i,ii,jj] for ii in h:(h+curr_filter_size[1]-1), jj in w:(w+curr_filter_size[2]-1)])
                    # println("h: $h, curr_filter_size[1]: $(curr_filter_size[1]), w: $w, curr_filter_size[2]: $(curr_filter_size[2])")
                    mult = W_vec .* x_vec

                    for expr in 1:reduce(*, curr_filter_size)
                        var_expression[index] = mult[expr]
                        index += 1
                    end
                end

                temp_sum = sum(var_expression)
                if k < K # hidden layers: k = 1, ..., K-1
                    @constraint(model, temp_sum + b[k][filter] == x[k, filter, h, w] - s[k, filter, h, w])
                else # output layer: k == K
                    @constraint(model, temp_sum + b[k][filter] == x[k, filter, h, w])
                end
            end
        end
    end
end

if K > 1
    # fix bounds to the hidden layers
    @constraint(model, [k in 1:K-1, i in 1:DNN_nodes[k+1][1], h in 1:DNN_nodes[k+1][2], w in 1:DNN_nodes[k+1][3]], x[k, i, h, w] <= U[k, i, h, w] * z[k, i, h, w])
    @constraint(model, [k in 1:K-1, i in 1:DNN_nodes[k+1][1], h in 1:DNN_nodes[k+1][2], w in 1:DNN_nodes[k+1][3]], s[k, i, h, w] <= -L[k, i, h, w] * (1 - z[k, i, h, w]))
end

# fix input values to known data (testing purposes only!)
for i in 1:DNN_nodes[1][1]
    for h in 1:DNN_nodes[1][2]
        for w in 1:DNN_nodes[1][3]
            fix(x[0,i,h,w], data[h,w,i,1], force=true)
        end
    end
end

# arbitrary objective function to allow optimization
@objective(model, Max, x[1,1,1,1])

optimize!(model)

# extract output values from the JuMP model, same as from the CNN
function extract_output(model::Model, DNN_nodes)
    x = model[:x]
    output = []
    len = length(DNN_nodes)
    for i in 1:DNN_nodes[len][1]
        for h in 1:DNN_nodes[len][2]
            for w in 1:DNN_nodes[len][3]
                push!(output, value(x[len-1,i,h,w]))
            end
        end
    end
    return output
end

output = extract_output(model, DNN_nodes)

# @variable(model, x[k in 0:K, j in 1:node_count[k+1]] >= 0)
# @variable(model, s[k in 1:K, j in 1:node_count[k+1]] >= 0)
# # @variable(model, z[k in 1:K, j in 1:node_count[k+1]], Bin)
# @variable(model, U[k in 0:K, j in 1:node_count[k+1]])
# @variable(model, L[k in 0:K, j in 1:node_count[k+1]]) 

# # arbitrary lower and upper bounds for all nodes
# index = 1
# for k in 0:K
#     for j in 1:node_count[k+1]
#         fix(U[k, j], 1000)
#         fix(L[k, j], -1000)
#         index += 1
#     end
# end

# # fix bounds U and L to input nodes
# for input_node in 1:node_count[1]
#     delete_lower_bound(x[0, input_node])
#     @constraint(model, L[0, input_node] <= x[0, input_node])
#     @constraint(model, x[0, input_node] <= U[0, input_node])
# end

# # constraints corresponding to the ReLU activation functions
# for k in 1:K
#     for node in 1:node_count[k+1] # node count of the next layer of k, i.e., the layer k+1
#         temp_sum = sum(W[k][node, j] * x[k-1, j] for j in 1:node_count[k])
#         if k < K # hidden layers: k = 1, ..., K-1
#             @constraint(model, temp_sum + b[k][node] == x[k, node] - s[k, node])
#         else # output layer: k == K
#             @constraint(model, temp_sum + b[k][node] == x[k, node])
#         end
#     end
# end

# # fix bounds to the hidden layer nodes
# @constraint(model, [k in 1:K, j in 1:node_count[k+1]], x[k, j] <= U[k, j] * z[k, j])
# @constraint(model, [k in 1:K, j in 1:node_count[k+1]], s[k, j] <= -L[k, j] * (1 - z[k, j]))

# # fix bounds to the output nodes
# for output_node in 1:node_count[K+1]
#     delete_lower_bound(x[K, output_node])
#     @constraint(model, L[K, output_node] <= x[K, output_node])
#     @constraint(model, x[K, output_node] <= U[K, output_node])
# end

# @objective(model, Max, x[K, 1]) # arbitrary objective function to have a complete JuMP model

# return model

# end

# reversed_matrix = reverse(matrix, dims=(1, 2))
